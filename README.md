# cc-notify

Get push notifications on your phone when [Claude Code](https://docs.anthropic.com/en/docs/claude-code) needs your input.

Self-hosted [ntfy](https://ntfy.sh) server with [Claude Code hooks](https://docs.anthropic.com/en/docs/claude-code/hooks). Notifications travel over a direct [WireGuard](https://www.wireguard.com/) tunnel via [Tailscale Serve](https://tailscale.com/kb/1312/serve) — no third-party server ever sees your messages.

## Quick Start

```bash
git clone https://github.com/buntingszn/cc-notify.git
cd cc-notify
./setup.sh
```

The setup script will:

1. Detect your OS and container runtime (Podman, Docker, or neither)
2. Deploy ntfy with authentication enabled
3. Configure [Tailscale Serve](https://tailscale.com/kb/1312/serve) for HTTPS access from your phone
4. Generate the hooks JSON for `~/.claude/settings.json`

### Requirements

- **Podman** *(tested)*, Docker, or neither (downloads the ntfy binary)
- **[Tailscale](https://tailscale.com/)** for phone notifications *(tested, recommended)*
- `curl` and `openssl`

## Subscribing to Notifications

After running `setup.sh`, subscribe on your phone or browser to start receiving notifications.

### Phone

1. Install the [ntfy app](https://ntfy.sh/#subscribe-phone) (Android / iOS)
2. Settings → **Add default server** → enter your Tailscale URL (e.g., `https://your-host.ts.net`)
3. Settings → **Manage users** → add the subscriber credentials from setup
4. Subscribe to the **claude** topic

Your phone must be on your Tailscale network.

### Browser

1. Open your ntfy URL and log in with your subscriber credentials
2. Subscribe to the **claude** topic and allow browser notifications

## How It Works

```
Claude Code ──hook──▶ curl ──▶ ntfy (127.0.0.1:8098) ──▶ tailscale serve ──▶ phone
```

ntfy runs on localhost. Claude Code [hooks](https://docs.anthropic.com/en/docs/claude-code/hooks) fire `curl` commands that POST to ntfy on two events:

| Hook | Fires when | Notification |
|------|-----------|--------------|
| **Stop** | Claude finishes and waits for input | "Claude is waiting for input" |
| **Notification** | Claude sends a notification | The message content |

Tailscale Serve exposes ntfy over HTTPS to your tailnet — auto-provisioned TLS, no port forwarding, accessible from any device on your network.

## Security

**With Tailscale Serve** (recommended):

- Notifications travel over a **direct WireGuard tunnel** between your machine and your phone — point-to-point, end-to-end encrypted.
- Tailscale's coordination server sees connection metadata (which devices, which ports) but **never sees message content, tokens, or notification text**.
- Access is limited to your tailnet. Nothing is exposed to the public internet.

**Without Tailscale** (localhost only):

- All traffic stays on `127.0.0.1`. Only useful for same-machine browser notifications.

**ntfy auth model:**

- Anonymous access is disabled (`auth-default-access: deny-all`).
- The hooks user has **write-only** access (can publish, cannot subscribe).
- The subscriber user has **read-write** access.
- Tokens are generated via `openssl rand`.

## Manual Setup

If you prefer not to use `setup.sh`, expand the relevant method below.

<details>
<summary><strong>Podman Quadlet (Linux + systemd)</strong></summary>

```bash
mkdir -p ~/.local/share/cc-notify
cp ntfy/server.yml.template ~/.local/share/cc-notify/server.yml
# Edit server.yml: set base-url and listen-http

mkdir -p ~/.config/containers/systemd
cp ntfy/ntfy.container ~/.config/containers/systemd/
systemctl --user daemon-reload
systemctl --user start ntfy

podman exec ntfy ntfy user add --role=user yourname
podman exec ntfy ntfy token add --label=claude-hooks yourname
```

</details>

<details>
<summary><strong>Docker Compose</strong></summary>

```bash
mkdir -p data
cp ntfy/server.yml.template data/server.yml
# Edit server.yml: set base-url and listen-http

docker compose -f ntfy/docker-compose.yml up -d

docker compose -f ntfy/docker-compose.yml exec ntfy ntfy user add --role=user yourname
docker compose -f ntfy/docker-compose.yml exec ntfy ntfy token add --label=claude-hooks yourname
```

</details>

<details>
<summary><strong>Bare binary</strong></summary>

```bash
# Download
curl -L "https://github.com/binwiederhier/ntfy/releases/latest/download/ntfy_$(uname -s)_$(uname -m | sed 's/x86_64/amd64/').tar.gz" | tar xz
sudo mv ntfy_*/ntfy /usr/local/bin/

mkdir -p ~/.local/share/cc-notify
cp ntfy/server.yml.template ~/.local/share/cc-notify/server.yml
# Edit server.yml: set base-url and listen-http

ntfy serve --config ~/.local/share/cc-notify/server.yml
```

</details>

<details>
<summary><strong>Tailscale Serve (manual)</strong></summary>

```bash
sudo tailscale serve --bg --https 443 http://127.0.0.1:8098
```

</details>

## Reverse Proxy Alternatives

If you don't use Tailscale, expose ntfy via a reverse proxy with TLS.

<details>
<summary><strong>Caddy</strong></summary>

```
notify.example.com {
    reverse_proxy 127.0.0.1:8098
}
```

</details>

<details>
<summary><strong>nginx</strong></summary>

```nginx
server {
    listen 443 ssl;
    server_name notify.example.com;

    location / {
        proxy_pass http://127.0.0.1:8098;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

</details>

## Troubleshooting

**Test ntfy directly:**

```bash
curl -H "Authorization: Bearer YOUR_TOKEN" -d "test" http://127.0.0.1:8098/claude
```

**Check ntfy is running:**

```bash
# Podman / bare binary
systemctl --user status ntfy

# Docker
docker compose ps

# Any method
curl http://127.0.0.1:8098/v1/health
```

**Hook not firing:** hooks log to stderr in your terminal. Test the `curl` command from the hooks JSON manually.

**Podman permission denied:** `systemctl --user enable --now podman.socket`

## License

[MIT](LICENSE)
