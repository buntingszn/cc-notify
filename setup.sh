#!/usr/bin/env bash
set -euo pipefail

# cc-notify setup — interactive installer for ntfy + Claude Code hooks
# Detects environment and deploys ntfy with auth configured.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_PORT=8098
DATA_DIR="$HOME/.local/share/cc-notify"

# --- Colors (disabled if not a terminal) ---

if [[ -t 1 ]]; then
    BOLD='\033[1m'
    DIM='\033[2m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    CYAN='\033[0;36m'
    RED='\033[0;31m'
    RESET='\033[0m'
else
    BOLD='' DIM='' GREEN='' YELLOW='' CYAN='' RED='' RESET=''
fi

info()  { echo -e "${CYAN}▸${RESET} $*"; }
ok()    { echo -e "${GREEN}✓${RESET} $*"; }
warn()  { echo -e "${YELLOW}!${RESET} $*"; }
err()   { echo -e "${RED}✗${RESET} $*" >&2; }
header() { echo -e "\n${BOLD}$*${RESET}\n"; }

# --- Detect environment ---

detect_os() {
    case "$(uname -s)" in
        Linux*)  echo "linux" ;;
        Darwin*) echo "macos" ;;
        *)       echo "unknown" ;;
    esac
}

has_cmd() { command -v "$1" &>/dev/null; }

detect_runtime() {
    if has_cmd podman && [[ "$(detect_os)" == "linux" ]] && has_cmd systemctl; then
        echo "podman"
    elif has_cmd docker; then
        echo "docker"
    else
        echo "none"
    fi
}

detect_arch() {
    case "$(uname -m)" in
        x86_64)        echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7l)        echo "armv7" ;;
        *)             uname -m ;;
    esac
}

# --- User prompts ---

prompt_value() {
    local prompt="$1" default="$2" value
    if [[ -n "$default" ]]; then
        read -rp "$(echo -e "${CYAN}?${RESET} ${prompt} [${DIM}${default}${RESET}]: ")" value
        echo "${value:-$default}"
    else
        read -rp "$(echo -e "${CYAN}?${RESET} ${prompt}: ")" value
        echo "$value"
    fi
}

prompt_choice() {
    local prompt="$1"
    shift
    local options=("$@")

    echo -e "\n${CYAN}?${RESET} ${prompt}"
    for i in "${!options[@]}"; do
        echo -e "  ${BOLD}$((i + 1)))${RESET} ${options[$i]}"
    done

    local choice
    while true; do
        read -rp "$(echo -e "${CYAN}▸${RESET} Choose [1-${#options[@]}]: ")" choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
            echo "$choice"
            return
        fi
        warn "Enter a number between 1 and ${#options[@]}"
    done
}

# --- Helpers ---

render_template() {
    local template="$1" output="$2"
    local content
    content="$(cat "$template")"
    content="${content//\{\{BASE_URL\}\}/$BASE_URL}"
    content="${content//\{\{PORT\}\}/$PORT}"
    echo "$content" > "$output"
}

copy_with_port() {
    local src="$1" dest="$2"
    local content
    content="$(cat "$src")"
    content="${content//8098:8098/${PORT}:${PORT}}"
    content="${content//127.0.0.1:8098/127.0.0.1:${PORT}}"
    echo "$content" > "$dest"
}

wait_for_healthy() {
    local hint="${1:-}"
    info "Waiting for ntfy to start..."
    local retries=0
    while ! curl -sf "http://127.0.0.1:${PORT}/v1/health" &>/dev/null; do
        sleep 1
        retries=$((retries + 1))
        if (( retries > 30 )); then
            err "ntfy failed to start within 30 seconds"
            [[ -n "$hint" ]] && err "Check: $hint"
            exit 1
        fi
    done
    ok "ntfy is running"
}

# --- Deployment methods ---

deploy_podman_quadlet() {
    header "Deploying with Podman Quadlet"

    mkdir -p "$DATA_DIR"
    render_template "$SCRIPT_DIR/ntfy/server.yml.template" "$DATA_DIR/server.yml"
    ok "Config written to $DATA_DIR/server.yml"

    local quadlet_dir="$HOME/.config/containers/systemd"
    mkdir -p "$quadlet_dir"
    copy_with_port "$SCRIPT_DIR/ntfy/ntfy.container" "$quadlet_dir/ntfy.container"
    ok "Quadlet installed to $quadlet_dir/ntfy.container"

    info "Reloading systemd..."
    systemctl --user daemon-reload

    info "Starting ntfy..."
    systemctl --user start ntfy
    wait_for_healthy "systemctl --user status ntfy"

    systemctl --user enable ntfy 2>/dev/null || true
    ok "Enabled auto-start on login"
}

deploy_docker_compose() {
    header "Deploying with Docker Compose"

    mkdir -p "$DATA_DIR/data"
    render_template "$SCRIPT_DIR/ntfy/server.yml.template" "$DATA_DIR/data/server.yml"
    ok "Config written to $DATA_DIR/data/server.yml"

    copy_with_port "$SCRIPT_DIR/ntfy/docker-compose.yml" "$DATA_DIR/docker-compose.yml"
    ok "docker-compose.yml written to $DATA_DIR/"

    info "Starting ntfy..."
    docker compose -f "$DATA_DIR/docker-compose.yml" up -d
    wait_for_healthy "docker compose -f $DATA_DIR/docker-compose.yml logs"
}

deploy_bare_binary() {
    header "Deploying with bare binary"

    local os ntfy_bin
    os="$(detect_os)"

    if has_cmd ntfy; then
        ntfy_bin="$(command -v ntfy)"
        ok "ntfy already installed at $ntfy_bin"
    else
        info "Downloading ntfy..."
        local tmpdir arch tarball url
        tmpdir="$(mktemp -d)"
        arch="$(detect_arch)"
        tarball="ntfy_$(uname -s | tr '[:upper:]' '[:lower:]')_${arch}.tar.gz"
        url="https://github.com/binwiederhier/ntfy/releases/latest/download/${tarball}"

        if ! curl -fsSL "$url" -o "$tmpdir/$tarball"; then
            err "Failed to download ntfy from $url"
            err "Check https://github.com/binwiederhier/ntfy/releases for available builds"
            rm -rf "$tmpdir"
            exit 1
        fi

        tar xzf "$tmpdir/$tarball" -C "$tmpdir"

        ntfy_bin="$(find "$tmpdir" -name ntfy -type f | head -1)"
        chmod +x "$ntfy_bin"

        local install_dir="$HOME/.local/bin"
        mkdir -p "$install_dir"
        mv "$ntfy_bin" "$install_dir/ntfy"
        ntfy_bin="$install_dir/ntfy"
        rm -rf "$tmpdir"
        ok "ntfy installed to $ntfy_bin"

        if ! echo "$PATH" | grep -q "$install_dir"; then
            warn "Add $install_dir to your PATH if not already"
        fi
    fi

    mkdir -p "$DATA_DIR"
    render_template "$SCRIPT_DIR/ntfy/server.yml.template" "$DATA_DIR/server.yml"
    ok "Config written to $DATA_DIR/server.yml"

    # Generate service file
    if [[ "$os" == "linux" ]] && has_cmd systemctl; then
        local service_dir="$HOME/.config/systemd/user"
        mkdir -p "$service_dir"
        cat > "$service_dir/ntfy.service" <<UNIT
[Unit]
Description=ntfy push notification server (cc-notify)
After=network-online.target

[Service]
Type=simple
ExecStart=$ntfy_bin serve --config $DATA_DIR/server.yml
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
UNIT
        ok "systemd unit written to $service_dir/ntfy.service"

        systemctl --user daemon-reload
        systemctl --user start ntfy
        systemctl --user enable ntfy 2>/dev/null || true
        ok "ntfy started and enabled"

    elif [[ "$os" == "macos" ]]; then
        local plist_dir="$HOME/Library/LaunchAgents"
        local plist_file="$plist_dir/com.cc-notify.ntfy.plist"
        mkdir -p "$plist_dir"
        cat > "$plist_file" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.cc-notify.ntfy</string>
    <key>ProgramArguments</key>
    <array>
        <string>$ntfy_bin</string>
        <string>serve</string>
        <string>--config</string>
        <string>$DATA_DIR/server.yml</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$DATA_DIR/ntfy.log</string>
    <key>StandardErrorPath</key>
    <string>$DATA_DIR/ntfy.err</string>
</dict>
</plist>
PLIST
        ok "launchd plist written to $plist_file"
        launchctl load "$plist_file"
        ok "ntfy started via launchd"
    else
        warn "No service manager detected. Run ntfy manually:"
        echo "  $ntfy_bin serve --config $DATA_DIR/server.yml"
    fi

    wait_for_healthy
}

# --- User + token creation ---

run_ntfy_cmd() {
    case "$DEPLOY_METHOD" in
        podman)
            podman exec ntfy ntfy "$@"
            ;;
        docker)
            docker compose -f "$DATA_DIR/docker-compose.yml" exec ntfy ntfy "$@"
            ;;
        binary)
            "$(command -v ntfy)" --config "$DATA_DIR/server.yml" "$@"
            ;;
    esac
}

create_user_and_token() {
    header "Setting up authentication"

    # Create subscriber user
    local username password
    username="$(prompt_value "Subscriber username (for your phone/browser)" "claude-user")"

    info "Choose a password for the subscriber account."
    info "You'll enter this in the ntfy app on your phone."
    while true; do
        read -rsp "$(echo -e "${CYAN}?${RESET} Password: ")" password
        echo
        if [[ ${#password} -lt 8 ]]; then
            warn "Password must be at least 8 characters"
            continue
        fi
        break
    done

    # Pipe password to avoid interactive prompt
    echo "$password" | run_ntfy_cmd user add --role=user "$username" 2>/dev/null || true
    ok "Created subscriber user: $username"

    # Grant read-write access to claude topic for the subscriber
    run_ntfy_cmd access "$username" 'claude' read-write 2>/dev/null || true

    # Create a dedicated hooks user with write-only access
    local hooks_password
    hooks_password="$(openssl rand -hex 16)"
    echo "$hooks_password" | run_ntfy_cmd user add --role=user "claude-hooks" 2>/dev/null || true
    run_ntfy_cmd access "claude-hooks" 'claude' write-only 2>/dev/null || true

    # Create access token for the hooks user
    local token_output
    token_output="$(run_ntfy_cmd token add --label=claude-hooks claude-hooks 2>&1)" || true

    # Extract the token from output — ntfy prints "token tk_... created"
    HOOKS_TOKEN="$(echo "$token_output" | grep -oE 'tk_[a-zA-Z0-9]+' | head -1)" || true

    if [[ -z "$HOOKS_TOKEN" ]]; then
        warn "Could not extract token automatically. Falling back to basic auth."
        HOOKS_TOKEN=""
        HOOKS_AUTH_HEADER="Authorization: Basic $(echo -n "claude-hooks:${hooks_password}" | base64)"
    fi

    ok "Authentication configured"

    SUB_USERNAME="$username"
    SUB_PASSWORD="$password"
}

# --- Output ---

get_auth_header() {
    if [[ -n "${HOOKS_TOKEN:-}" ]]; then
        echo "Authorization: Bearer $HOOKS_TOKEN"
    else
        echo "$HOOKS_AUTH_HEADER"
    fi
}

print_hooks_config() {
    header "Claude Code Hooks Configuration"

    local auth_header
    auth_header="$(get_auth_header)"

    # Generate hooks JSON once, write to file, display to user
    local hooks_file="$DATA_DIR/hooks.json"
    cat > "$hooks_file" <<HOOKS
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "curl -s -H '${auth_header}' -H 'Title: Claude Code' -H 'Tags: robot' -d 'Claude is waiting for input' ${BASE_URL}/claude"
          }
        ]
      }
    ],
    "Notification": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "curl -s -H '${auth_header}' -H 'Title: Claude Code' -H 'Tags: bell' -d \"\$CLAUDE_NOTIFICATION\" ${BASE_URL}/claude"
          }
        ]
      }
    ]
  }
}
HOOKS

    echo -e "Add this to ${BOLD}~/.claude/settings.json${RESET}:"
    echo
    cat "$hooks_file"
    echo
    warn "Copy the hooks block above into your settings file."
    ok "Hooks config also saved to $hooks_file"
}

print_client_instructions() {
    header "Client Setup"

    echo -e "${BOLD}Phone (ntfy app):${RESET}"
    echo "  1. Install ntfy from your app store"
    echo "  2. Settings → Add default server → $BASE_URL"
    echo "  3. Settings → Manage users → add:"
    echo "     Username: $SUB_USERNAME"
    echo "     Password: (the password you just set)"
    echo "  4. Subscribe to topic: claude"
    echo

    echo -e "${BOLD}Browser:${RESET}"
    echo "  1. Open $BASE_URL"
    echo "  2. Log in as $SUB_USERNAME"
    echo "  3. Subscribe to topic: claude"
    echo "  4. Allow notifications"
    echo

    echo -e "${BOLD}Test it:${RESET}"
    local auth_header
    auth_header="$(get_auth_header)"
    echo "  curl -H '${auth_header}' -d 'Hello from cc-notify!' $BASE_URL/claude"
}

# --- Tailscale Serve ---

detect_tailscale_hostname() {
    if ! has_cmd tailscale; then
        return
    fi

    local ts_hostname=""
    if has_cmd jq; then
        ts_hostname="$(tailscale status --self --json 2>/dev/null | jq -r '.Self.DNSName // ""' | sed 's/\.$//')" || true
    elif has_cmd python3; then
        ts_hostname="$(tailscale status --self --json 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("Self",{}).get("DNSName","").rstrip("."))' 2>/dev/null)" || true
    fi

    echo "$ts_hostname"
}

setup_tailscale_serve() {
    # Only run if the base URL uses the Tailscale hostname
    if [[ -z "$TAILSCALE_HOSTNAME" ]] || [[ "$BASE_URL" != *"$TAILSCALE_HOSTNAME"* ]]; then
        return
    fi

    header "Tailscale Serve"

    # Check if tailscale serve is already forwarding this port
    if tailscale serve status 2>/dev/null | grep -q ":${PORT}"; then
        ok "Tailscale Serve already configured for port ${PORT}"
        return
    fi

    info "Tailscale Serve will expose ntfy at ${BASE_URL} over HTTPS."
    info "Your phone (on the same tailnet) can reach it from anywhere."
    echo

    local setup_ts
    setup_ts="$(prompt_choice "Configure Tailscale Serve now?" \
        "Yes — run 'tailscale serve' (recommended)" \
        "No — I'll set it up manually later")"

    if [[ "$setup_ts" == "1" ]]; then
        info "Running: sudo tailscale serve --bg --https 443 http://127.0.0.1:${PORT}"
        if sudo tailscale serve --bg --https 443 "http://127.0.0.1:${PORT}" 2>&1; then
            ok "Tailscale Serve configured: ${BASE_URL}"
        else
            warn "tailscale serve failed. You can set it up manually:"
            echo "  sudo tailscale serve --bg --https 443 http://127.0.0.1:${PORT}"
        fi
    else
        info "Set it up later with:"
        echo "  sudo tailscale serve --bg --https 443 http://127.0.0.1:${PORT}"
    fi
}

# --- Main ---

main() {
    header "cc-notify setup"
    echo "Self-hosted ntfy for Claude Code push notifications."
    echo

    # Check prerequisites
    if ! has_cmd curl; then
        err "curl is required but not found"
        exit 1
    fi
    if ! has_cmd openssl; then
        err "openssl is required but not found"
        exit 1
    fi

    # Detect environment
    local os runtime
    os="$(detect_os)"
    runtime="$(detect_runtime)"

    info "OS: $os"
    info "Container runtime: $runtime"

    # Choose deployment method
    local method_choice
    case "$runtime" in
        podman)
            method_choice="$(prompt_choice "Deployment method:" \
                "Podman Quadlet (recommended — auto-starts on login)" \
                "Docker Compose" \
                "Bare binary (download ntfy, run directly)")"
            ;;
        docker)
            method_choice="$(prompt_choice "Deployment method:" \
                "Docker Compose (recommended)" \
                "Bare binary (download ntfy, run directly)")"
            # Map choice numbers
            if [[ "$method_choice" == "2" ]]; then method_choice=3; fi
            ;;
        none)
            info "No container runtime found — using bare binary"
            method_choice=3
            ;;
    esac

    case "$method_choice" in
        1) DEPLOY_METHOD="podman" ;;
        2) DEPLOY_METHOD="docker" ;;
        3) DEPLOY_METHOD="binary" ;;
    esac

    # Port
    PORT="$(prompt_value "Port for ntfy" "$DEFAULT_PORT")"

    # Base URL — auto-detect Tailscale and default to HTTPS
    local default_base_url="http://127.0.0.1:${PORT}"
    TAILSCALE_HOSTNAME=""

    local ts_hostname
    ts_hostname="$(detect_tailscale_hostname)"
    if [[ -n "$ts_hostname" ]]; then
        TAILSCALE_HOSTNAME="$ts_hostname"
        default_base_url="https://${ts_hostname}"
        ok "Tailscale detected: $ts_hostname"
        info "Defaulting base URL to https://${ts_hostname}"
        info "This is the tested/recommended setup."
    fi

    BASE_URL="$(prompt_value "Base URL (used in hooks and ntfy app)" "$default_base_url")"

    # Deploy
    case "$DEPLOY_METHOD" in
        podman) deploy_podman_quadlet ;;
        docker) deploy_docker_compose ;;
        binary) deploy_bare_binary ;;
    esac

    # Set up Tailscale Serve if using a Tailscale URL
    setup_tailscale_serve

    # Create users and tokens
    create_user_and_token

    # Output config
    print_hooks_config
    print_client_instructions

    header "Done!"
    echo "ntfy is running at $BASE_URL"
    echo "Subscribe to the 'claude' topic in your ntfy app to receive notifications."
}

main "$@"
