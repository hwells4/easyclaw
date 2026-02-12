# EasyClaw

One command to launch your own AI assistant server. Run it from your laptop and it creates the server, secures it, and installs [OpenClaw](https://github.com/openclaw/openclaw) for you.

## What You Need Before Starting

1. **A Hetzner Cloud account** — [sign up here](https://console.hetzner.cloud/) (it's the server host, like a landlord for your AI)
2. **A Hetzner API token** — once signed in, go to your project > Security > API Tokens > Generate. Copy the token — you'll paste it into the wizard.
3. **API keys for OpenClaw** — the wizard tells you exactly what to get and when to paste it. You don't need these upfront.

That's it. You don't need to know Linux, SSH, or servers. The wizard walks you through everything.

## Run It

Open your terminal (Terminal on Mac, or any command line) and paste:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/hwells4/easyclaw/main/setup.sh)"
```

The wizard will:

1. Ask for your Hetzner API token
2. Let you pick a server size and location
3. Create the server and set up a secure connection
4. Lock down the server (firewall, brute-force protection, encrypted access)
5. Install everything OpenClaw needs
6. Walk you through OpenClaw's own setup — this is where you paste your API keys
7. Start OpenClaw and print how to connect

The whole process takes about 10 minutes. Most of that is the server installing packages — you just follow the prompts.

## After Setup

The wizard prints a command to connect to your server. It looks like:

```
ssh -i ~/.ssh/easyclaw_ed25519 claw@123.45.67.89
```

You can paste that into your terminal any time to get back into your server.

## Server Costs

EasyClaw runs on Hetzner Cloud. You pick the size during setup:

| Size | RAM | CPUs | ~Cost/month |
|------|-----|------|-------------|
| Small | 2 GB | 2 | ~$6/mo |
| **Medium** | **4 GB** | **3** | **~$11/mo (Recommended)** |
| Large | 8 GB | 4 | ~$19/mo |
| Extra Large | 16 GB | 8 | ~$34/mo |

You can delete the server any time from the [Hetzner console](https://console.hetzner.cloud/) to stop billing.

## Something Wrong?

**Can't connect after setup?** Try the SSH command the wizard printed. If you lost it, check the [Hetzner console](https://console.hetzner.cloud/) for your server's IP address, then:
```bash
ssh -i ~/.ssh/easyclaw_ed25519 claw@<your-server-ip>
```

**OpenClaw not working?** Connect to your server and run:
```bash
openclaw doctor
```

**Need to start over?** Delete the server from the [Hetzner console](https://console.hetzner.cloud/) and run the setup command again.

## License

[PolyForm Noncommercial 1.0.0](https://polyformproject.org/licenses/noncommercial/1.0.0) — Copyright (c) 2026 Dodo Digital
