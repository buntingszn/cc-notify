#!/usr/bin/env bash
set -euo pipefail

# cc-notify setup — deploy ntfy with Podman Quadlet + auth for Claude Code hooks

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

has_cmd() { command -v "$1" &>/dev/null; }

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
    content="${content//\{\{HOOKS_TOKEN\}\}/$HOOKS_TOKEN}"
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
}

# --- Tailscale ---

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
    if [[ -z "$TAILSCALE_HOSTNAME" ]] || [[ "$BASE_URL" != *"$TAILSCALE_HOSTNAME"* ]]; then
        return
    fi

    header "Tailscale Serve"

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

# --- Output ---

print_hooks_config() {
    header "Claude Code Hooks Configuration"

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
            "command": "curl -s -H 'Authorization: Bearer ${HOOKS_TOKEN}' -H 'Title: Claude Code' -H 'Tags: robot' -d 'Claude is waiting for input' ${BASE_URL}/claude"
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
            "command": "jq -r '.message // empty' | grep . | curl -s -H 'Authorization: Bearer ${HOOKS_TOKEN}' -H 'Title: Claude Code' -H 'Tags: bell' -d @- ${BASE_URL}/claude"
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
    echo "     Password: $SUB_PASSWORD"
    echo "  4. Subscribe to topic: claude"
    echo

    echo -e "${BOLD}Browser:${RESET}"
    echo "  1. Open $BASE_URL"
    echo "  2. Log in as $SUB_USERNAME / $SUB_PASSWORD"
    echo "  3. Subscribe to topic: claude"
    echo "  4. Allow notifications"
    echo

    echo -e "${BOLD}Test it:${RESET}"
    echo "  curl -H 'Authorization: Bearer ${HOOKS_TOKEN}' -d 'Hello from cc-notify!' $BASE_URL/claude"
}

# --- Main ---

main() {
    header "cc-notify setup"
    echo "Self-hosted ntfy for Claude Code push notifications."
    echo

    # Check prerequisites
    local missing=()
    for cmd in curl jq openssl podman systemctl; do
        has_cmd "$cmd" || missing+=("$cmd")
    done
    if (( ${#missing[@]} > 0 )); then
        err "Missing required commands: ${missing[*]}"
        [[ " ${missing[*]} " == *" podman "* ]] && err "Install Podman: https://podman.io/docs/installation"
        [[ " ${missing[*]} " == *" jq "* ]] && err "Install jq: sudo dnf install jq / sudo apt install jq"
        exit 1
    fi

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
    fi

    BASE_URL="$(prompt_value "Base URL (used in hooks and ntfy app)" "$default_base_url")"

    # Generate credentials
    SUB_USERNAME="claude-user"
    SUB_PASSWORD="$(openssl rand -hex 12)"
    HOOKS_TOKEN="tk_$(openssl rand -hex 15 | head -c 29)"

    # Deploy with Podman Quadlet
    header "Deploying with Podman Quadlet"

    mkdir -p "$DATA_DIR"
    render_template "$SCRIPT_DIR/ntfy/server.yml.template" "$DATA_DIR/server.yml"
    ok "Config written to $DATA_DIR/server.yml"

    local quadlet_dir="$HOME/.config/containers/systemd"
    mkdir -p "$quadlet_dir"
    copy_with_port "$SCRIPT_DIR/ntfy/ntfy.container" "$quadlet_dir/ntfy.container"
    ok "Quadlet installed to $quadlet_dir/ntfy.container"

    systemctl --user daemon-reload
    systemctl --user start ntfy
    wait_for_healthy

    systemctl --user enable ntfy 2>/dev/null || true
    ok "Enabled auto-start on login"

    # Create users and set access via podman exec
    header "Setting up authentication"

    echo "$SUB_PASSWORD" | podman exec -i ntfy ntfy user add --role=user "$SUB_USERNAME" 2>/dev/null || true
    ok "Created subscriber user: $SUB_USERNAME"

    local hooks_password
    hooks_password="$(openssl rand -hex 16)"
    echo "$hooks_password" | podman exec -i ntfy ntfy user add --role=user "claude-hooks" 2>/dev/null || true

    podman exec ntfy ntfy access "$SUB_USERNAME" 'claude' read-write 2>/dev/null || true
    podman exec ntfy ntfy access "claude-hooks" 'claude' write-only 2>/dev/null || true
    ok "Authentication configured"

    # Tailscale Serve
    setup_tailscale_serve

    # Output
    print_hooks_config
    print_client_instructions

    header "Done!"
    echo "ntfy is running at $BASE_URL"
    echo "Subscribe to the 'claude' topic in your ntfy app to receive notifications."
}

main "$@"
