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

1. Detect your OS and container runtime (Podman, Docker, or neither)
2. Deploy ntfy with authentication enabled
3. Configure Tailscale Serve for HTTPS access from your phone
4. Generate the hooks JSON for `~/.claude/settings.json`

### Requirements

- **Podman** *(tested)*, Docker, or neither (downloads the ntfy binary)
- **[Tailscale](https://tailscale.com/)** for phone notifications *(tested, recommended)*
- `curl`, `jq`, `openssl`

## Subscribing to Notifications

After running `setup.sh`, subscribe on your phone or browser.

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
agent ──hook──▶ jq + curl ──▶ ntfy (127.0.0.1:8098) ──▶ tailscale serve ──▶ phone
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

**Hook not firing:** hooks log to stderr in your terminal. Test the `curl` command from the hooks config manually.

**Podman permission denied:** `systemctl --user enable --now podman.socket`

## License

[MIT](LICENSE)
