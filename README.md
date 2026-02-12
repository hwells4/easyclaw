# EasyClaw

Get OpenClaw running on a secure server in under 10 minutes. One script handles everything — security hardening, dependencies, OpenClaw install, and a systemd service that keeps it running.

## What You Need

1. **A Hetzner Cloud account** — [Sign up here](https://console.hetzner.cloud/). Other providers (DigitalOcean, Contabo, AWS) work too, but Hetzner is cheapest.
2. **An SSH key pair** on your local machine (see below)
3. **API keys for OpenClaw** — the setup wizard will tell you exactly what to paste and when

### SSH Keys (Important)

EasyClaw disables password login and enforces SSH key authentication. If you don't already have an SSH key, generate one now on your **local machine** (not the server):

```bash
ssh-keygen -t ed25519 -C "your-email@example.com"
```

Press Enter to accept the default location. This creates two files:
- `~/.ssh/id_ed25519` — your private key (never share this)
- `~/.ssh/id_ed25519.pub` — your public key (you'll give this to Hetzner)

**Already have a key?** Check with `ls ~/.ssh/id_ed25519.pub`. If it exists, you're good.

## Step 1: Create a Server

### Option A: Hetzner Console (Easiest)

1. Log into [Hetzner Cloud Console](https://console.hetzner.cloud/)
2. Create a new project (or use the default)
3. Click **Add Server**
4. Choose:
   - **Location:** Ashburn (US) or wherever you're closest to
   - **Image:** Ubuntu 24.04
   - **Type:** CPX21 (4 vCPU, 8 GB RAM) — recommended for most users
   - **SSH Key:** Click "Add SSH Key" and paste the contents of `~/.ssh/id_ed25519.pub`
5. Click **Create & Buy Now** (~$5/month)
6. Copy the server's IP address

### Option B: Terraform (Automated)

If you prefer infrastructure-as-code, see [`terraform/`](terraform/). It provisions the server, firewall, and SSH key in one command.

### Server Size Guide

| RAM | CPU | ~Cost/mo | Best For |
|-----|-----|----------|----------|
| 4 GB | 2 cores | ~$4 | Light usage, single agent |
| **8 GB** | **4 cores** | **~$5** | **Most users** |
| 16 GB | 4 cores | ~$10 | Multiple agents, heavy usage |
| 32 GB | 8 cores | ~$27 | Power user, concurrent workloads |

## Step 2: Run EasyClaw

SSH into your new server as root and run:

```bash
ssh root@<your-server-ip>
```

Then:

```bash
curl -fsSL https://raw.githubusercontent.com/hwells4/easyclaw/main/setup.sh | sudo bash -s -- --install-openclaw
```

The setup wizard walks you through everything interactively. It takes about 5-8 minutes.

## What Happens During Setup

The wizard asks a few questions (username, which tools to install), then automatically:

1. **Creates a non-root user** (`claw` by default) with sudo access
2. **Hardens SSH** — disables root login, enforces key-only auth, limits retries to 3
3. **Configures firewall** — blocks everything except SSH (22), HTTP/S (80/443), and OpenClaw (7860)
4. **Enables Fail2ban** — bans IPs for 24 hours after 3 failed SSH attempts
5. **Sets up swap** — dynamically sized to match your RAM, prevents out-of-memory crashes
6. **Enables auto-updates** — security patches install automatically
7. **Installs tools** — Node.js 22, Homebrew, Docker, Claude Code, Codex
8. **Installs OpenClaw** — as the service user, not root
9. **Runs OpenClaw onboarding** — this is where you'll paste your API keys (Telegram bot token, model API key, etc.)
10. **Creates a systemd service** — OpenClaw gateway runs automatically and restarts on failure
11. **Installs temp cleanup** — daily cron clears stale files from `/tmp` without touching active processes

## Step 3: After Setup

Once the script finishes, copy your SSH key to the new user so you can log in directly:

```bash
# From your LOCAL machine (not the server):
ssh-copy-id claw@<your-server-ip>
```

Test it:

```bash
ssh claw@<your-server-ip>
```

Then verify everything is running:

```bash
sudo systemctl status openclaw-gateway   # Should be active
sudo ufw status                          # Should show allowed ports
sudo fail2ban-client status              # Should show sshd jail
swapon --show                            # Should show swap active
```

## Managing OpenClaw

```bash
# Start/stop/restart the gateway
sudo systemctl start openclaw-gateway
sudo systemctl stop openclaw-gateway
sudo systemctl restart openclaw-gateway

# View logs
sudo journalctl -u openclaw-gateway -f

# Edit secrets (API keys, tokens)
sudo vim /etc/openclaw-secrets
sudo systemctl restart openclaw-gateway   # Restart to pick up changes

# Run health check
openclaw doctor

# Run security audit
openclaw security audit
```

Secrets are stored in `/etc/openclaw-secrets` (owned by root, mode 600) and loaded by systemd. They never appear in your shell history or environment.

## Tailscale (Recommended)

Instead of exposing OpenClaw's port to the internet, use [Tailscale](https://tailscale.com/) for private access over a mesh VPN:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up
```

Then access OpenClaw via its Tailscale IP instead of the public IP.

## Headless / Automated Setup

Skip the wizard for scripted deployments:

```bash
curl -fsSL https://raw.githubusercontent.com/hwells4/easyclaw/main/setup.sh | \
  sudo bash -s -- --install-openclaw --no-wizard
```

Customize with environment variables:

```bash
NEW_USER=myuser SSH_PORT=2222 OPENCLAW_PORT=8080 sudo ./setup.sh --install-openclaw --no-wizard
```

Or provide a config file for fully automated OpenClaw setup:

```bash
curl -fsSL https://raw.githubusercontent.com/hwells4/easyclaw/main/setup.sh | \
  sudo bash -s -- --config openclaw-config.json
```

See `openclaw-config.example.json` for the config format.

## Troubleshooting

### Can't SSH after setup

The script disables root login and password auth. If you're locked out:

1. Access your server via the Hetzner web console
2. Run: `rm /etc/ssh/sshd_config.d/99-openclaw-hardening.conf && systemctl restart sshd`
3. Fix your SSH key setup, then re-run EasyClaw

### "Permission denied" with Docker

Log out and back in — group changes take effect on new sessions:

```bash
exit
ssh claw@<your-server-ip>
```

### OpenClaw gateway won't start

Check the logs:

```bash
sudo journalctl -u openclaw-gateway --no-pager -n 50
```

Common fix: make sure `/etc/openclaw-secrets` has your API keys set.

## Tested On

- Ubuntu 22.04 LTS / 24.04 LTS
- Hetzner Cloud, DigitalOcean, Contabo, AWS EC2

## License

MIT
