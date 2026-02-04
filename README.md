# cc-notify

Get push notifications on your phone when your AI coding agent needs your input.

Runs a self-hosted [Bark](https://github.com/Finb/Bark) or [ntfy](https://ntfy.sh) server and wires it into your agent's hook system. Built for [Claude Code](https://docs.anthropic.com/en/docs/claude-code), works with [Cursor](#other-tools), [Gemini CLI](#other-tools), and [others](#other-tools).

With [Tailscale Serve](https://tailscale.com/kb/1312/serve), notifications travel over a direct WireGuard tunnel — no third-party server ever sees your messages.

## Quick Start

```bash
git clone https://github.com/buntingszn/cc-notify.git
cd cc-notify
./setup.sh
```

The setup script prompts you to choose a backend:

1. **Bark** (recommended) — deploys bark-server, prompts for your device key, prints hooks JSON
2. **ntfy** — deploys ntfy with generated credentials and bearer token, prints hooks JSON

Both paths deploy as a Podman Quadlet (auto-starts on login) and optionally configure Tailscale Serve for HTTPS access from your phone.

### Requirements

- **Linux** with **Podman** and **systemd**
- **[Tailscale](https://tailscale.com/)** for phone notifications *(recommended)*
- `curl`, `jq` (encryption and ntfy also need `openssl`)

## Bark vs ntfy

Bark and ntfy are both self-hosted notification servers. They take different approaches:

**Bark** is purpose-built for Apple Push Notification service (APNs). Your self-hosted server talks directly to Apple — no relay, no middle server. Setup is minimal: install the iOS app, copy your device key, done. The trade-off is that it's iOS-only and has no web UI.

**ntfy** is a general-purpose pub/sub notification server. It supports Android, iOS, and browser notifications. It has a web UI, topic-based routing, user auth with granular ACLs, and attachments. The trade-off is more moving parts: you manage users, tokens, topics, and an `upstream-base-url` relay for iOS push delivery.

| | Bark | ntfy |
|---|---|---|
| **iOS push** | Direct to APNs (no relay) | Via ntfy.sh relay (message ID only) |
| **Android** | No | Yes |
| **Browser** | No | Yes |
| **Auth model** | Device key (one token) | Users + topics + ACLs |
| **Setup** | Install app, paste key | Install app, configure server, add user, subscribe to topic |
| **Config files** | None | `server.yml` |
| **Web UI** | No | Yes |

## Subscribing — Bark (default)

1. Install [Bark](https://apps.apple.com/us/app/bark-customed-notifications/id1403753865) from the App Store
2. Open Bark → tap **Servers** → add your server URL (e.g., `https://your-host.ts.net`)
3. Notifications arrive automatically — no topics to subscribe to

Your phone must be on your Tailscale network (if using Tailscale Serve).

## Subscribing — ntfy (alternative)

### Phone

1. Install the [ntfy app](https://ntfy.sh/#subscribe-phone) (Android / iOS)
2. Settings → **Add default server** → enter your Tailscale URL (e.g., `https://your-host.ts.net`)
3. Settings → **Manage users** → add the subscriber credentials from setup
4. Subscribe to the **claude** topic

Your phone must be on your Tailscale network.

> **iOS push delivery:** The server forwards message IDs (not content) to ntfy.sh so the iOS app can receive instant push notifications. Your actual notification text never leaves your server.

### Browser

1. Open your ntfy URL and log in with your subscriber credentials
2. Subscribe to the **claude** topic and allow browser notifications

## How It Works

**Bark (with encryption):**

```
agent ──hook──> bark-push.sh ──AES-128-CBC──> bark (127.0.0.1:8099) ──APNs──> iPhone (decrypts on-device)
```

**ntfy:**

```
agent ──hook──> jq + curl ──> ntfy (127.0.0.1:8098) ──tailscale serve──> phone
                                       │
                                       └──> ntfy.sh (message ID only, for iOS push)
```

Both backends run on localhost. Agent hooks fire shell commands that POST notifications. Two events are wired up:

| Hook | Fires when | Notification |
|------|-----------|--------------|
| **Stop** | Agent finishes and waits for input | "Claude is waiting for input" |
| **Notification** | Agent sends a notification | The message content (parsed from stdin JSON via `jq`) |

Tailscale Serve exposes the backend over HTTPS to your tailnet — auto-provisioned TLS, no port forwarding, accessible from any device on your network.

> **Note:** Claude Code hooks work regardless of which model provider you use (Anthropic, OpenAI, Google, Bedrock, etc.). The hooks are a client-side feature.

## Other Tools

The notification server and Tailscale setup are tool-agnostic. Only the hooks configuration differs per tool. After running `setup.sh`, use the generated push script (`~/.local/share/cc-notify/bark-push.sh` for Bark) or adapt the `curl` commands to your tool's config format.

The push script accepts a message as an argument or reads from stdin, and handles encryption automatically:

```bash
# Fixed message
~/.local/share/cc-notify/bark-push.sh 'Agent is waiting for input'

# Piped message
echo 'Task complete' | ~/.local/share/cc-notify/bark-push.sh
```

### Cursor

Place in `.cursor/hooks.json` at your project root.

**Bark:**

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

**ntfy:**

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
            "command": "curl -s -H 'Authorization: Bearer YOUR_TOKEN' -H 'Title: Cursor' -H 'Tags: robot' -d 'Cursor is waiting for input' https://your-host.ts.net/claude"
          }
        ]
      }
    ]
  }
}
```

### Gemini CLI

Gemini CLI hooks go in `.gemini/settings.json`.

**Bark:**

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

**ntfy:**

```json
{
  "hooks": {
    "Notification": [
      {
        "command": "jq -r '.message // empty' | grep . | curl -s -H 'Authorization: Bearer YOUR_TOKEN' -H 'Title: Gemini CLI' -H 'Tags: bell' -d @- https://your-host.ts.net/claude"
      }
    ]
  }
}
```

### Aider

```bash
# Bark
aider --notifications-command "~/.local/share/cc-notify/bark-push.sh 'Aider is waiting for input'"

# ntfy
aider --notifications-command "curl -s -H 'Authorization: Bearer YOUR_TOKEN' -d 'Aider is waiting for input' https://your-host.ts.net/claude"
```

### Codex CLI

Add under `[notify]` in `config.toml`:

```toml
# Bark
[notify]
command = "~/.local/share/cc-notify/bark-push.sh 'Codex is waiting for input'"

# ntfy
[notify]
command = "curl -s -H 'Authorization: Bearer YOUR_TOKEN' -d 'Codex is waiting for input' https://your-host.ts.net/claude"
```

### Any tool with shell hooks

For Bark, use the generated push script. For ntfy, use `curl` with your bearer token.

**Bark:**

```bash
~/.local/share/cc-notify/bark-push.sh 'Agent is waiting for input'
```

**ntfy:**

```bash
curl -s \
  -H 'Authorization: Bearer YOUR_TOKEN' \
  -H 'Title: My Agent' \
  -H 'Tags: robot' \
  -d 'Agent is waiting for input' \
  https://your-host.ts.net/claude
```

## Security

### Bark

- The bark-server **binds to localhost only** (`127.0.0.1`). It is not reachable from your LAN without Tailscale Serve.
- The **device key** is the only credential. Anyone with it can push to your device.
- Bark pushes directly to **Apple Push Notification service** — no relay server involved.
- With Tailscale Serve, traffic is encrypted over a WireGuard tunnel. Without it, traffic stays on loopback.
- **End-to-end encryption** is offered during setup (recommended). When enabled, `setup.sh` generates an AES-128-CBC key and IV, creates an encrypted push script (`~/.local/share/cc-notify/bark-push.sh`), and prints the key/IV for you to enter in the Bark iOS app. The bark-server and APNs only ever see ciphertext — decryption happens on-device.

### ntfy

- The ntfy server **binds to localhost only** (`127.0.0.1`). It is not reachable from your LAN without Tailscale Serve.

**With Tailscale Serve** (recommended):

- Notifications travel over a **direct WireGuard tunnel** between your machine and your phone — point-to-point, end-to-end encrypted.
- Tailscale's coordination server sees connection metadata (which devices, which ports) but **never sees message content, tokens, or notification text**.
- Access is limited to your tailnet. Nothing is exposed to the public internet.

**Without Tailscale** (localhost only):

- All traffic stays on `127.0.0.1`. Only useful for same-machine browser notifications.

**iOS push delivery** (`upstream-base-url`):

- ntfy forwards only the message ID to ntfy.sh so the iOS app receives instant push notifications.
- The actual notification content is fetched directly from your server by the app — ntfy.sh never sees it.

**ntfy auth model:**

- Anonymous access is disabled (`auth-default-access: deny-all`).
- The hooks user has **write-only** access (can publish, cannot subscribe).
- The subscriber user has **read-write** access.
- Hooks bearer token is declared in `server.yml` (generated via `openssl rand`).

## Manual Setup

<details>
<summary><strong>Bark — Podman Quadlet</strong></summary>

```bash
mkdir -p ~/.local/share/cc-notify
mkdir -p ~/.config/containers/systemd
cp bark/bark.container ~/.config/containers/systemd/
systemctl --user daemon-reload
systemctl --user start bark

# Verify
curl http://127.0.0.1:8099/healthz

# Test push (use your device key from the Bark app)
curl -H 'Content-Type: application/json' \
  -d '{"device_key":"YOUR_KEY","title":"Test","body":"Hello!"}' \
  http://127.0.0.1:8099/push
```

</details>

<details>
<summary><strong>ntfy — Podman Quadlet</strong></summary>

```bash
mkdir -p ~/.local/share/cc-notify
cp ntfy/server.yml.template ~/.local/share/cc-notify/server.yml
# Edit server.yml: set base-url, listen-http, and auth-tokens

mkdir -p ~/.config/containers/systemd
cp ntfy/ntfy.container ~/.config/containers/systemd/
systemctl --user daemon-reload
systemctl --user start ntfy

# Create subscriber user
podman exec -i ntfy ntfy user add --role=user claude-user
# Create hooks user
podman exec -i ntfy ntfy user add --role=user claude-hooks
# Set access
podman exec ntfy ntfy access claude-user claude read-write
podman exec ntfy ntfy access claude-hooks claude write-only
```

</details>

<details>
<summary><strong>Tailscale Serve (manual)</strong></summary>

```bash
sudo tailscale serve --bg --https 443 http://127.0.0.1:8099   # Bark
sudo tailscale serve --bg --https 443 http://127.0.0.1:8098   # ntfy
```

</details>

## Troubleshooting

### Bark

**Test push directly:**

```bash
~/.local/share/cc-notify/bark-push.sh 'Hello from cc-notify!'
```

**Check bark is running:**

```bash
systemctl --user status bark
curl http://127.0.0.1:8099/healthz
```

**No notification on phone:** Verify your device key is correct (shown on the Bark app main screen). Check that your phone is on the same Tailscale network if using Tailscale Serve.

**Encryption not working:** Verify the Bark app has the same algorithm (AES-128-CBC), key, and IV configured under "Push Encryption". The key and IV are saved in `~/.local/share/cc-notify/bark-push.sh`.

### ntfy

**Test ntfy directly:**

```bash
curl -H "Authorization: Bearer YOUR_TOKEN" -d "test" http://127.0.0.1:8098/claude
```

**Check ntfy is running:**

```bash
systemctl --user status ntfy
curl http://127.0.0.1:8098/v1/health
```

**iOS notifications not instant:** Verify `upstream-base-url: "https://ntfy.sh"` is set in `~/.local/share/cc-notify/server.yml`.

### General

**Hook not firing:** Hooks log to stderr in your terminal. Test the `curl` command from the hooks config manually.

**Podman permission denied:** `systemctl --user enable --now podman.socket`

## License

[MIT](LICENSE)
