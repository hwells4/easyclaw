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

SETUP_LOG="/var/log/easyclaw-setup.log"

log() { echo -e "${GREEN}[easyclaw]${NC} $1"; }
warn() { echo -e "${YELLOW}[warn]${NC} $1"; }
error() { echo -e "${RED}[error]${NC} $1"; exit 1; }
step() { echo -e "\n${BLUE}${BOLD}── $1 ──${NC}\n"; }

# Run a command quietly — show a one-line status, log full output to file
quiet() {
    local label="$1"; shift
    echo -en "  ${label}... "
    if "$@" >> "$SETUP_LOG" 2>&1; then
        echo -e "${GREEN}done${NC}"
    else
        echo -e "${RED}failed${NC}"
        echo "  See $SETUP_LOG for details"
        return 1
    fi
}

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
    echo "  This wizard will:"
    echo ""
    echo "    1. Create a cloud server for you on Hetzner"
    echo "    2. Secure it (firewall, brute-force protection, encrypted access)"
    echo "    3. Install OpenClaw and start it up"
    echo ""
    echo "  The whole thing takes about 10 minutes. You just follow the prompts."
    echo ""
    echo "  Hetzner is the cloud provider that hosts your server."
    echo "  You'll need a Hetzner account and an API key to continue."
    echo "  Servers start at ~\$4/month and you can delete anytime."
    echo ""

    # ── Hetzner API key ──
    step "Hetzner API Key"

    local token_valid=false
    while [ "$token_valid" = false ]; do
        if ! ask_yes_no "Do you have your Hetzner API key ready?" "y"; then
            echo ""
            echo "  No problem! Here's how to get one:"
            echo ""
            echo "  ${BOLD}1.${NC} Go to ${BLUE}https://console.hetzner.cloud/${NC}"
            echo "     Create a free account if you don't have one."
            echo ""
            echo "  ${BOLD}2.${NC} Once logged in, create a new Project (or use the default one)."
            echo ""
            echo "  ${BOLD}3.${NC} Inside your project, click ${BOLD}Security${NC} in the left sidebar."
            echo ""
            echo "  ${BOLD}4.${NC} Click the ${BOLD}API Tokens${NC} tab, then ${BOLD}Generate API Token${NC}."
            echo ""
            echo "  ${BOLD}5.${NC} Give it a name (like \"easyclaw\"), select ${BOLD}Read & Write${NC} access,"
            echo "     and click Generate."
            echo ""
            echo "  ${BOLD}6.${NC} ${YELLOW}Copy the token now${NC} — you won't be able to see it again."
            echo ""

            echo -en "  Ready to continue? Press Enter when you have your token... "
            read -r
        fi

        echo ""
        echo "  Your token is only used during this setup and is never saved to disk."
        echo ""
        HETZNER_TOKEN=""
        while [ -z "$HETZNER_TOKEN" ]; do
            echo -en "  Paste your Hetzner API token: "
            read -rs HETZNER_TOKEN
            echo ""
            if [ -z "$HETZNER_TOKEN" ]; then
                echo "  Token can't be empty."
            fi
        done

        # Validate token
        echo -en "  Checking token with Hetzner... "
        local test_response
        test_response=$(hetzner_api GET /servers 2>/dev/null || true)
        if echo "$test_response" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'servers' in d" 2>/dev/null; then
            echo -e "${GREEN}valid!${NC}"
            token_valid=true
        else
            echo -e "${RED}invalid${NC}"
            echo ""
            echo "  That token didn't work. Let's try again."
            echo ""
        fi
    done

    # ── Server size ──
    step "Server Size"

    echo "  Pick a server size:"
    echo ""
    echo "    1)  Small       —  2 GB /  2 CPU  ~\$6/mo   Light usage"
    echo "    2)  Medium      —  4 GB /  3 CPU  ~\$11/mo  Recommended"
    echo "    3)  Large       —  8 GB /  4 CPU  ~\$19/mo  Heavy usage"
    echo "    4)  Extra Large — 16 GB /  8 CPU  ~\$34/mo  Power user"
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
    log "Updating system packages (this takes a few minutes)..."
    quiet "Updating package lists" apt-get update
    quiet "Upgrading installed packages" apt-get upgrade -y
    quiet "Installing required packages" apt-get install -y \
        curl wget git vim htop tmux ufw fail2ban unzip \
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
    # Passwordless sudo — no password was set (SSH key auth only)
    echo "$NEW_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$NEW_USER"
    chmod 440 "/etc/sudoers.d/$NEW_USER"
    log "User $NEW_USER created (SSH key auth, passwordless sudo)"
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
    if sshd -t >> "$SETUP_LOG" 2>&1; then
        # Ubuntu 24.04 uses "ssh", older versions use "sshd"
        systemctl restart ssh 2>/dev/null || systemctl restart sshd
        log "SSH hardened. Root login disabled, key auth only."
    else
        error "sshd config validation failed"
    fi
}

setup_firewall() {
    log "Configuring firewall..."
    {
        ufw default deny incoming
        ufw default allow outgoing
        ufw allow "$SSH_PORT/tcp"
        ufw allow 80/tcp
        ufw allow 443/tcp
        ufw allow "$OPENCLAW_PORT/tcp"
        ufw --force enable
    } >> "$SETUP_LOG" 2>&1
    log "Firewall enabled"
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
    systemctl enable fail2ban >> "$SETUP_LOG" 2>&1
    systemctl start fail2ban >> "$SETUP_LOG" 2>&1
    log "Brute-force protection enabled"
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
    mkswap /swapfile.img >> "$SETUP_LOG" 2>&1
    swapon /swapfile.img >> "$SETUP_LOG" 2>&1
    grep -q '/swapfile.img' /etc/fstab || echo '/swapfile.img none swap sw 0 0' >> /etc/fstab
    sysctl vm.swappiness=10 >> "$SETUP_LOG" 2>&1
    grep -q 'vm.swappiness' /etc/sysctl.conf || echo 'vm.swappiness=10' >> /etc/sysctl.conf
    log "Swap configured (${SWAP_SIZE_MB}MB)"
}

setup_auto_updates() {
    log "Enabling automatic security updates..."
    quiet "Installing auto-update tools" apt-get install -y unattended-upgrades
    cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF
    systemctl enable unattended-upgrades >> "$SETUP_LOG" 2>&1
    systemctl start unattended-upgrades >> "$SETUP_LOG" 2>&1
    log "Auto-updates enabled"
}

install_homebrew() {
    log "Installing Homebrew (this takes a couple minutes)..."
    if su - "$NEW_USER" -c 'command -v brew' &>/dev/null; then log "Already installed"; return; fi

    # Download installer to file
    curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o /tmp/brew-install.sh
    chmod +r /tmp/brew-install.sh

    # Homebrew REFUSES to run as root — must install as the claw user
    echo -en "  Installing Homebrew... "
    if su - "$NEW_USER" -c "NONINTERACTIVE=1 /bin/bash /tmp/brew-install.sh" >> "$SETUP_LOG" 2>&1; then
        echo -e "${GREEN}done${NC}"
    else
        echo -e "${RED}failed${NC}"
        echo "  Check $SETUP_LOG for details"
        rm -f /tmp/brew-install.sh
        error "Homebrew is required for OpenClaw plugins. Cannot continue."
    fi
    rm -f /tmp/brew-install.sh

    # Set up PATH for the claw user's shell
    if ! grep -q 'linuxbrew' "/home/$NEW_USER/.bashrc" 2>/dev/null; then
        echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' >> "/home/$NEW_USER/.bashrc"
        chown "$NEW_USER:$NEW_USER" "/home/$NEW_USER/.bashrc"
    fi

    echo -en "  Installing compiler tools... "
    if su - "$NEW_USER" -c 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)" && brew install gcc' >> "$SETUP_LOG" 2>&1; then
        echo -e "${GREEN}done${NC}"
    else
        echo -e "${RED}failed (non-critical)${NC}"
    fi

    log "Homebrew installed"
}

install_node() {
    log "Installing Node.js 22..."
    quiet "Adding Node.js repository" bash -c "curl -fsSL https://deb.nodesource.com/setup_22.x | bash -"
    quiet "Installing Node.js" apt-get install -y nodejs

    # Set up npm global prefix so claw user can `npm install -g` without root
    su - "$NEW_USER" -c 'mkdir -p ~/.npm-global && npm config set prefix ~/.npm-global' >> "$SETUP_LOG" 2>&1
    if ! grep -q 'npm-global' "/home/$NEW_USER/.bashrc" 2>/dev/null; then
        echo 'export PATH="$HOME/.npm-global/bin:$PATH"' >> "/home/$NEW_USER/.bashrc"
    fi

    log "Node.js $(node --version) installed"
}

install_docker() {
    log "Installing Docker..."
    if command -v docker &>/dev/null; then warn "Already installed"; return; fi
    {
        apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
        apt-get update
    } >> "$SETUP_LOG" 2>&1
    quiet "Installing Docker packages" apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    usermod -aG docker "$NEW_USER"
    systemctl enable docker >> "$SETUP_LOG" 2>&1 && systemctl start docker >> "$SETUP_LOG" 2>&1
    log "Docker installed"
}

install_claude_code() {
    curl -fsSL https://claude.ai/install.sh -o /tmp/claude-install.sh
    quiet "Installing Claude Code" su - "$NEW_USER" -c "bash /tmp/claude-install.sh" || warn "Claude Code install failed — install manually later"
    rm -f /tmp/claude-install.sh
}

install_codex() {
    quiet "Installing Codex" su - "$NEW_USER" -c "npm install -g @openai/codex" || warn "Codex install failed — install manually later"
}

install_openclaw_deps() {
    log "Installing Bun runtime..."
    curl -fsSL https://bun.sh/install -o /tmp/bun-install.sh
    quiet "Installing Bun" su - "$NEW_USER" -c "bash /tmp/bun-install.sh"
    rm -f /tmp/bun-install.sh
    if ! grep -q '\.bun/bin' "/home/$NEW_USER/.bashrc" 2>/dev/null; then
        echo 'export PATH="$HOME/.bun/bin:$PATH"' >> "/home/$NEW_USER/.bashrc"
    fi
}

install_openclaw() {
    log "Installing OpenClaw..."
    quiet "Downloading OpenClaw" su - "$NEW_USER" -c "npm install -g openclaw"
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

    # Send noisy package manager output here instead of the terminal
    mkdir -p "$(dirname "$SETUP_LOG")"
    : > "$SETUP_LOG"

    log "Starting EasyClaw server setup..."
    log "Full install log: $SETUP_LOG"

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
    [ "$INSTALL_DOCKER" = true ] && install_docker || warn "Docker install failed — skipping"
    [ "$INSTALL_CLAUDE_CODE" = true ] && install_claude_code || true
    [ "$INSTALL_CODEX" = true ] && install_codex || true

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
