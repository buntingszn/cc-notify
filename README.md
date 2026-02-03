# cc-notify

Get push notifications on your phone when your AI coding agent needs your input.

Runs a self-hosted [ntfy](https://ntfy.sh) server and wires it into your agent's hook system. Built for [Claude Code](https://docs.anthropic.com/en/docs/claude-code), works with [Cursor](#other-tools), [Gemini CLI](#other-tools), and [others](#other-tools).

With [Tailscale Serve](https://tailscale.com/kb/1312/serve), notifications travel over a direct WireGuard tunnel — no third-party server ever sees your messages.

## Quick Start

```bash
git clone https://github.com/buntingszn/cc-notify.git
cd cc-notify
./setup.sh
```

The setup script will:

1. Deploy ntfy as a Podman Quadlet (auto-starts on login)
2. Generate subscriber credentials and a hooks bearer token
3. Configure Tailscale Serve for HTTPS access from your phone
4. Print the hooks JSON for `~/.claude/settings.json`

### Requirements

- **Linux** with **Podman** and **systemd**
- **[Tailscale](https://tailscale.com/)** for phone notifications *(recommended)*
- `curl`, `jq`, `openssl`

## Subscribing to Notifications

After running `setup.sh`, subscribe on your phone or browser using the generated credentials.

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

```
agent ──hook──▶ jq + curl ──▶ ntfy (127.0.0.1:8098) ──tailscale serve──▶ phone
                                       │
                                       └──▶ ntfy.sh (message ID only, for iOS push)
```

ntfy runs on localhost. Agent hooks fire shell commands that POST to ntfy. Two events are wired up:

| Hook | Fires when | Notification |
|------|-----------|--------------|
| **Stop** | Agent finishes and waits for input | "Claude is waiting for input" |
| **Notification** | Agent sends a notification | The message content (parsed from stdin JSON via `jq`) |

Tailscale Serve exposes ntfy over HTTPS to your tailnet — auto-provisioned TLS, no port forwarding, accessible from any device on your network.

> **Note:** Claude Code hooks work regardless of which model provider you use (Anthropic, OpenAI, Google, Bedrock, etc.). The hooks are a client-side feature.

## Other Tools

The ntfy server and Tailscale setup are tool-agnostic. Only the hooks configuration differs per tool. After running `setup.sh`, adapt the generated `curl` commands to your tool's config format.

### Cursor

Cursor hooks use nearly identical JSON. Place in `.cursor/hooks.json` at your project root:

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

Gemini CLI hooks go in `.gemini/settings.json`:

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

Aider supports a simple notification command flag:

```bash
aider --notifications-command "curl -s -H 'Authorization: Bearer YOUR_TOKEN' -d 'Aider is waiting for input' https://your-host.ts.net/claude"
```

### Codex CLI

Codex uses `config.toml`. Add under `[notify]`:

```toml
[notify]
command = "curl -s -H 'Authorization: Bearer YOUR_TOKEN' -d 'Codex is waiting for input' https://your-host.ts.net/claude"
```

### Any tool with shell hooks

The core notification is a single `curl` command. If your tool can run a shell command on completion, use:

```bash
curl -s \
  -H 'Authorization: Bearer YOUR_TOKEN' \
  -H 'Title: My Agent' \
  -H 'Tags: robot' \
  -d 'Agent is waiting for input' \
  https://your-host.ts.net/claude
```

Replace `YOUR_TOKEN` and the URL with values from `~/.local/share/cc-notify/hooks.json`.

## Security

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
- Subscriber credentials are auto-generated during setup.

## Manual Setup

If you prefer not to use `setup.sh`:

<details>
<summary><strong>Podman Quadlet (Linux + systemd)</strong></summary>

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
sudo tailscale serve --bg --https 443 http://127.0.0.1:8098
```

</details>

## Troubleshooting

**Test ntfy directly:**

```bash
curl -H "Authorization: Bearer YOUR_TOKEN" -d "test" http://127.0.0.1:8098/claude
```

**Check ntfy is running:**

```bash
systemctl --user status ntfy
curl http://127.0.0.1:8098/v1/health
```

**Hook not firing:** hooks log to stderr in your terminal. Test the `curl` command from the hooks config manually.

**Podman permission denied:** `systemctl --user enable --now podman.socket`

**iOS notifications not instant:** verify `upstream-base-url: "https://ntfy.sh"` is set in `~/.local/share/cc-notify/server.yml`.

## License

[MIT](LICENSE)
