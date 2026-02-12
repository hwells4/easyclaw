# Terraform Configuration for EasyClaw

Automatically provision a Hetzner Cloud server and run EasyClaw to set up OpenClaw.

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
   - Security > API Tokens > Generate Token
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

6. **Connect and run EasyClaw**:
   ```bash
   ssh claw@<server-ip>
   curl -fsSL https://raw.githubusercontent.com/hwells4/easyclaw/main/setup.sh | sudo bash
   ```

## Server Types & Pricing (Hetzner)

| Type | vCPUs | RAM | SSD | ~Cost/month |
|------|-------|-----|-----|-------------|
| cpx11 | 2 | 4 GB | 40 GB | ~$3.85 |
| cpx21 | 4 | 8 GB | 80 GB | ~$5.35 |
| cpx31 | 4 | 16 GB | 160 GB | ~$9.70 |
| cpx41 | 8 | 16 GB | 240 GB | ~$14.60 |
| cpx51 | 8 | 32 GB | 360 GB | ~$26.70 |

For OpenClaw with coding agents, **cpx21** (8GB) is the minimum recommendation.

## Managing the Server

```bash
terraform show          # Check what's running
terraform destroy       # Delete server (stops billing)
```

### Multiple environments

```bash
terraform workspace new dev
terraform apply -var="server_name=openclaw-dev" -var="server_type=cpx11"

terraform workspace new prod
terraform apply -var="server_name=openclaw-prod" -var="server_type=cpx31"
```

## Files

- `main.tf` — Server, firewall, and outputs
- `cloud-init.yml` — First-boot setup (runs before EasyClaw)
- `terraform.tfvars.example` — Example variables
