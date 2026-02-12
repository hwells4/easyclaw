# Terraform Configuration for OpenClaw VPS

This directory contains Terraform configs to automatically provision a Hetzner Cloud server for OpenClaw.

## Prerequisites

1. **Install Terraform**:
   ```bash
   # macOS
   brew install terraform
   
   # Linux
   wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
   echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
   sudo apt update && sudo apt install terraform
   ```

2. **Get a Hetzner API token**:
   - Go to [Hetzner Cloud Console](https://console.hetzner.cloud/)
   - Select your project
   - Security → API Tokens → Generate Token
   - Copy the token (you won't see it again)

3. **Have an SSH key pair**:
   ```bash
   # Generate if you don't have one
   ssh-keygen -t ed25519 -C "your-email@example.com"
   
   # Copy your public key content
   cat ~/.ssh/id_ed25519.pub
   ```

## Setup

1. **Copy the example variables file**:
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```

2. **Edit `terraform.tfvars`** with your values:
   ```hcl
   hcloud_token   = "your-actual-token"
   ssh_public_key = "ssh-ed25519 AAAAC3NzaC..."
   server_type    = "cpx21"  # Adjust as needed
   ```

3. **Initialize Terraform**:
   ```bash
   terraform init
   ```

4. **Preview changes**:
   ```bash
   terraform plan
   ```

5. **Create the server** (~30 seconds):
   ```bash
   terraform apply
   ```

   Type `yes` to confirm.

6. **Connect to your server**:
   ```bash
   # Terraform will output the SSH command, e.g.:
   ssh claw@<server-ip>
   ```

7. **Run the VPS setup script**:
   ```bash
   # Basic setup (manual OpenClaw install)
   curl -fsSL https://raw.githubusercontent.com/hwells4/easyclaw/main/setup.sh | sudo bash
   
   # Or auto-install OpenClaw too:
   curl -fsSL https://raw.githubusercontent.com/hwells4/easyclaw/main/setup.sh | sudo bash -s -- --install-openclaw
   ```

## Auto-Install with Config File

Want fully automated setup with your own configuration?

```bash
# 1. On your local machine, create config
cp openclaw-config.example.json openclaw-config.json
# Edit with your API keys, bot tokens, etc.

# 2. Copy to server
cp openclaw-config.json /tmp/

# 3. Run setup with config
curl -fsSL https://raw.githubusercontent.com/hwells4/easyclaw/main/setup.sh | sudo bash -s -- --config /tmp/openclaw-config.json
```

## Server Types & Pricing (Hetzner)

| Type | vCPUs | RAM | SSD | ~Cost/month |
|------|-------|-----|-----|-------------|
| cpx11 | 2 | 4 GB | 40 GB | ~€3.85 |
| cpx21 | 4 | 8 GB | 80 GB | ~€5.35 |
| cpx31 | 4 | 16 GB | 160 GB | ~€9.70 |
| cpx41 | 8 | 16 GB | 240 GB | ~€14.60 |
| cpx51 | 8 | 32 GB | 360 GB | ~€26.70 |

For OpenClaw with local models (Voxtral, Piper), **cpx21** (8GB) is the minimum.

## Managing the Server

### Check what's running
```bash
terraform show
```

### Update server type (resize)
1. Change `server_type` in `terraform.tfvars`
2. Run `terraform apply`
3. **Note:** Hetzner requires powering off to resize:
   ```bash
   hcloud server poweroff <server-name>
   # Then terraform apply
   hcloud server poweron <server-name>
   ```

### Destroy (stop paying)
```bash
terraform destroy
```

**⚠️ Warning:** This permanently deletes the server and all data on it!

### Multiple environments
Create separate workspaces:
```bash
# Create dev environment
terraform workspace new dev
terraform apply -var="server_name=openclaw-dev" -var="server_type=cpx11"

# Switch to prod
terraform workspace new prod
terraform apply -var="server_name=openclaw-prod" -var="server_type=cpx31"

# List workspaces
terraform workspace list

# Switch between them
terraform workspace select dev
```

## Troubleshooting

### "Invalid API token"
Double-check your token in `terraform.tfvars`. Tokens start with `R8a9...` or similar.

### "SSH connection refused"
Wait 2-3 minutes after creation for cloud-init to finish setting up the user.

### "Permission denied (publickey)"
Make sure you're using the private key that matches the public key in `terraform.tfvars`:
```bash
ssh -i ~/.ssh/id_ed25519 claw@<ip>
```

### Want to use a different cloud provider?
The setup script (`setup.sh`) works on any Ubuntu 22.04/24.04 server. You'd just need to swap the Hetzner provider for AWS, DigitalOcean, etc.

## Files

- `main.tf` — Main Terraform configuration (server, firewall, outputs)
- `cloud-init.yml` — Initial server setup (runs on first boot)
- `terraform.tfvars.example` — Example variables file
- `.gitignore` — Excludes sensitive files from git