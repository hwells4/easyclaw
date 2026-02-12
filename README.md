# OpenClaw VPS Setup Guide

A complete guide and automated script for setting up a secure VPS for running OpenClaw.

## Quick Start

```bash
# Run the automated setup (as root)
curl -fsSL https://raw.githubusercontent.com/hwells4/easyclaw/main/setup.sh | sudo bash

# Or with OpenClaw fully auto-installed:
curl -fsSL https://raw.githubusercontent.com/hwells4/easyclaw/main/setup.sh | sudo bash -s -- --install-openclaw
```

Or manually:

```bash
# Download and run
wget https://raw.githubusercontent.com/hwells4/easyclaw/main/setup.sh
chmod +x setup.sh
sudo ./setup.sh --install-openclaw
```

## What This Script Does

### 1. System Updates
- Updates all packages
- Installs essential tools (curl, git, vim, htop, tmux, build-essential)

### 2. User Setup
- Creates a non-root user (`claw` by default)
- Adds user to sudo group
- **Why:** Running services as root is a security risk

### 3. SSH Hardening
- Disables root login
- Enforces key-based authentication (passwords disabled)
- Limits authentication attempts
- Adds connection timeouts
- **⚠️ Important:** Ensure you have SSH key access before running this!

### 4. Firewall (UFW)
- Blocks all incoming traffic by default
- Allows: SSH (22), OpenClaw (7860), HTTP (80), HTTPS (443)
- **Why:** Defense in depth — only expose necessary ports

### 5. Intrusion Prevention (Fail2ban)
- Bans IPs after 3 failed SSH attempts
- Configurable ban time (default: 1 hour)
- **Why:** Protects against brute force attacks

### 6. Swap (8GB)
- Creates `/swapfile.img` with 8GB swap
- Sets `vm.swappiness=10` (prefer RAM, swap as safety net)
- **Why:** Coding agents can spike memory; swap prevents OOM kills

### 7. Package Managers & CLI Tools
- **Homebrew** (Linuxbrew) — modern package manager, better for dev tools
- **Docker** — containerization for services
- **Node.js 22.x** — required for OpenClaw
- **Bun** — fast JavaScript runtime (used by some OpenClaw components)
- **Claude Code** — Anthropic's CLI for Claude
- **Codex** — OpenAI's CLI agent

### 8. Auto-Updates
- Enables unattended security updates
- Keeps the system patched automatically

### 9. Temp Cleanup (Cron)
- Installs `tmp-cleanup` to `~/.local/bin/`
- Runs daily at 4am via crontab
- Indexes CASS (coding agent session search) before cleanup
- Removes files/dirs in `/tmp` older than 2 days
- Never removes files with open file handles (`lsof` check)
- Preserves tmux sockets, SSH agents, browser sockets, systemd dirs
- **Why:** Coding agents (Claude, Codex, etc.) generate heavy temp data that can fill `/tmp` and hang processes
- Manual usage: `tmp-cleanup --dry-run --verbose`

### 10. OpenClaw (with `--install-openclaw`)

When the `--install-openclaw` flag is passed, the script also:
- Installs OpenClaw as the service user (not root) to avoid dual-install issues
- Generates a `SECURITY.md` with safe agent boundaries
- Runs `openclaw onboard` for interactive setup (API keys, Telegram, 1Password, etc.)
- Creates `/etc/openclaw-secrets` for systemd-managed secrets
- Installs a 1Password CLI audit wrapper (logs all `op` invocations)
- Creates a hardened systemd service with `EnvironmentFile` for secrets

## Secrets Management

Secrets are stored in `/etc/openclaw-secrets` (root:root, mode 600) and loaded by the
systemd service via `EnvironmentFile`. This keeps secrets out of the user's environment
and shell history.

```bash
# Edit secrets
sudo vim /etc/openclaw-secrets

# Restart to pick up changes
sudo systemctl restart openclaw-gateway
```

The file format is one `KEY=VALUE` per line:

```
OP_SERVICE_ACCOUNT_TOKEN=ops_abc123...
ANTHROPIC_API_KEY=sk-ant-...
```

## Manual Setup (Step-by-Step)

If you prefer to understand each step:

### 1. Create a Non-Root User

```bash
# As root
useradd -m -s /bin/bash claw
usermod -aG sudo claw
passwd claw
```

### 2. Harden SSH

```bash
# Backup config
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak

# Edit config
vim /etc/ssh/sshd_config

# Add these lines:
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3

# Restart SSH
systemctl restart sshd
```

### 3. Setup Firewall

```bash
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 7860/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw enable
```

### 4. Install Fail2ban

```bash
apt-get install fail2ban

# Create config
cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 3

[sshd]
enabled = true
port = 22
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
EOF

systemctl enable fail2ban
systemctl start fail2ban
```

### 5. Install Homebrew

```bash
# As the new user (claw)
su - claw
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' >> ~/.bashrc
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
```

### 6. Install Docker

```bash
# As root
curl -fsSL https://get.docker.com | sh
usermod -aG docker claw
systemctl enable docker
systemctl start docker
```

### 7. Install Node.js

```bash
# As root
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs
```

### 8. Install OpenClaw

```bash
# As the new user (claw) — not root!
su - claw
npm install -g openclaw
openclaw onboard
```

## Post-Setup Checklist

After running the script:

- [ ] Copy SSH key to new user: `ssh-copy-id claw@<server-ip>`
- [ ] Test SSH login as new user (keep root session open!)
- [ ] Verify firewall: `sudo ufw status`
- [ ] Verify fail2ban: `sudo fail2ban-client status`
- [ ] Verify swap: `swapon --show`
- [ ] If using `--install-openclaw`: edit `/etc/openclaw-secrets` with your tokens
- [ ] If using `--install-openclaw`: review `~/.openclaw/workspace/SECURITY.md`
- [ ] Run `openclaw doctor` to verify everything works
- [ ] Run `openclaw security audit` to check for issues

## Security Notes

### SSH Keys

Generate a key pair if you don't have one:

```bash
ssh-keygen -t ed25519 -C "your-email@example.com"
```

Copy to server:

```bash
ssh-copy-id claw@<server-ip>
```

### Firewall Rules

View active rules:

```bash
sudo ufw status verbose
```

Add custom rules:

```bash
# Allow specific IP
sudo ufw allow from 192.168.1.100

# Allow port range
sudo ufw allow 8000:9000/tcp
```

### Tailscale (Recommended)

For secure remote access to the gateway and other services, [Tailscale](https://tailscale.com/) is recommended over exposing ports publicly. With Tailscale, you can access services like OpenClaw's gateway over a private mesh VPN without opening firewall ports to the internet.

```bash
# Install Tailscale
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up

# Then access services via the Tailscale IP instead of public IP
```

### Fail2ban Monitoring

Check banned IPs:

```bash
sudo fail2ban-client status sshd
```

Unban an IP:

```bash
sudo fail2ban-client set sshd unbanip 192.168.1.100
```

## Troubleshooting

### Can't SSH After Hardening

If you locked yourself out:

1. Access server via console (Hetzner/DigitalOcean/Vultr console)
2. Restore SSH config: `cp /etc/ssh/sshd_config.bak.* /etc/ssh/sshd_config`
3. Restart SSH: `systemctl restart sshd`

### Permission Denied (Docker)

Log out and back in for group changes to take effect:

```bash
exit
ssh claw@<server-ip>
```

Or run: `newgrp docker`

### Homebrew Not Found

Ensure it's in your PATH:

```bash
echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' >> ~/.bashrc
source ~/.bashrc
```

## Environment Variables

Customize the setup with env vars:

```bash
# Create user with different name
NEW_USER=myuser sudo ./setup.sh

# Use custom SSH port
SSH_PORT=2222 sudo ./setup.sh

# Use custom OpenClaw port
OPENCLAW_PORT=8080 sudo ./setup.sh
```

## Recommended VPS Specs for OpenClaw

| Component | Minimum | Recommended |
|-----------|---------|-------------|
| RAM | 4 GB | 8 GB+ |
| CPU | 2 cores | 4 cores |
| Storage | 20 GB SSD | 50 GB SSD |
| OS | Ubuntu 22.04 LTS | Ubuntu 24.04 LTS |

## Tested On

- Ubuntu 22.04 LTS
- Ubuntu 24.04 LTS
- Hetzner Cloud
- DigitalOcean Droplets
- AWS EC2 (t3.medium+)

## Contributing

PRs welcome! Please test on a fresh VPS before submitting.

## License

MIT