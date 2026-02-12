# EasyClaw

One script to set up a secure OpenClaw server. Run the wizard, answer a few questions, and you're done.

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/hwells4/easyclaw/main/setup.sh | sudo bash
```

Or with OpenClaw auto-installed:

```bash
curl -fsSL https://raw.githubusercontent.com/hwells4/easyclaw/main/setup.sh | sudo bash -s -- --install-openclaw
```

## What You Get

Run one command on a fresh Ubuntu VPS and EasyClaw handles the rest:

- **Security hardening** — SSH lockdown, UFW firewall, Fail2ban (24h bans)
- **Swap** — Dynamic sizing based on RAM (up to 16GB), swappiness tuned for coding agents
- **Auto-updates** — Unattended security patches
- **Node.js 22** + **Homebrew** — Always installed
- **Docker** — Optional, on by default
- **Claude Code** — Anthropic's CLI agent (optional)
- **Codex** — OpenAI's CLI agent (optional)
- **OpenClaw** — Full install with gateway service, secrets management, and security audit (optional)
- **Temp cleanup** — Daily cron that clears stale `/tmp` files without touching active processes

## The Wizard

When you run the script interactively, it walks you through everything:

```
╔══════════════════════════════════════════╗
║          EasyClaw Setup Wizard           ║
╚══════════════════════════════════════════╝

  Quick, easy, and secure OpenClaw setup.
  One script. One wizard. Done.
```

It asks for your username, which tools to install, and whether to set up OpenClaw. Then it does everything else automatically.

Skip the wizard with `--no-wizard` for headless/automated setups.

## Options

```
--install-openclaw    Install OpenClaw after system setup
--config <file>       Use config file for automated OpenClaw setup
--no-wizard           Skip interactive wizard (use defaults or env vars)
```

### Environment Variables

```bash
NEW_USER=myuser sudo ./setup.sh          # Custom username (default: claw)
SSH_PORT=2222 sudo ./setup.sh             # Custom SSH port (default: 22)
OPENCLAW_PORT=8080 sudo ./setup.sh        # Custom OpenClaw port (default: 7860)
```

## Automated Setup with Config

For fully hands-off deployment:

```bash
# 1. Create your config
cp openclaw-config.example.json openclaw-config.json
# Edit with your API keys, bot tokens, etc.

# 2. Run with config
curl -fsSL https://raw.githubusercontent.com/hwells4/easyclaw/main/setup.sh | \
  sudo bash -s -- --config openclaw-config.json
```

## Terraform (Hetzner Cloud)

Provision a server and run EasyClaw in one flow. See [`terraform/README.md`](terraform/README.md).

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Edit with your Hetzner token and SSH key
terraform init && terraform apply
```

## What Gets Hardened

| Layer | What EasyClaw Does |
|-------|-------------------|
| SSH | Disables root login, enforces key auth, limits retries |
| Firewall | Denies all incoming by default, opens only needed ports |
| Fail2ban | Bans IPs after 3 failed SSH attempts for 24 hours |
| Swap | Prevents OOM kills from memory-hungry coding agents |
| Updates | Auto-installs security patches nightly |
| Secrets | Stored in `/etc/openclaw-secrets` (root:root, mode 600) |
| Temp files | Daily cleanup preserves active processes, removes stale data |

## Recommended VPS Specs

| Tier | RAM | CPU | Cost | Use Case |
|------|-----|-----|------|----------|
| Light | 4 GB | 2 cores | ~$4-6/mo | Single agent |
| **Standard** | **8 GB** | **4 cores** | **~$8-10/mo** | **Most users** |
| Heavy | 16 GB | 6 cores | ~$15-18/mo | Multiple agents |
| Power | 32 GB | 8 cores | ~$28-35/mo | Concurrent workloads |

Tested on Ubuntu 22.04 and 24.04 with Hetzner, DigitalOcean, Contabo, and AWS EC2.

## Post-Setup Checklist

- [ ] Copy SSH key to new user: `ssh-copy-id claw@<server-ip>`
- [ ] Test SSH login as new user (keep root session open!)
- [ ] Verify firewall: `sudo ufw status`
- [ ] Verify fail2ban: `sudo fail2ban-client status`
- [ ] Verify swap: `swapon --show`
- [ ] If using OpenClaw: edit `/etc/openclaw-secrets` with your tokens
- [ ] If using OpenClaw: `openclaw doctor`

## Troubleshooting

### Locked out of SSH

Access via your provider's console, then restore the backup config:

```bash
cp /etc/ssh/sshd_config.bak.* /etc/ssh/sshd_config
systemctl restart sshd
```

### Docker permission denied

Log out and back in for group changes:

```bash
exit
ssh claw@<server-ip>
```

### Homebrew not in PATH

```bash
echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' >> ~/.bashrc
source ~/.bashrc
```

## License

MIT - Copyright (c) 2026 Dodo Digital
