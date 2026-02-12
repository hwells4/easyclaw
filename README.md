# EasyClaw

One command to launch a secure OpenClaw server. Creates the server, handles SSH keys, hardens everything, and installs OpenClaw — all from your laptop.

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/hwells4/easyclaw/main/setup.sh | bash
```

That's it. The wizard handles everything:

1. Asks for your Hetzner API token
2. Picks server size and location
3. Generates SSH keys (or uses your existing ones)
4. Creates the server via Hetzner API
5. Waits for boot, SSHes in
6. Hardens the server (firewall, fail2ban, SSH lockdown, swap)
7. Installs Node.js, Homebrew, Docker, Claude Code, Codex
8. Installs OpenClaw and runs its onboarding wizard
9. Creates a systemd service that keeps OpenClaw running
10. Prints your SSH command and you're done

## What You Need

1. **A Hetzner Cloud account** — [sign up here](https://console.hetzner.cloud/)
2. **A Hetzner API token** — Console > Project > Security > API Tokens > Generate
3. **API keys for OpenClaw** — the wizard tells you exactly what to paste and when

That's all. You don't need to create a server manually. You don't need to set up SSH keys. EasyClaw does it.

## What Gets Installed

**Always:**
- Security hardening (SSH lockdown, UFW firewall, Fail2ban, auto-updates)
- Swap (dynamic, matches RAM)
- Node.js 22, Homebrew
- OpenClaw + systemd gateway service
- Daily /tmp cleanup cron
- SECURITY.md agent boundaries

**Optional (wizard asks):**
- Docker
- Claude Code (Anthropic CLI)
- Codex (OpenAI CLI)

## After Setup

The wizard prints your SSH command:

```bash
ssh -i ~/.ssh/easyclaw_ed25519 claw@<server-ip>
```

On the server:

```bash
sudo systemctl status openclaw-gateway   # Check status
sudo journalctl -u openclaw-gateway -f   # View logs
sudo vim /etc/openclaw-secrets            # Edit API keys
sudo systemctl restart openclaw-gateway   # Restart after changes
openclaw doctor                           # Health check
```

## Headless Mode

For scripted/automated deployments:

```bash
HETZNER_TOKEN=your-token \
SERVER_TYPE=cpx21 \
SERVER_LOCATION=ash \
  curl -fsSL https://raw.githubusercontent.com/hwells4/easyclaw/main/setup.sh | bash -s -- --no-wizard
```

All environment variables:

| Variable | Default | Options |
|----------|---------|---------|
| `HETZNER_TOKEN` | (required) | Your Hetzner API token |
| `SERVER_TYPE` | `cpx21` | `cpx11`, `cpx21`, `cpx31`, `cpx41` |
| `SERVER_LOCATION` | `ash` | `ash`, `hil`, `nbg1`, `hel1` |
| `NEW_USER` | `claw` | Any valid username |
| `SSH_KEY_PATH` | auto-generated | Path to existing SSH private key |

## Server Sizes

| Type | RAM | CPU | ~Cost/mo |
|------|-----|-----|----------|
| CPX11 | 4 GB | 2 | ~$4 |
| **CPX21** | **8 GB** | **4** | **~$5** |
| CPX31 | 16 GB | 4 | ~$10 |
| CPX41 | 16 GB | 8 | ~$15 |

## Terraform

The `terraform/` directory is also available for infrastructure-as-code provisioning on Hetzner. See [`terraform/README.md`](terraform/README.md).

## Troubleshooting

**Can't SSH after setup?** The script disables root login. Use the SSH command printed at the end, or access via Hetzner web console and run:
```bash
rm /etc/ssh/sshd_config.d/99-easyclaw-hardening.conf && systemctl restart sshd
```

**OpenClaw won't start?** Check logs and secrets:
```bash
sudo journalctl -u openclaw-gateway --no-pager -n 50
sudo cat /etc/openclaw-secrets
```

## License

MIT — Copyright (c) 2026 Dodo Digital
