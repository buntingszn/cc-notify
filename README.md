# cc-notify

Get push notifications on your phone when your AI coding agent needs your input.

Runs a self-hosted [Bark](https://github.com/Finb/Bark) or [ntfy](https://ntfy.sh) server and wires it into your agent's hook system. Built for [Claude Code](https://docs.anthropic.com/en/docs/claude-code), works with [Cursor](#other-tools), [Gemini CLI](#other-tools), [Aider](#other-tools), and [others](#other-tools).

## Quick Start

```bash
git clone https://github.com/buntingszn/cc-notify.git
cd cc-notify
./setup.sh
```

The setup script:

1. Deploys **Bark** (recommended) or **ntfy** as a Podman Quadlet (auto-starts on login)
2. Optionally enables **AES-128-CBC end-to-end encryption** (Bark) — the server and APNs never see plaintext
3. Optionally configures **[Tailscale Serve](https://tailscale.com/kb/1312/serve)** for HTTPS access over a WireGuard tunnel
4. Generates a push script and hooks config for your agent

### Requirements

- **Linux** with **Podman** and **systemd**
- **[Tailscale](https://tailscale.com/)** for phone notifications *(recommended)*
- `curl`, `jq` (encryption and ntfy also need `openssl`)

## How It Works

```
agent ──hook──> bark-push.sh ──AES-128-CBC──> bark (localhost) ──APNs──> iPhone (decrypts on-device)
agent ──hook──> jq + curl ──────────────────> ntfy (localhost) ────────> phone/browser
```

Agent hooks fire shell commands that POST notifications to the local server. Three events are wired, each with a distinct sound and project-aware message:

| Hook | Fires when | Message | Sound |
|------|-----------|---------|-------|
| **Stop** | Agent finishes and waits for input | "Claude is waiting — *project*" | tink |
| **Notification** | Agent sends a notification | "*message* — *project*" | calypso |
| **PostToolUseFailure** | A Bash command fails | "Command failed: *cmd* — *project*" | bamboo |

The push script supports `BARK_SOUND` and `BARK_ICON` environment variables, so each hook can specify different notification sounds and a custom icon. Pass them as env var prefixes:

```bash
BARK_SOUND=tink BARK_ICON=https://example.com/icon.png ~/.local/share/cc-notify/bark-push.sh 'Hello'
```

> Hooks are a client-side feature — they work regardless of which model provider you use.

## Bark vs ntfy

| | Bark | ntfy |
|---|---|---|
| **Platforms** | iOS | Android, iOS, browser |
| **iOS push** | Direct to APNs | Via ntfy.sh relay (message ID only) |
| **Auth** | Device key | Users + topics + ACLs |
| **Encryption** | AES-128-CBC e2e (optional) | WireGuard transport only |
| **Setup** | Install app, paste key | Install app, configure server, add user, subscribe |
| **Web UI** | No | Yes |

## Subscribing

### Bark (default)

1. Install [Bark](https://apps.apple.com/us/app/bark-customed-notifications/id1403753865) from the App Store
2. Open Bark → **Servers** → add your server URL (e.g., `https://your-host.ts.net`)
3. If encryption was enabled during setup, go to **Push Encryption** → set **AES-128-CBC** with the key and IV shown by the setup script

### ntfy (alternative)

1. Install the [ntfy app](https://ntfy.sh/#subscribe-phone) (Android / iOS)
2. Settings → **Add default server** → your Tailscale URL
3. Settings → **Manage users** → add the subscriber credentials from setup
4. Subscribe to the **claude** topic

> **iOS push:** ntfy forwards only message IDs to ntfy.sh — your notification text never leaves your server.

## Other Tools

After running `setup.sh`, use the generated push script for Bark or adapt the `curl` commands for ntfy.

```bash
# Bark — fixed message or piped from stdin
~/.local/share/cc-notify/bark-push.sh 'Agent is waiting'
echo 'Task complete' | ~/.local/share/cc-notify/bark-push.sh
```

<details>
<summary><strong>Cursor</strong></summary>

Place in `.cursor/hooks.json` at your project root.

```json
{
  "version": 1,
  "hooks": {
    "stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "~/.local/share/cc-notify/bark-push.sh 'Cursor is waiting for input'"
          }
        ]
      }
    ]
  }
}
```

</details>

<details>
<summary><strong>Gemini CLI</strong></summary>

Add to `.gemini/settings.json`:

```json
{
  "hooks": {
    "Notification": [
      {
        "command": "jq -r '.message // empty' | grep . | ~/.local/share/cc-notify/bark-push.sh"
      }
    ]
  }
}
```

</details>

<details>
<summary><strong>Aider</strong></summary>

```bash
aider --notifications-command "~/.local/share/cc-notify/bark-push.sh 'Aider is waiting for input'"
```

</details>

<details>
<summary><strong>Codex CLI</strong></summary>

Add to `config.toml`:

```toml
[notify]
command = "~/.local/share/cc-notify/bark-push.sh 'Codex is waiting for input'"
```

</details>

<details>
<summary><strong>ntfy (any tool)</strong></summary>

Replace the push script with a `curl` command using your bearer token:

```bash
curl -s \
  -H 'Authorization: Bearer YOUR_TOKEN' \
  -H 'Title: My Agent' \
  -d 'Agent is waiting for input' \
  https://your-host.ts.net/claude
```

</details>

## Security

### Bark

- Binds to **localhost only** (`127.0.0.1`) — not reachable from LAN without Tailscale Serve
- Pushes directly to **Apple APNs** — no relay server
- **E2E encryption** (AES-128-CBC) encrypts on your machine, decrypts on-device — the bark-server and APNs only see ciphertext
- **Tailscale Serve** adds WireGuard transport encryption and HTTPS

### ntfy

- Binds to **localhost only** (`127.0.0.1`)
- **Tailscale Serve** provides a direct WireGuard tunnel — Tailscale's coordination server never sees message content
- iOS push uses `upstream-base-url` to forward **message IDs only** — ntfy.sh never sees notification text
- Auth: anonymous access disabled, hooks user is write-only, subscriber is read-write

## Manual Setup

<details>
<summary><strong>Bark</strong></summary>

```bash
mkdir -p ~/.local/share/cc-notify ~/.config/containers/systemd
cp bark/bark.container ~/.config/containers/systemd/
systemctl --user daemon-reload && systemctl --user start bark

# Verify
curl http://127.0.0.1:8099/healthz

# Copy bark-push-example.sh and fill in your device key / encryption values
cp bark/bark-push-example.sh ~/.local/share/cc-notify/bark-push.sh
chmod +x ~/.local/share/cc-notify/bark-push.sh
# Edit DEVICE_KEY, BASE_URL, ENC_KEY_HEX, ENC_IV_HEX

# Test
~/.local/share/cc-notify/bark-push.sh 'Hello from cc-notify!'
```

</details>

<details>
<summary><strong>ntfy</strong></summary>

```bash
mkdir -p ~/.local/share/cc-notify ~/.config/containers/systemd
cp ntfy/server.yml.template ~/.local/share/cc-notify/server.yml
# Edit server.yml: set base-url, listen-http, and auth-tokens

cp ntfy/ntfy.container ~/.config/containers/systemd/
systemctl --user daemon-reload && systemctl --user start ntfy

# Create users and set access
podman exec -i ntfy ntfy user add --role=user claude-user
podman exec -i ntfy ntfy user add --role=user claude-hooks
podman exec ntfy ntfy access claude-user claude read-write
podman exec ntfy ntfy access claude-hooks claude write-only
```

</details>

<details>
<summary><strong>Tailscale Serve</strong></summary>

```bash
sudo tailscale serve --bg --https 443 http://127.0.0.1:8099   # Bark
sudo tailscale serve --bg --https 443 http://127.0.0.1:8098   # ntfy
```

</details>

## Troubleshooting

**Test push:** `~/.local/share/cc-notify/bark-push.sh 'test'` (Bark) or `curl -H "Authorization: Bearer TOKEN" -d "test" http://127.0.0.1:8098/claude` (ntfy)

**Service not running:** `systemctl --user status bark` / `systemctl --user status ntfy`

**No notification:** Check device key (Bark app main screen) or subscriber credentials (ntfy). Verify phone is on Tailscale network.

**Encryption not working:** Verify the Bark app has matching algorithm (AES-128-CBC), key, and IV under Push Encryption. Values are in `~/.local/share/cc-notify/bark-push.sh`.

**Hook not firing:** Test the command from `~/.local/share/cc-notify/hooks.json` manually in your terminal.

**Podman permission denied:** `systemctl --user enable --now podman.socket`

## License

[MIT](LICENSE)
