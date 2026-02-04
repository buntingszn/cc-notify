#!/usr/bin/env bash
set -euo pipefail

# cc-notify setup — deploy Bark or ntfy with Podman Quadlet for Claude Code hooks

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

    echo -e "\n${CYAN}?${RESET} ${prompt}" >&2
    for i in "${!options[@]}"; do
        echo -e "  ${BOLD}$((i + 1)))${RESET} ${options[$i]}" >&2
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

wait_for_healthy() {
    local service_name="$1" health_endpoint="$2"
    info "Waiting for ${service_name} to start..."
    local retries=0
    while ! curl -sf "http://127.0.0.1:${PORT}${health_endpoint}" &>/dev/null; do
        sleep 1
        retries=$((retries + 1))
        if (( retries > 30 )); then
            err "${service_name} failed to start within 30 seconds"
            err "Check: systemctl --user status ${service_name}"
            exit 1
        fi
    done
    ok "${service_name} is running"
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

    info "Tailscale Serve will expose ${BACKEND} at ${BASE_URL} over HTTPS."
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

# --- Bark ---

generate_bark_push_script() {
    local push_script="$DATA_DIR/bark-push.sh"

    # Config values (expanded from setup variables)
    cat > "$push_script" <<CONF
#!/usr/bin/env bash
set -euo pipefail

DEVICE_KEY='${DEVICE_KEY}'
BASE_URL='${BASE_URL}'
ENC_KEY_HEX='${ENCRYPT_KEY_HEX}'
ENC_IV_HEX='${ENCRYPT_IV_HEX}'
CONF

    # Script logic (no variable expansion — absolute paths for container compatibility)
    cat >> "$push_script" <<'LOGIC'

body=""
if [[ $# -gt 0 ]]; then
    body="$1"
else
    body="$(cat)"
fi
[[ -z "$body" ]] && exit 0

if [[ -n "$ENC_KEY_HEX" ]]; then
    payload=$(/usr/bin/jq -nc --arg t "Claude Code" --arg b "$body" '{"title":$t,"body":$b,"group":"claude"}')
    ciphertext=$(echo -n "$payload" | /usr/bin/openssl enc -aes-128-cbc -K "$ENC_KEY_HEX" -iv "$ENC_IV_HEX" | /usr/bin/base64 -w 0)
    /usr/bin/curl -s -H 'Content-Type: application/json' \
      -d "$(/usr/bin/jq -nc --arg dk "$DEVICE_KEY" --arg ct "$ciphertext" '{device_key:$dk,ciphertext:$ct}')" \
      "${BASE_URL}/push"
else
    /usr/bin/curl -s -H 'Content-Type: application/json' \
      -d "$(/usr/bin/jq -nc --arg dk "$DEVICE_KEY" --arg t "Claude Code" --arg b "$body" '{device_key:$dk,title:$t,body:$b,group:"claude"}')" \
      "${BASE_URL}/push"
fi
LOGIC

    chmod +x "$push_script"
    ok "Push script written to $push_script"
}

setup_bark() {
    header "Deploying Bark with Podman Quadlet"

    mkdir -p "$DATA_DIR"

    local quadlet_dir="$HOME/.config/containers/systemd"
    mkdir -p "$quadlet_dir"

    # Bark container listens on 8080 internally; only the host port changes
    local content
    content="$(cat "$SCRIPT_DIR/bark/bark.container")"
    content="${content//127.0.0.1:8099:8080/127.0.0.1:${PORT}:8080}"
    echo "$content" > "$quadlet_dir/bark.container"
    ok "Quadlet installed to $quadlet_dir/bark.container"

    systemctl --user daemon-reload
    systemctl --user start bark
    wait_for_healthy "bark" "/healthz"

    systemctl --user enable bark 2>/dev/null || true
    ok "Enabled auto-start on login"

    header "Bark Device Key"
    echo "Register your phone with this bark server:"
    echo "  1. Open the Bark app on your iPhone"
    echo "  2. Tap \"Servers\" → add server: ${BASE_URL}"
    echo "  3. Copy the device key shown for this server"
    echo "  4. Paste it below"
    echo
    DEVICE_KEY="$(prompt_value "Bark device key" "")"

    if [[ -z "$DEVICE_KEY" ]]; then
        err "Device key is required. Add your server in the Bark app first."
        exit 1
    fi

    # Encryption setup
    header "Push Encryption (AES-128-CBC)"
    echo "Encrypts notification content before it leaves your machine."
    echo "The bark-server and Apple APNs never see your message text."
    echo

    local setup_enc
    setup_enc="$(prompt_choice "Enable push encryption?" \
        "Yes — generate a random key and IV (recommended)" \
        "Yes — enter an existing key and IV" \
        "No — send notifications in plaintext")"

    ENCRYPT_KEY=""
    ENCRYPT_IV=""
    ENCRYPT_KEY_HEX=""
    ENCRYPT_IV_HEX=""

    if [[ "$setup_enc" == "1" ]] || [[ "$setup_enc" == "2" ]]; then
        for cmd in openssl xxd; do
            if ! has_cmd "$cmd"; then
                err "Encryption requires '${cmd}'. Install it and re-run setup."
                exit 1
            fi
        done
    fi

    if [[ "$setup_enc" == "1" ]]; then
        ENCRYPT_KEY="$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 16)"
        ENCRYPT_IV="$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 16)"
        ENCRYPT_KEY_HEX="$(printf '%s' "$ENCRYPT_KEY" | xxd -ps -c 200)"
        ENCRYPT_IV_HEX="$(printf '%s' "$ENCRYPT_IV" | xxd -ps -c 200)"
        ok "Generated encryption key and IV"
    elif [[ "$setup_enc" == "2" ]]; then
        ENCRYPT_KEY="$(prompt_value "Encryption key (exactly 16 characters)" "")"
        if [[ ${#ENCRYPT_KEY} -ne 16 ]]; then
            err "Key must be exactly 16 characters"
            exit 1
        fi
        ENCRYPT_IV="$(prompt_value "Encryption IV (exactly 16 characters)" "")"
        if [[ ${#ENCRYPT_IV} -ne 16 ]]; then
            err "IV must be exactly 16 characters"
            exit 1
        fi
        ENCRYPT_KEY_HEX="$(printf '%s' "$ENCRYPT_KEY" | xxd -ps -c 200)"
        ENCRYPT_IV_HEX="$(printf '%s' "$ENCRYPT_IV" | xxd -ps -c 200)"
        ok "Encryption key and IV accepted"
    fi

    generate_bark_push_script
}

print_bark_hooks() {
    header "Claude Code Hooks Configuration"

    local push_script="$DATA_DIR/bark-push.sh"
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
            "command": "${push_script} 'Claude is waiting for input'"
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
            "command": "/usr/bin/jq -r '.message // empty' | grep . | ${push_script}"
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

print_bark_instructions() {
    header "Client Setup"

    echo -e "${BOLD}Phone (Bark app):${RESET}"
    echo "  1. Install Bark from the App Store"
    echo "  2. Open Bark → tap \"Servers\" → add your server: $BASE_URL"

    if [[ -n "$ENCRYPT_KEY" ]]; then
        echo "  3. Go to the app homepage → \"Push Encryption\""
        echo "  4. Select algorithm: AES-128-CBC"
        echo "  5. Set Key:  $ENCRYPT_KEY"
        echo "  6. Set IV:   $ENCRYPT_IV"
        echo "  7. Tap Done to save"
        echo
        warn "Save these values — you need them if you re-install the app:"
        echo "  Key: $ENCRYPT_KEY"
        echo "  IV:  $ENCRYPT_IV"
    else
        echo "  3. Notifications arrive automatically — no topics to subscribe to"
    fi
    echo

    local push_script="$DATA_DIR/bark-push.sh"
    echo -e "${BOLD}Test it:${RESET}"
    echo "  ${push_script} 'Hello from cc-notify!'"
}

# --- ntfy ---

setup_ntfy() {
    # Generate credentials
    SUB_USERNAME="claude-user"
    SUB_PASSWORD="$(openssl rand -hex 12)"
    HOOKS_TOKEN="tk_$(openssl rand -hex 15 | head -c 29)"

    header "Deploying ntfy with Podman Quadlet"

    mkdir -p "$DATA_DIR"
    render_template "$SCRIPT_DIR/ntfy/server.yml.template" "$DATA_DIR/server.yml"
    ok "Config written to $DATA_DIR/server.yml"

    local quadlet_dir="$HOME/.config/containers/systemd"
    mkdir -p "$quadlet_dir"

    # ntfy host and container ports are the same
    local content
    content="$(cat "$SCRIPT_DIR/ntfy/ntfy.container")"
    content="${content//8098:8098/${PORT}:${PORT}}"
    content="${content//127.0.0.1:8098/127.0.0.1:${PORT}}"
    echo "$content" > "$quadlet_dir/ntfy.container"
    ok "Quadlet installed to $quadlet_dir/ntfy.container"

    systemctl --user daemon-reload
    systemctl --user start ntfy
    wait_for_healthy "ntfy" "/v1/health"

    systemctl --user enable ntfy 2>/dev/null || true
    ok "Enabled auto-start on login"

    # Create users and set access
    header "Setting up authentication"

    echo "$SUB_PASSWORD" | podman exec -i ntfy ntfy user add --role=user "$SUB_USERNAME" 2>/dev/null || true
    ok "Created subscriber user: $SUB_USERNAME"

    local hooks_password
    hooks_password="$(openssl rand -hex 16)"
    echo "$hooks_password" | podman exec -i ntfy ntfy user add --role=user "claude-hooks" 2>/dev/null || true

    podman exec ntfy ntfy access "$SUB_USERNAME" 'claude' read-write 2>/dev/null || true
    podman exec ntfy ntfy access "claude-hooks" 'claude' write-only 2>/dev/null || true
    ok "Authentication configured"
}

print_ntfy_hooks() {
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
            "command": "/usr/bin/curl -s -H 'Authorization: Bearer ${HOOKS_TOKEN}' -H 'Title: Claude Code' -H 'Tags: robot' -d 'Claude is waiting for input' ${BASE_URL}/claude"
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
            "command": "/usr/bin/jq -r '.message // empty' | grep . | /usr/bin/curl -s -H 'Authorization: Bearer ${HOOKS_TOKEN}' -H 'Title: Claude Code' -H 'Tags: bell' -d @- ${BASE_URL}/claude"
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

print_ntfy_instructions() {
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
    echo "Self-hosted push notifications for Claude Code."
    echo

    # Check prerequisites
    local missing=()
    for cmd in curl jq podman systemctl; do
        has_cmd "$cmd" || missing+=("$cmd")
    done
    if (( ${#missing[@]} > 0 )); then
        err "Missing required commands: ${missing[*]}"
        [[ " ${missing[*]} " == *" podman "* ]] && err "Install Podman: https://podman.io/docs/installation"
        [[ " ${missing[*]} " == *" jq "* ]] && err "Install jq: sudo dnf install jq / sudo apt install jq"
        exit 1
    fi

    # Backend choice
    BACKEND="$(prompt_choice "Which notification backend?" \
        "Bark — iOS app, simple device key auth (recommended)" \
        "ntfy — Android + iOS + browser, topic-based with user auth")"

    if [[ "$BACKEND" == "1" ]]; then
        BACKEND="bark"
        local default_port=8099
    else
        BACKEND="ntfy"
        local default_port=8098
        # ntfy needs openssl for credential generation
        if ! has_cmd openssl; then
            err "Missing required command: openssl (needed for ntfy credential generation)"
            exit 1
        fi
    fi

    # Port
    PORT="$(prompt_value "Port for ${BACKEND}" "$default_port")"

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

    BASE_URL="$(prompt_value "Base URL (used in hooks and app config)" "$default_base_url")"

    # Deploy backend
    if [[ "$BACKEND" == "bark" ]]; then
        setup_bark
    else
        setup_ntfy
    fi

    # Tailscale Serve
    setup_tailscale_serve

    # Output
    if [[ "$BACKEND" == "bark" ]]; then
        print_bark_hooks
        print_bark_instructions
    else
        print_ntfy_hooks
        print_ntfy_instructions
    fi

    header "Done!"
    echo "${BACKEND} is running at $BASE_URL"
    if [[ "$BACKEND" == "bark" ]]; then
        echo "Notifications will be pushed directly to your Bark app."
    else
        echo "Subscribe to the 'claude' topic in your ntfy app to receive notifications."
    fi
}

main "$@"
