#!/bin/bash
#
# EasyClaw — One command to launch a secure OpenClaw server
# https://github.com/hwells4/easyclaw
#
# Run from your laptop:
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/hwells4/easyclaw/main/setup.sh)"
#
# The script handles everything:
#   1. Creates a Hetzner server via API
#   2. Generates/uses SSH keys
#   3. SSHes in and hardens the server
#   4. Installs OpenClaw + all dependencies
#

set -euo pipefail

# ─── Colors ───────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Configuration ────────────────────────────────────────────────────
NEW_USER="${NEW_USER:-claw}"
SSH_PORT="${SSH_PORT:-22}"
OPENCLAW_PORT="${OPENCLAW_PORT:-7860}"
HETZNER_TOKEN="${HETZNER_TOKEN:-}"
SERVER_TYPE="${SERVER_TYPE:-cpx21}"
SERVER_LOCATION="${SERVER_LOCATION:-ash}"
SERVER_NAME="${SERVER_NAME:-}"
SSH_KEY_PATH="${SSH_KEY_PATH:-}"
RUN_WIZARD="${RUN_WIZARD:-true}"
INSTALL_DOCKER="${INSTALL_DOCKER:-true}"
INSTALL_CLAUDE_CODE="${INSTALL_CLAUDE_CODE:-true}"
INSTALL_CODEX="${INSTALL_CODEX:-true}"
OPENCLAW_CONFIG="${OPENCLAW_CONFIG:-}"

# Set during execution
SERVER_IP=""
EASYCLAW_SSH_KEY="$HOME/.ssh/easyclaw_ed25519"

log() { echo -e "${GREEN}[easyclaw]${NC} $1"; }
warn() { echo -e "${YELLOW}[warn]${NC} $1"; }
error() { echo -e "${RED}[error]${NC} $1"; exit 1; }
step() { echo -e "\n${BLUE}${BOLD}── $1 ──${NC}\n"; }

ask_yes_no() {
    local prompt="$1" default="${2:-y}"
    local yn_hint="[Y/n]"
    [ "$default" = "n" ] && yn_hint="[y/N]"
    while true; do
        echo -en "  ${prompt} ${yn_hint}: "
        read -r answer
        answer="${answer:-$default}"
        case "$answer" in
            [Yy]*) return 0 ;; [Nn]*) return 1 ;;
            *) echo "  Please answer y or n." ;;
        esac
    done
}

# ─── Hetzner API helpers ─────────────────────────────────────────────
hetzner_api() {
    local method="$1" endpoint="$2" data="${3:-}"
    local args=(-s -H "Authorization: Bearer $HETZNER_TOKEN" -H "Content-Type: application/json")
    [ -n "$data" ] && args+=(-d "$data")
    curl "${args[@]}" -X "$method" "https://api.hetzner.cloud/v1${endpoint}"
}

# =====================================================================
#  PHASE 1: LOCAL — Create server, handle SSH keys
# =====================================================================

setup_ssh_key() {
    step "SSH Key"

    # Explicit key path takes priority (user knows what they're doing)
    if [ -n "$SSH_KEY_PATH" ] && [ -f "$SSH_KEY_PATH" ]; then
        log "Using provided SSH key: $SSH_KEY_PATH"
        EASYCLAW_SSH_KEY="$SSH_KEY_PATH"
        return
    fi

    # Reuse existing EasyClaw key if one exists (it's already dedicated to us)
    if [ -f "$EASYCLAW_SSH_KEY" ] && [ -f "${EASYCLAW_SSH_KEY}.pub" ]; then
        log "Found existing EasyClaw key: $EASYCLAW_SSH_KEY"
        if ask_yes_no "Use this key?" "y"; then
            return
        fi
    fi

    # Generate a dedicated key — never reuse id_ed25519/id_rsa
    log "Generating dedicated SSH key for EasyClaw..."
    ssh-keygen -t ed25519 -f "$EASYCLAW_SSH_KEY" -N "" -C "easyclaw-$(date +%Y%m%d)"
    log "Created: $EASYCLAW_SSH_KEY"
}

create_hetzner_server() {
    step "Create Server"

    # Upload SSH key to Hetzner
    log "Uploading SSH key to Hetzner..."
    local pubkey
    pubkey=$(cat "${EASYCLAW_SSH_KEY}.pub")
    local key_name="easyclaw-$(date +%s)"

    local key_response
    key_response=$(hetzner_api POST /ssh_keys "{\"name\":\"$key_name\",\"public_key\":\"$pubkey\"}")

    local ssh_key_id
    ssh_key_id=$(echo "$key_response" | python3 -c "import sys,json; print(json.load(sys.stdin)['ssh_key']['id'])" 2>/dev/null)

    if [ -z "$ssh_key_id" ] || [ "$ssh_key_id" = "None" ]; then
        # Key might already exist — try to find it by fingerprint
        local fingerprint
        fingerprint=$(ssh-keygen -lf "${EASYCLAW_SSH_KEY}.pub" -E md5 | awk '{print $2}' | sed 's/MD5://')
        ssh_key_id=$(hetzner_api GET "/ssh_keys" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for k in data.get('ssh_keys', []):
    if k.get('fingerprint') == '$fingerprint':
        print(k['id']); break
" 2>/dev/null)
        if [ -z "$ssh_key_id" ]; then
            echo "$key_response" >&2
            error "Failed to upload SSH key to Hetzner. Check your API token."
        fi
        log "SSH key already exists on Hetzner (id: $ssh_key_id)"
    else
        log "SSH key uploaded (id: $ssh_key_id)"
    fi

    # Create server
    if [ -z "$SERVER_NAME" ]; then
        SERVER_NAME="openclaw-$(head -c 4 /dev/urandom | xxd -p)"
    fi

    log "Creating server: $SERVER_NAME ($SERVER_TYPE in $SERVER_LOCATION)..."

    local server_response
    server_response=$(hetzner_api POST /servers "{
        \"name\": \"$SERVER_NAME\",
        \"server_type\": \"$SERVER_TYPE\",
        \"image\": \"ubuntu-24.04\",
        \"location\": \"$SERVER_LOCATION\",
        \"ssh_keys\": [$ssh_key_id],
        \"start_after_create\": true
    }")

    SERVER_IP=$(echo "$server_response" | python3 -c "import sys,json; print(json.load(sys.stdin)['server']['public_net']['ipv4']['ip'])" 2>/dev/null)

    if [ -z "$SERVER_IP" ] || [ "$SERVER_IP" = "None" ]; then
        echo "$server_response" >&2
        error "Failed to create server. Check your API token and Hetzner account."
    fi

    log "Server created! IP: $SERVER_IP"
}

wait_for_server() {
    step "Waiting for Server"

    log "Waiting for $SERVER_IP to accept SSH connections..."
    local attempts=0
    local max_attempts=60  # 5 minutes

    while [ $attempts -lt $max_attempts ]; do
        if ssh -i "$EASYCLAW_SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes root@"$SERVER_IP" "echo ok" &>/dev/null; then
            log "Server is ready!"
            return
        fi
        attempts=$((attempts + 1))
        echo -en "\r  Waiting... ${attempts}/${max_attempts} ($(( attempts * 5 ))s)"
        sleep 5
    done
    echo ""
    error "Server did not become reachable after 5 minutes. Check Hetzner console."
}

run_remote_setup() {
    step "Running Setup on Server"

    log "SSHing into $SERVER_IP and running server setup..."
    echo ""

    local script_url="https://raw.githubusercontent.com/hwells4/easyclaw/main/setup.sh"
    local ssh_opts="-i $EASYCLAW_SSH_KEY -o StrictHostKeyChecking=no"

    # Download script to server first (keeps stdin free for interactive prompts)
    ssh $ssh_opts root@"$SERVER_IP" \
        "curl -fsSL $script_url -o /tmp/easyclaw-setup.sh && chmod +x /tmp/easyclaw-setup.sh"

    # Run with -t for pseudo-terminal so openclaw onboard can prompt for API keys
    ssh -t $ssh_opts root@"$SERVER_IP" \
        "NEW_USER=$NEW_USER INSTALL_DOCKER=$INSTALL_DOCKER INSTALL_CLAUDE_CODE=$INSTALL_CLAUDE_CODE INSTALL_CODEX=$INSTALL_CODEX bash /tmp/easyclaw-setup.sh --on-server"
}

run_wizard_local() {
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║            EasyClaw Setup                ║${NC}"
    echo -e "${GREEN}║   One command. Secure OpenClaw server.   ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
    echo ""
    echo "  This wizard will create a server, harden it, and install"
    echo "  OpenClaw — all from right here. Takes about 10 minutes."
    echo ""

    # ── Hetzner API token ──
    step "Hetzner Cloud"

    echo "  You need a Hetzner Cloud API token."
    echo "  Get one at: https://console.hetzner.cloud/"
    echo "    → Pick a project → Security → API Tokens → Generate"
    echo ""

    while [ -z "$HETZNER_TOKEN" ]; do
        echo -en "  Paste your Hetzner API token: "
        read -rs HETZNER_TOKEN
        echo ""
        if [ -z "$HETZNER_TOKEN" ]; then
            echo "  Token can't be empty."
        fi
    done

    # Validate token
    local test_response
    test_response=$(hetzner_api GET /servers 2>/dev/null || true)
    if echo "$test_response" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'servers' in d" 2>/dev/null; then
        log "API token valid!"
    else
        error "Invalid API token. Check it and try again."
    fi

    # ── Server size ──
    step "Server Size"

    echo "  Pick a server size:"
    echo ""
    echo "    1)  CPX11 —  4 GB /  2 CPU  ~\$4/mo   Light usage"
    echo "    2)  CPX21 —  8 GB /  4 CPU  ~\$5/mo   Recommended"
    echo "    3)  CPX31 — 16 GB /  4 CPU  ~\$10/mo  Heavy usage"
    echo "    4)  CPX41 — 16 GB /  8 CPU  ~\$15/mo  Power user"
    echo ""
    echo -en "  Choice [2]: "
    read -r size_choice
    case "${size_choice:-2}" in
        1) SERVER_TYPE="cpx11" ;; 2) SERVER_TYPE="cpx21" ;;
        3) SERVER_TYPE="cpx31" ;; 4) SERVER_TYPE="cpx41" ;;
        *) SERVER_TYPE="cpx21" ;;
    esac

    # ── Location ──
    step "Server Location"

    echo "  Pick a location:"
    echo ""
    echo "    1)  Ashburn, US (ash)      — US East"
    echo "    2)  Hillsboro, US (hil)    — US West"
    echo "    3)  Nuremberg, DE (nbg1)   — Europe"
    echo "    4)  Helsinki, FI (hel1)    — Europe"
    echo ""
    echo -en "  Choice [1]: "
    read -r loc_choice
    case "${loc_choice:-1}" in
        1) SERVER_LOCATION="ash" ;; 2) SERVER_LOCATION="hil" ;;
        3) SERVER_LOCATION="nbg1" ;; 4) SERVER_LOCATION="hel1" ;;
        *) SERVER_LOCATION="ash" ;;
    esac

    # ── Username ──
    step "User Account"

    echo "  Username for the server (runs OpenClaw, not root)."
    echo -en "  Username [claw]: "
    read -r input_user
    if [ -n "$input_user" ]; then
        if [[ "$input_user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
            NEW_USER="$input_user"
        else
            warn "Invalid username, using default: claw"
        fi
    fi

    # ── Optional tools ──
    step "Optional Tools"

    echo "  These are always installed: Node.js 22, Homebrew, OpenClaw"
    echo "  Choose extras:"
    echo ""

    ask_yes_no "Docker?" "y" && INSTALL_DOCKER=true || INSTALL_DOCKER=false
    ask_yes_no "Claude Code? (Anthropic CLI)" "y" && INSTALL_CLAUDE_CODE=true || INSTALL_CLAUDE_CODE=false
    ask_yes_no "Codex? (OpenAI CLI)" "y" && INSTALL_CODEX=true || INSTALL_CODEX=false

    # ── API keys heads up ──
    step "Almost Ready"

    echo "  After the server is set up, OpenClaw will ask you to paste"
    echo "  API keys for the services you want. Have these ready:"
    echo ""
    echo "    - Kimi K2.5 API key:  https://platform.moonshot.cn/console/api-keys"
    echo "    - Telegram bot token: Message @BotFather on Telegram"
    echo "    - 1Password token:    https://my.1password.com/developer (optional)"
    echo ""

    # ── Summary ──
    step "Summary"

    echo "  Server:      $SERVER_TYPE in $SERVER_LOCATION"
    echo "  User:        $NEW_USER"
    echo "  Docker:      $([ "$INSTALL_DOCKER" = true ] && echo "yes" || echo "no")"
    echo "  Claude Code: $([ "$INSTALL_CLAUDE_CODE" = true ] && echo "yes" || echo "no")"
    echo "  Codex:       $([ "$INSTALL_CODEX" = true ] && echo "yes" || echo "no")"
    echo "  OpenClaw:    always"
    echo ""

    if ! ask_yes_no "Create the server and start setup?" "y"; then
        echo "  Cancelled."
        exit 0
    fi
}

print_final_summary() {
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║        EasyClaw Setup Complete!          ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
    echo ""
    echo "  Server IP:   $SERVER_IP"
    echo "  SSH user:    $NEW_USER"
    echo "  SSH key:     $EASYCLAW_SSH_KEY"
    echo ""
    echo "  Connect:"
    echo "    ssh -i $EASYCLAW_SSH_KEY $NEW_USER@$SERVER_IP"
    echo ""
    echo "  OpenClaw commands (on server):"
    echo "    sudo systemctl status openclaw-gateway"
    echo "    sudo journalctl -u openclaw-gateway -f"
    echo ""
    echo "  Manage secrets:"
    echo "    sudo vim /etc/openclaw-secrets"
    echo "    sudo systemctl restart openclaw-gateway"
    echo ""
    echo -e "  ${GREEN}Your OpenClaw server is running!${NC}"
    echo ""
}

local_main() {
    # Check dependencies
    for cmd in curl ssh ssh-keygen python3; do
        command -v "$cmd" &>/dev/null || error "Missing required tool: $cmd"
    done

    if [ "$RUN_WIZARD" = true ] && [ -t 0 ]; then
        run_wizard_local
    else
        # Headless mode — need HETZNER_TOKEN set
        [ -z "$HETZNER_TOKEN" ] && error "HETZNER_TOKEN required for non-interactive mode"
    fi

    setup_ssh_key
    create_hetzner_server
    wait_for_server
    run_remote_setup

    print_final_summary
}

# =====================================================================
#  PHASE 2: ON-SERVER — Harden + install everything
# =====================================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "On-server setup must run as root"
    fi
}

update_system() {
    log "Updating system packages..."
    apt-get update
    apt-get upgrade -y
    apt-get install -y \
        curl wget git vim htop tmux ufw fail2ban \
        software-properties-common apt-transport-https \
        ca-certificates gnupg lsb-release build-essential \
        python3 python3-pip python3-venv
}

create_user() {
    log "Creating user: $NEW_USER"
    if id "$NEW_USER" &>/dev/null; then
        warn "User $NEW_USER already exists"
        return
    fi
    useradd -m -s /bin/bash "$NEW_USER"
    usermod -aG sudo "$NEW_USER"
    # No password prompt — SSH key auth only
    log "User $NEW_USER created (SSH key auth, no password)"
}

setup_ssh_hardening() {
    log "Configuring SSH hardening..."
    mkdir -p /etc/ssh/sshd_config.d
    cat > /etc/ssh/sshd_config.d/99-easyclaw-hardening.conf << 'EOF'
# Security hardening applied by EasyClaw
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
    if sshd -t; then
        systemctl restart sshd
        log "SSH hardened. Root login disabled, key auth only."
    else
        error "sshd config validation failed"
    fi
}

setup_firewall() {
    log "Configuring UFW firewall..."
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow "$SSH_PORT/tcp"
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow "$OPENCLAW_PORT/tcp"
    ufw --force enable
    log "Firewall enabled. Allowed: SSH ($SSH_PORT), HTTP/S, OpenClaw ($OPENCLAW_PORT)"
}

setup_fail2ban() {
    log "Configuring Fail2ban..."
    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = 24h
findtime = 10m
maxretry = 3

[sshd]
enabled = true
port = $SSH_PORT
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
EOF
    systemctl enable fail2ban
    systemctl start fail2ban
    log "Fail2ban configured"
}

setup_swap() {
    log "Setting up swap..."
    if swapon --show | grep -q '/swapfile.img'; then
        warn "Swap already active"
        return
    fi
    TOTAL_RAM_MB=$(grep MemTotal /proc/meminfo | awk '{print int($2/1024)}')
    SWAP_SIZE_MB=$(( TOTAL_RAM_MB <= 16384 ? TOTAL_RAM_MB : 16384 ))
    if [ -f /swapfile.img ]; then
        chmod 0600 /swapfile.img
    else
        fallocate -l "${SWAP_SIZE_MB}M" /swapfile.img
        chmod 0600 /swapfile.img
    fi
    mkswap /swapfile.img
    swapon /swapfile.img
    grep -q '/swapfile.img' /etc/fstab || echo '/swapfile.img none swap sw 0 0' >> /etc/fstab
    sysctl vm.swappiness=10
    grep -q 'vm.swappiness' /etc/sysctl.conf || echo 'vm.swappiness=10' >> /etc/sysctl.conf
    log "${SWAP_SIZE_MB}MB swap configured (swappiness=10)"
}

setup_auto_updates() {
    log "Enabling automatic security updates..."
    apt-get install -y unattended-upgrades
    cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF
    systemctl enable unattended-upgrades
    systemctl start unattended-upgrades
    log "Auto-updates enabled"
}

install_homebrew() {
    log "Installing Homebrew..."
    if command -v brew &>/dev/null; then warn "Already installed"; return; fi
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    if ! grep -q 'linuxbrew' /root/.bashrc 2>/dev/null; then
        echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' >> /root/.bashrc
    fi
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
    if ! grep -q 'linuxbrew' "/home/$NEW_USER/.bashrc" 2>/dev/null; then
        echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' >> "/home/$NEW_USER/.bashrc"
    fi
    chown "$NEW_USER:$NEW_USER" "/home/$NEW_USER/.bashrc"
    brew install gcc
    log "Homebrew installed"
}

install_node() {
    log "Installing Node.js 22..."
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt-get install -y nodejs
    log "Node.js $(node --version) installed"
}

install_docker() {
    log "Installing Docker..."
    if command -v docker &>/dev/null; then warn "Already installed"; return; fi
    apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    usermod -aG docker "$NEW_USER"
    systemctl enable docker && systemctl start docker
    log "Docker installed"
}

install_claude_code() {
    log "Installing Claude Code..."
    su - "$NEW_USER" -c 'curl -fsSL https://claude.ai/install.sh | bash' || warn "Claude Code install failed — install manually later"
}

install_codex() {
    log "Installing Codex..."
    su - "$NEW_USER" -c "npm install -g @openai/codex" || warn "Codex install failed — install manually later"
}

install_openclaw_deps() {
    log "Installing OpenClaw dependencies..."
    su - "$NEW_USER" -c 'curl -fsSL https://bun.sh/install | bash'
    if ! grep -q '\.bun/bin' "/home/$NEW_USER/.bashrc" 2>/dev/null; then
        echo 'export PATH="$HOME/.bun/bin:$PATH"' >> "/home/$NEW_USER/.bashrc"
    fi
}

install_openclaw() {
    log "Installing OpenClaw (as $NEW_USER)..."
    su - "$NEW_USER" -c "npm install -g openclaw"
    mkdir -p "/home/$NEW_USER/.config/openclaw"
    chown -R "$NEW_USER:$NEW_USER" "/home/$NEW_USER/.config"
    if [ -n "$OPENCLAW_CONFIG" ] && [ -f "$OPENCLAW_CONFIG" ]; then
        cp "$OPENCLAW_CONFIG" "/home/$NEW_USER/.config/openclaw/config.json"
        chown "$NEW_USER:$NEW_USER" "/home/$NEW_USER/.config/openclaw/config.json"
    fi
    log "OpenClaw installed"
}

install_security_md() {
    log "Installing SECURITY.md..."
    local SCRIPT_DIR
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    mkdir -p "/home/$NEW_USER/.openclaw/workspace"
    if [ -f "$SCRIPT_DIR/scripts/security-md-template.sh" ]; then
        bash "$SCRIPT_DIR/scripts/security-md-template.sh" "/home/$NEW_USER/.openclaw/workspace/SECURITY.md"
    else
        curl -fsSL https://raw.githubusercontent.com/hwells4/easyclaw/main/scripts/security-md-template.sh | \
            bash -s -- "/home/$NEW_USER/.openclaw/workspace/SECURITY.md"
    fi
    chown -R "$NEW_USER:$NEW_USER" "/home/$NEW_USER/.openclaw"
}

setup_secrets_file() {
    log "Setting up secrets file..."
    if [ -f /etc/openclaw-secrets ]; then warn "Already exists"; return; fi
    cat > /etc/openclaw-secrets << 'EOF'
# OpenClaw secrets — managed by EasyClaw
# Loaded by openclaw-gateway systemd service.
# OP_SERVICE_ACCOUNT_TOKEN=
EOF
    chmod 0600 /etc/openclaw-secrets
    chown root:root /etc/openclaw-secrets
    log "Created /etc/openclaw-secrets (root:root 600)"
}

install_op_audit_wrapper() {
    local OP_REAL="/home/${NEW_USER}/.local/bin/op.real"
    local OP_PATH="/home/${NEW_USER}/.local/bin/op"
    if [ ! -f "$OP_PATH" ] || [ -f "$OP_REAL" ]; then return; fi
    log "Installing 1Password audit wrapper..."
    mv "$OP_PATH" "$OP_REAL"
    cat > "$OP_PATH" << 'WRAPPER'
#!/bin/bash
LOG_DIR="$HOME/.openclaw/logs"
mkdir -p "$LOG_DIR"
echo "$(date -Iseconds) [op] $*" >> "$LOG_DIR/op-audit.log"
exec "$HOME/.local/bin/op.real" "$@"
WRAPPER
    chmod +x "$OP_PATH"
    chown "$NEW_USER:$NEW_USER" "$OP_PATH" "$OP_REAL"
}

setup_tmp_cleanup() {
    log "Installing /tmp cleanup cron..."
    local SCRIPT_DIR
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    mkdir -p "/home/$NEW_USER/.local/bin"
    if [ -f "$SCRIPT_DIR/scripts/tmp-cleanup.sh" ]; then
        cp "$SCRIPT_DIR/scripts/tmp-cleanup.sh" "/home/$NEW_USER/.local/bin/tmp-cleanup"
    else
        curl -fsSL https://raw.githubusercontent.com/hwells4/easyclaw/main/scripts/tmp-cleanup.sh \
            -o "/home/$NEW_USER/.local/bin/tmp-cleanup"
    fi
    chmod +x "/home/$NEW_USER/.local/bin/tmp-cleanup"
    chown "$NEW_USER:$NEW_USER" "/home/$NEW_USER/.local/bin/tmp-cleanup"
    if ! grep -q '\.local/bin' "/home/$NEW_USER/.bashrc" 2>/dev/null; then
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "/home/$NEW_USER/.bashrc"
    fi
    local EXISTING_CRON
    EXISTING_CRON=$(su - "$NEW_USER" -c 'crontab -l 2>/dev/null' || true)
    if ! echo "$EXISTING_CRON" | grep -q 'tmp-cleanup'; then
        (echo "$EXISTING_CRON"; echo "0 4 * * * /home/$NEW_USER/.local/bin/tmp-cleanup >/dev/null 2>&1") \
            | su - "$NEW_USER" -c 'crontab -'
    fi
    log "/tmp cleanup installed (daily at 4am)"
}

server_main() {
    check_root

    log "Starting EasyClaw server setup..."

    # System hardening
    update_system
    create_user

    # Copy SSH keys to new user BEFORE hardening disables root login
    log "Setting up SSH access for $NEW_USER..."
    mkdir -p "/home/$NEW_USER/.ssh"
    cp /root/.ssh/authorized_keys "/home/$NEW_USER/.ssh/authorized_keys"
    chown -R "$NEW_USER:$NEW_USER" "/home/$NEW_USER/.ssh"
    chmod 700 "/home/$NEW_USER/.ssh"
    chmod 600 "/home/$NEW_USER/.ssh/authorized_keys"

    setup_ssh_hardening
    setup_firewall
    setup_fail2ban
    setup_swap
    setup_auto_updates

    # Package managers & tools
    install_homebrew
    install_node
    [ "$INSTALL_DOCKER" = true ] && install_docker
    [ "$INSTALL_CLAUDE_CODE" = true ] && install_claude_code
    [ "$INSTALL_CODEX" = true ] && install_codex

    # Cleanup
    setup_tmp_cleanup

    # OpenClaw (always in EasyClaw)
    install_openclaw_deps
    install_openclaw
    install_security_md

    # OpenClaw onboarding (interactive — asks for API keys)
    echo ""
    echo -e "${GREEN}── OpenClaw Onboarding ─────────────────────${NC}"
    echo ""
    echo "  OpenClaw will now ask for your API keys."
    echo "  Follow the prompts."
    echo ""
    su - "$NEW_USER" -c "openclaw onboard --install-daemon" || warn "openclaw onboard exited non-zero — continuing"

    # Post-onboarding extras
    setup_secrets_file
    install_op_audit_wrapper

    log "Running OpenClaw security audit..."
    su - "$NEW_USER" -c "openclaw security audit --fix" || warn "Security audit returned non-zero"

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║      Server Setup Complete!              ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
    echo ""
}

# =====================================================================
#  ENTRYPOINT
# =====================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --on-server) ON_SERVER=true; shift ;;
            --no-wizard) RUN_WIZARD=false; shift ;;
            --help|-h)
                echo "EasyClaw — One command to launch a secure OpenClaw server"
                echo ""
                echo "Usage:"
                echo "  /bin/bash -c \"\$(curl -fsSL .../setup.sh)\"   Run the wizard (from your laptop)"
                echo "  ./setup.sh --on-server                Run server setup (called automatically)"
                echo ""
                echo "Environment variables (headless mode):"
                echo "  HETZNER_TOKEN     Hetzner API token (required)"
                echo "  SERVER_TYPE       cpx11/cpx21/cpx31/cpx41 (default: cpx21)"
                echo "  SERVER_LOCATION   ash/hil/nbg1/hel1 (default: ash)"
                echo "  NEW_USER          Username (default: claw)"
                echo "  SSH_KEY_PATH      Path to SSH private key"
                exit 0
                ;;
            *) error "Unknown option: $1" ;;
        esac
    done
}

ON_SERVER=false
parse_args "$@"

if [ "$ON_SERVER" = true ]; then
    server_main
else
    local_main
fi
