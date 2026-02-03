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
    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64)  echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7l)  echo "armv7" ;;
        *)       echo "$arch" ;;
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

# --- Config rendering ---

render_template() {
    local template="$1" output="$2"
    local content
    content="$(cat "$template")"
    content="${content//\{\{BASE_URL\}\}/$BASE_URL}"
    content="${content//\{\{PORT\}\}/$PORT}"
    echo "$content" > "$output"
}

render_hooks() {
    local template="$1" output="$2"
    local content
    content="$(cat "$template")"
    content="${content//\{\{NTFY_TOKEN\}\}/$HOOKS_TOKEN}"
    content="${content//\{\{NTFY_URL\}\}/$BASE_URL}"
    echo "$content" > "$output"
}

# --- Deployment methods ---

deploy_podman_quadlet() {
    header "Deploying with Podman Quadlet"

    mkdir -p "$DATA_DIR"
    render_template "$SCRIPT_DIR/ntfy/server.yml.template" "$DATA_DIR/server.yml"
    ok "Config written to $DATA_DIR/server.yml"

    local quadlet_dir="$HOME/.config/containers/systemd"
    mkdir -p "$quadlet_dir"

    # Update the quadlet port if non-default
    local quadlet_content
    quadlet_content="$(cat "$SCRIPT_DIR/ntfy/ntfy.container")"
    quadlet_content="${quadlet_content//8098:8098/${PORT}:${PORT}}"
    quadlet_content="${quadlet_content//127.0.0.1:8098/127.0.0.1:${PORT}}"
    echo "$quadlet_content" > "$quadlet_dir/ntfy.container"
    ok "Quadlet installed to $quadlet_dir/ntfy.container"

    info "Reloading systemd..."
    systemctl --user daemon-reload

    info "Starting ntfy..."
    systemctl --user start ntfy

    # Wait for healthy
    info "Waiting for ntfy to start..."
    local retries=0
    while ! curl -sf "http://127.0.0.1:${PORT}/v1/health" &>/dev/null; do
        sleep 1
        retries=$((retries + 1))
        if (( retries > 30 )); then
            err "ntfy failed to start within 30 seconds"
            err "Check: systemctl --user status ntfy"
            exit 1
        fi
    done
    ok "ntfy is running"

    systemctl --user enable ntfy 2>/dev/null || true
    ok "Enabled auto-start on login"
}

deploy_docker_compose() {
    header "Deploying with Docker Compose"

    local compose_dir="$DATA_DIR"
    mkdir -p "$compose_dir/data"

    render_template "$SCRIPT_DIR/ntfy/server.yml.template" "$compose_dir/data/server.yml"
    ok "Config written to $compose_dir/data/server.yml"

    # Copy and adjust docker-compose.yml
    local compose_content
    compose_content="$(cat "$SCRIPT_DIR/ntfy/docker-compose.yml")"
    compose_content="${compose_content//8098:8098/${PORT}:${PORT}}"
    compose_content="${compose_content//127.0.0.1:8098/127.0.0.1:${PORT}}"
    echo "$compose_content" > "$compose_dir/docker-compose.yml"
    ok "docker-compose.yml written to $compose_dir/"

    info "Starting ntfy..."
    docker compose -f "$compose_dir/docker-compose.yml" up -d

    # Wait for healthy
    info "Waiting for ntfy to start..."
    local retries=0
    while ! curl -sf "http://127.0.0.1:${PORT}/v1/health" &>/dev/null; do
        sleep 1
        retries=$((retries + 1))
        if (( retries > 30 )); then
            err "ntfy failed to start within 30 seconds"
            err "Check: docker compose -f $compose_dir/docker-compose.yml logs"
            exit 1
        fi
    done
    ok "ntfy is running"
}

deploy_bare_binary() {
    header "Deploying with bare binary"

    local os arch ntfy_bin
    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    arch="$(detect_arch)"

    if has_cmd ntfy; then
        ntfy_bin="$(command -v ntfy)"
        ok "ntfy already installed at $ntfy_bin"
    else
        info "Downloading ntfy..."
        local tmpdir
        tmpdir="$(mktemp -d)"
        local tarball="ntfy_${os}_${arch}.tar.gz"
        local url="https://github.com/binwiederhier/ntfy/releases/latest/download/${tarball}"

        if ! curl -fsSL "$url" -o "$tmpdir/$tarball"; then
            err "Failed to download ntfy from $url"
            err "Check https://github.com/binwiederhier/ntfy/releases for available builds"
            rm -rf "$tmpdir"
            exit 1
        fi

        tar xzf "$tmpdir/$tarball" -C "$tmpdir"

        # Find the ntfy binary in extracted files
        ntfy_bin="$(find "$tmpdir" -name ntfy -type f -perm -111 | head -1)"
        if [[ -z "$ntfy_bin" ]]; then
            ntfy_bin="$(find "$tmpdir" -name ntfy -type f | head -1)"
            chmod +x "$ntfy_bin"
        fi

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
    if [[ "$(detect_os)" == "linux" ]] && has_cmd systemctl; then
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

    elif [[ "$(detect_os)" == "macos" ]]; then
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

    # Wait for healthy
    info "Waiting for ntfy to start..."
    local retries=0
    while ! curl -sf "http://127.0.0.1:${PORT}/v1/health" &>/dev/null; do
        sleep 1
        retries=$((retries + 1))
        if (( retries > 30 )); then
            err "ntfy failed to start within 30 seconds"
            exit 1
        fi
    done
    ok "ntfy is running"
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
            local ntfy_bin
            ntfy_bin="$(command -v ntfy)"
            "$ntfy_bin" --config "$DATA_DIR/server.yml" "$@"
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

    # Grant write access to claude topic for the subscriber (so they can read)
    run_ntfy_cmd access "$username" 'claude' read-write 2>/dev/null || true

    # Generate hooks token — this is what the curl commands use
    HOOKS_TOKEN="$(openssl rand -hex 24)"

    # Create a dedicated hooks user with write-only access
    local hooks_password
    hooks_password="$(openssl rand -hex 16)"
    echo "$hooks_password" | run_ntfy_cmd user add --role=user "claude-hooks" 2>/dev/null || true
    run_ntfy_cmd access "claude-hooks" 'claude' write-only 2>/dev/null || true

    # Create access token for the hooks user
    local token_output
    token_output="$(run_ntfy_cmd token add --label=claude-hooks claude-hooks 2>&1)" || true

    # Extract the token from output — ntfy prints "token tk_... created"
    HOOKS_TOKEN="$(echo "$token_output" | grep -oP 'tk_[a-zA-Z0-9]+' | head -1)" || true

    if [[ -z "$HOOKS_TOKEN" ]]; then
        warn "Could not extract token automatically. Creating token manually..."
        # Fallback: use basic auth in the curl command instead
        HOOKS_TOKEN=""
        HOOKS_AUTH_HEADER="Authorization: Basic $(echo -n "claude-hooks:${hooks_password}" | base64)"
    fi

    ok "Authentication configured"

    SUB_USERNAME="$username"
    SUB_PASSWORD="$password"
}

# --- Output ---

print_hooks_config() {
    header "Claude Code Hooks Configuration"

    local auth_header ntfy_url
    ntfy_url="$BASE_URL"

    if [[ -n "${HOOKS_TOKEN:-}" ]]; then
        auth_header="Authorization: Bearer $HOOKS_TOKEN"
    else
        auth_header="$HOOKS_AUTH_HEADER"
    fi

    echo -e "Add this to ${BOLD}~/.claude/settings.json${RESET}:"
    echo
    cat <<HOOKS
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "curl -s -H '${auth_header}' -H 'Title: Claude Code' -H 'Tags: robot' -d 'Claude is waiting for input' ${ntfy_url}/claude"
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
            "command": "curl -s -H '${auth_header}' -H 'Title: Claude Code' -H 'Tags: bell' -d \"\$CLAUDE_NOTIFICATION\" ${ntfy_url}/claude"
          }
        ]
      }
    ]
  }
}
HOOKS

    echo
    warn "Copy the hooks block above into your settings file."
    echo

    # Also write rendered hooks to a file for reference
    local hooks_file="$DATA_DIR/hooks.json"
    cat > "$hooks_file" <<HOOKSFILE
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "curl -s -H '${auth_header}' -H 'Title: Claude Code' -H 'Tags: robot' -d 'Claude is waiting for input' ${ntfy_url}/claude"
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
            "command": "curl -s -H '${auth_header}' -H 'Title: Claude Code' -H 'Tags: bell' -d \"\\\$CLAUDE_NOTIFICATION\" ${ntfy_url}/claude"
          }
        ]
      }
    ]
  }
}
HOOKSFILE
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
    if [[ -n "${HOOKS_TOKEN:-}" ]]; then
        auth_header="-H 'Authorization: Bearer $HOOKS_TOKEN'"
    else
        auth_header="-H '$HOOKS_AUTH_HEADER'"
    fi
    echo "  curl $auth_header -d 'Hello from cc-notify!' $BASE_URL/claude"
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

    # Base URL
    local default_base_url="http://127.0.0.1:${PORT}"

    # Check for Tailscale
    if has_cmd tailscale; then
        local ts_hostname
        ts_hostname="$(tailscale status --self --json 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("Self",{}).get("DNSName","").rstrip("."))' 2>/dev/null)" || true
        if [[ -n "$ts_hostname" ]]; then
            info "Tailscale detected: $ts_hostname"
            info "You can use 'tailscale serve' later for remote HTTPS access."
        fi
    fi

    BASE_URL="$(prompt_value "Base URL" "$default_base_url")"

    # Deploy
    case "$DEPLOY_METHOD" in
        podman) deploy_podman_quadlet ;;
        docker) deploy_docker_compose ;;
        binary) deploy_bare_binary ;;
    esac

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
