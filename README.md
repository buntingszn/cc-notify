# cc-notify

Push notifications on your phone when Claude Code needs your input. Self-hosted [ntfy](https://ntfy.sh) server with Claude Code hooks — no data leaves your machine.

## How It Works

```
Claude Code ──hook──▶ curl POST ──▶ ntfy (localhost:8098) ──▶ ntfy app (phone/browser)
                                         │
                                    your machine
                                   (nothing leaves)
```

Claude Code fires [hooks](https://docs.anthropic.com/en/docs/claude-code/hooks) on lifecycle events. Two matter here:

| Event | When it fires | You see |
|-------|--------------|---------|
| **Stop** | Claude finishes a turn and waits for input | "Claude is waiting for input" |
| **Notification** | Claude calls `send_notification` tool | The notification message |

## Prerequisites

You need **one** of:

- **Podman** (Linux with systemd) — auto-starts via quadlet
- **Docker** / Docker Compose — you manage lifecycle
- **Neither** — setup downloads the ntfy binary directly

Plus `openssl` and `curl` (almost certainly already installed).

## Quick Start

```bash
git clone https://github.com/yves-biener/cc-notify.git
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

After setup, add the hooks to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "curl -s -H 'Authorization: Bearer YOUR_TOKEN' -H 'Title: Claude Code' -H 'Tags: robot' -d 'Claude is waiting for input' http://127.0.0.1:8098/claude"
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
            "command": "curl -s -H 'Authorization: Bearer YOUR_TOKEN' -H 'Title: Claude Code' -H 'Tags: bell' -d \"$CLAUDE_NOTIFICATION\" http://127.0.0.1:8098/claude"
          }
        ]
      }
    ]
  }
}
```

The `setup.sh` script generates this with your actual token and URL.

## Mobile / Browser Client Setup

### Phone (Android / iOS)

1. Install the [ntfy app](https://ntfy.sh/#subscribe-phone) from your app store
2. Open the app → Settings → **Add default server**
3. Enter your ntfy URL (e.g., `http://YOUR_IP:8098`)
4. Go to Settings → **Manage users** → add your subscriber credentials
5. Subscribe to the `claude` topic

### Browser

1. Open `http://127.0.0.1:8098` in your browser
2. Log in with your subscriber credentials
3. Subscribe to the `claude` topic
4. Allow browser notifications when prompted

### Desktop (ntfy CLI)

```bash
ntfy subscribe --token YOUR_SUBSCRIBER_TOKEN http://127.0.0.1:8098/claude
```

## Remote Access (Optional)

If you want notifications on your phone away from home, you need to expose ntfy.

### Option A: Tailscale Serve (recommended)

If you use [Tailscale](https://tailscale.com/), this is the simplest path:

```bash
# Expose ntfy over HTTPS on your tailnet
tailscale serve --bg https+insecure://127.0.0.1:8098

# Your ntfy is now at https://your-hostname.tailnet-name.ts.net
# Use this URL in your phone's ntfy app
```

### Option B: Reverse Proxy (Caddy)

```
notify.example.com {
    reverse_proxy 127.0.0.1:8098
}
```

### Option C: Reverse Proxy (nginx)

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

- **No message content leaves your machine** by default. ntfy runs locally and hooks send to `127.0.0.1`.
- Auth is required — anonymous access is disabled.
- The hooks token is a long random hex string with publish-only permissions.
- If you expose ntfy remotely, use HTTPS (Tailscale Serve or a reverse proxy with TLS).

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
