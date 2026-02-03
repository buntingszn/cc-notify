# cc-notify

Push notifications on your phone when Claude Code needs your input. Self-hosted [ntfy](https://ntfy.sh) server with Claude Code hooks. With Tailscale Serve, notifications travel directly to your phone over an encrypted WireGuard tunnel — no third-party server ever sees your messages.

> **Tested setup:** ntfy + Podman Quadlet + [Tailscale Serve](https://tailscale.com/kb/1312/serve) (HTTPS). Other deployment methods are supported but less battle-tested.

## How It Works

```
Claude Code ──hook──▶ curl POST ──▶ ntfy (127.0.0.1:8098)
                                         │
                                   tailscale serve
                                         │
                                    HTTPS on tailnet
                                         │
                                   ntfy app (phone)
```

ntfy runs locally. Tailscale Serve exposes it over HTTPS to your tailnet — encrypted, no port forwarding, accessible from your phone anywhere. The hooks send to localhost; Tailscale handles the rest.

Claude Code fires [hooks](https://docs.anthropic.com/en/docs/claude-code/hooks) on lifecycle events. Two matter here:

| Event | When it fires | You see |
|-------|--------------|---------|
| **Stop** | Claude finishes a turn and waits for input | "Claude is waiting for input" |
| **Notification** | Claude calls `send_notification` tool | The notification message |

## Prerequisites

You need **one** of:

- **Podman** (Linux with systemd) — auto-starts via quadlet *(tested)*
- **Docker** / Docker Compose — you manage lifecycle
- **Neither** — setup downloads the ntfy binary directly

Plus `openssl` and `curl` (almost certainly already installed).

For push notifications on your phone, you also need:

- **[Tailscale](https://tailscale.com/)** — provides HTTPS access to ntfy from your phone via `tailscale serve` *(tested, recommended)*
- Or a reverse proxy (Caddy, nginx) with TLS — see [Remote Access](#remote-access-alternatives)

## Quick Start

```bash
git clone https://github.com/buntingszn/cc-notify.git
cd cc-notify
chmod +x setup.sh
./setup.sh
```

The script will:
1. Detect your OS and available container runtime
2. Let you choose a deployment method
3. Generate auth credentials
4. Deploy ntfy
5. Print the hooks JSON to paste into `~/.claude/settings.json`
6. Print mobile/browser setup instructions

## Manual Setup

<details>
<summary><strong>Method 1: Podman Quadlet (Linux + systemd)</strong></summary>

```bash
# Create data directory
mkdir -p ~/.local/share/cc-notify

# Copy and edit server config
cp ntfy/server.yml.template ~/.local/share/cc-notify/server.yml
# Edit: set base-url and listen-http

# Install quadlet
mkdir -p ~/.config/containers/systemd
cp ntfy/ntfy.container ~/.config/containers/systemd/

# Reload and start
systemctl --user daemon-reload
systemctl --user start ntfy

# Create subscriber user
podman exec ntfy ntfy user add --role=user yourname

# Create access token for hooks
podman exec ntfy ntfy token add --label=claude-hooks yourname
```

</details>

<details>
<summary><strong>Method 2: Docker Compose</strong></summary>

```bash
# Create data directory
mkdir -p data

# Copy and edit server config
cp ntfy/server.yml.template data/server.yml
# Edit: set base-url and listen-http

# Start
docker compose -f ntfy/docker-compose.yml up -d

# Create subscriber user
docker compose -f ntfy/docker-compose.yml exec ntfy ntfy user add --role=user yourname

# Create access token for hooks
docker compose -f ntfy/docker-compose.yml exec ntfy ntfy token add --label=claude-hooks yourname
```

</details>

<details>
<summary><strong>Method 3: Bare Binary</strong></summary>

```bash
# Download ntfy
curl -L "https://github.com/binwiederhier/ntfy/releases/latest/download/ntfy_$(uname -s)_$(uname -m | sed 's/x86_64/amd64/').tar.gz" | tar xz
sudo mv ntfy_*/ntfy /usr/local/bin/

# Create data directory
mkdir -p ~/.local/share/cc-notify

# Copy and edit server config
cp ntfy/server.yml.template ~/.local/share/cc-notify/server.yml
# Edit: set base-url and listen-http

# Run directly
ntfy serve --config ~/.local/share/cc-notify/server.yml

# Or install the generated systemd/launchd service (setup.sh does this for you)
```

</details>

## Claude Code Hooks Configuration

After setup, add the hooks to `~/.claude/settings.json`. The hooks POST to your Tailscale HTTPS URL (or localhost if not using Tailscale):

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "curl -s -H 'Authorization: Bearer YOUR_TOKEN' -H 'Title: Claude Code' -H 'Tags: robot' -d 'Claude is waiting for input' https://your-host.tailnet-name.ts.net/claude"
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
            "command": "curl -s -H 'Authorization: Bearer YOUR_TOKEN' -H 'Title: Claude Code' -H 'Tags: bell' -d \"$CLAUDE_NOTIFICATION\" https://your-host.tailnet-name.ts.net/claude"
          }
        ]
      }
    ]
  }
}
```

The `setup.sh` script generates this with your actual token and URL (auto-detects Tailscale hostname).

## Mobile / Browser Client Setup

### Phone (Android / iOS)

1. Install the [ntfy app](https://ntfy.sh/#subscribe-phone) from your app store
2. Open the app → Settings → **Add default server**
3. Enter your Tailscale ntfy URL (e.g., `https://your-host.tailnet-name.ts.net`)
4. Go to Settings → **Manage users** → add your subscriber credentials
5. Subscribe to the `claude` topic

Your phone needs to be on your Tailscale network (install the Tailscale app if not already).

### Browser

1. Open your ntfy URL (e.g., `https://your-host.tailnet-name.ts.net`)
2. Log in with your subscriber credentials
3. Subscribe to the `claude` topic
4. Allow browser notifications when prompted

### Desktop (ntfy CLI)

```bash
ntfy subscribe --token YOUR_SUBSCRIBER_TOKEN https://your-host.tailnet-name.ts.net/claude
```

## Tailscale Serve (Recommended)

The tested setup uses [Tailscale Serve](https://tailscale.com/kb/1312/serve) to expose ntfy over HTTPS on your tailnet. The `setup.sh` script offers to configure this automatically when Tailscale is detected.

Manual setup:

```bash
# Expose ntfy over HTTPS on your tailnet (runs in background)
sudo tailscale serve --bg --https 443 http://127.0.0.1:8098

# Your ntfy is now at https://your-hostname.tailnet-name.ts.net
# Use this as your base URL in hooks and the ntfy app
```

This gives you:
- HTTPS with auto-provisioned TLS certificates
- Accessible from any device on your tailnet (phone, laptop, etc.)
- No port forwarding or public DNS needed
- Works from anywhere (home, office, mobile data)

Make sure your phone has the Tailscale app installed and is connected to the same tailnet.

## Remote Access (Alternatives)

If you don't use Tailscale, you can expose ntfy with a reverse proxy instead.

### Caddy

```
notify.example.com {
    reverse_proxy 127.0.0.1:8098
}
```

### nginx

```nginx
server {
    listen 443 ssl;
    server_name notify.example.com;

    location / {
        proxy_pass http://127.0.0.1:8098;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $remote_addr;

        # WebSocket support (for live updates)
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

## Security

**Without Tailscale Serve** (localhost only):
- No data leaves your machine. Hooks POST to `127.0.0.1`, ntfy runs locally.
- Only useful for browser notifications on the same machine.

**With Tailscale Serve** (recommended setup):
- Notification content travels over a **direct WireGuard tunnel** between your machine and your phone. It does not pass through Tailscale's servers — the connection is point-to-point and end-to-end encrypted.
- Tailscale's coordination server sees connection metadata (which devices are talking, that you're serving on port 443) but **never sees message content, tokens, or notification text**.
- TLS certificates are auto-provisioned. No self-signed certs or manual DNS.
- Access is limited to devices on your tailnet — not exposed to the public internet.

**General:**
- Auth is required on ntfy — anonymous access is disabled (`auth-default-access: deny-all`).
- The hooks user has **write-only** access to the `claude` topic (can publish, cannot read).
- The subscriber user has **read-write** access (can subscribe and see messages).
- Tokens are long random hex strings generated by `openssl rand`.

## Troubleshooting

### Notifications not arriving

```bash
# Test ntfy directly
curl -H "Authorization: Bearer YOUR_TOKEN" -d "test" http://127.0.0.1:8098/claude

# Check ntfy is running
# Podman:
systemctl --user status ntfy
# Docker:
docker compose ps
# Binary:
curl http://127.0.0.1:8098/v1/health
```

### Hook not firing

Check Claude Code hook logs:
```bash
# Hooks log to stderr — check your terminal output
# Or test the hook command manually in your shell
```

### Permission denied on Podman socket

```bash
systemctl --user enable --now podman.socket
```

## License

MIT — see [LICENSE](LICENSE).
