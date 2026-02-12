#!/bin/bash
#
# EasyClaw — One-script setup for a secure OpenClaw server
# https://github.com/hwells4/easyclaw
#

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration (defaults, overridden by wizard or CLI flags)
NEW_USER="${NEW_USER:-claw}"
SSH_PORT="${SSH_PORT:-22}"
OPENCLAW_PORT="${OPENCLAW_PORT:-7860}"
INSTALL_OPENCLAW="${INSTALL_OPENCLAW:-false}"
OPENCLAW_CONFIG="${OPENCLAW_CONFIG:-}"
INSTALL_DOCKER="${INSTALL_DOCKER:-true}"
INSTALL_CLAUDE_CODE="${INSTALL_CLAUDE_CODE:-true}"
INSTALL_CODEX="${INSTALL_CODEX:-true}"
RUN_WIZARD="${RUN_WIZARD:-true}"

log() {
    echo -e "${GREEN}[easyclaw]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[warn]${NC} $1"
}

error() {
    echo -e "${RED}[error]${NC} $1"
    exit 1
}

# Helper: ask a yes/no question, return 0 for yes, 1 for no
ask_yes_no() {
    local prompt="$1"
    local default="${2:-y}"  # default to yes

    local yn_hint="[Y/n]"
    if [ "$default" = "n" ]; then
        yn_hint="[y/N]"
    fi

    while true; do
        echo -en "  ${prompt} ${yn_hint}: "
        read -r answer
        answer="${answer:-$default}"
        case "$answer" in
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
            *) echo "  Please answer y or n." ;;
        esac
    done
}

# Interactive setup wizard — runs before anything is installed
run_wizard() {
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║          EasyClaw Setup Wizard           ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
    echo ""
    echo "  Quick, easy, and secure OpenClaw setup."
    echo "  One script. One wizard. Done."
    echo ""

    # ── Server size recommendation ──
    echo -e "${GREEN}── Server Size ─────────────────────────────${NC}"
    echo ""
    echo "  If you haven't created your VPS yet, here are our recommendations:"
    echo ""
    echo "    1)  4 GB RAM / 2 CPU   ~\$4-6/mo     Light usage, single agent"
    echo "    2)  8 GB RAM / 4 CPU   ~\$8-10/mo    Recommended — most users"
    echo "    3) 16 GB RAM / 6 CPU   ~\$15-18/mo   Multiple agents, heavy usage"
    echo "    4) 32 GB RAM / 8 CPU   ~\$28-35/mo   Power user, concurrent workloads"
    echo ""
    echo "  We recommend option 2 (8 GB) for most users."
    echo "  Hetzner, DigitalOcean, and Contabo all work well."
    echo ""
    echo -en "  Press Enter to continue... "
    read -r
    echo ""

    # ── Username ──
    echo -e "${GREEN}── User Account ────────────────────────────${NC}"
    echo ""
    echo "  We'll create a non-root user to run your services."
    while true; do
        echo -en "  Username [${NEW_USER}]: "
        read -r input_user
        if [ -z "$input_user" ]; then
            break
        fi
        if [[ "$input_user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
            NEW_USER="$input_user"
            break
        else
            echo "  Invalid username. Must start with a lowercase letter or underscore,"
            echo "  followed by up to 31 lowercase letters, digits, underscores, or hyphens."
        fi
    done
    echo ""

    # ── What to install ──
    echo -e "${GREEN}── Tools to Install ────────────────────────${NC}"
    echo ""
    echo "  The basics (Node.js, security hardening, swap) are always installed."
    echo "  Choose which optional tools you'd like:"
    echo ""

    if ask_yes_no "Install Docker? (container runtime)" "y"; then
        INSTALL_DOCKER=true
    else
        INSTALL_DOCKER=false
    fi

    if ask_yes_no "Install Claude Code? (Anthropic's CLI agent)" "y"; then
        INSTALL_CLAUDE_CODE=true
    else
        INSTALL_CLAUDE_CODE=false
    fi

    if ask_yes_no "Install Codex? (OpenAI's CLI agent)" "y"; then
        INSTALL_CODEX=true
    else
        INSTALL_CODEX=false
    fi

    echo ""

    # ── OpenClaw ──
    echo -e "${GREEN}── OpenClaw ────────────────────────────────${NC}"
    echo ""
    echo "  OpenClaw is the AI assistant that runs on this server."
    echo "  It connects to Telegram, manages agents, and runs a gateway."
    echo ""

    if ask_yes_no "Install OpenClaw?" "y"; then
        INSTALL_OPENCLAW=true

        echo ""
        echo "  After the system is set up, OpenClaw will run its own"
        echo "  onboarding wizard. It will ask you to paste API keys"
        echo "  for the services you want to connect (Telegram, etc.)."
        echo ""
        echo "  You don't need them right now — just have them ready"
        echo "  when that step comes up. Here's what you might need:"
        echo ""
        echo "    - Kimi K2.5 API key:  https://platform.moonshot.cn/console/api-keys"
        echo "      (recommended model — fast, capable, affordable)"
        echo "    - Telegram bot token: Message @BotFather on Telegram"
        echo "    - 1Password token:    https://my.1password.com/developer"
        echo "      (optional, for secrets management)"
        echo ""
        echo -en "  Press Enter when you're ready to continue... "
        read -r
    else
        INSTALL_OPENCLAW=false
    fi

    echo ""

    # ── Summary ──
    echo -e "${GREEN}── Setup Summary ───────────────────────────${NC}"
    echo ""
    echo "  User:          $NEW_USER"
    echo "  Docker:        $([ "$INSTALL_DOCKER" = true ] && echo "yes" || echo "no")"
    echo "  Claude Code:   $([ "$INSTALL_CLAUDE_CODE" = true ] && echo "yes" || echo "no")"
    echo "  Codex:         $([ "$INSTALL_CODEX" = true ] && echo "yes" || echo "no")"
    echo "  OpenClaw:      $([ "$INSTALL_OPENCLAW" = true ] && echo "yes" || echo "no")"
    echo ""
    echo "  Always included: Node.js 22, firewall, fail2ban, swap,"
    echo "                   SSH hardening, auto-updates, tmp cleanup"
    echo ""

    if ! ask_yes_no "Look good? Start the setup?" "y"; then
        echo ""
        echo "  Setup cancelled. Run again when you're ready."
        exit 0
    fi

    echo ""
    log "Starting setup with your selections..."
    echo ""
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --install-openclaw)
                INSTALL_OPENCLAW=true
                shift
                ;;
            --config)
                OPENCLAW_CONFIG="$2"
                INSTALL_OPENCLAW=true
                shift 2
                ;;
            --no-wizard)
                RUN_WIZARD=false
                shift
                ;;
            --help|-h)
                echo "EasyClaw — One-script OpenClaw server setup"
                echo ""
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --install-openclaw    Install OpenClaw after system setup"
                echo "  --config <file>       Use config file for OpenClaw setup"
                echo "  --no-wizard           Skip interactive wizard (use defaults/flags)"
                echo "  --help, -h            Show this help message"
                echo ""
                echo "Environment variables:"
                echo "  NEW_USER              Username to create (default: claw)"
                echo "  SSH_PORT              SSH port (default: 22)"
                echo "  OPENCLAW_PORT         OpenClaw port (default: 7860)"
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                ;;
        esac
    done
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (use sudo)"
    fi
}

update_system() {
    log "Updating system packages..."
    apt-get update
    apt-get upgrade -y
    apt-get install -y \
        curl \
        wget \
        git \
        vim \
        htop \
        tmux \
        ufw \
        fail2ban \
        software-properties-common \
        apt-transport-https \
        ca-certificates \
        gnupg \
        lsb-release \
        build-essential \
        python3 \
        python3-pip \
        python3-venv
}

create_user() {
    log "Creating user: $NEW_USER"

    if id "$NEW_USER" &>/dev/null; then
        warn "User $NEW_USER already exists"
        return
    fi

    # Create user with sudo access
    useradd -m -s /bin/bash "$NEW_USER"
    usermod -aG sudo "$NEW_USER"

    log "User $NEW_USER created. Set a password:"
    passwd "$NEW_USER" || warn "passwd failed — set password manually later with: sudo passwd $NEW_USER"
}

setup_ssh() {
    log "Configuring SSH hardening..."

    # Use a drop-in file for idempotent, non-destructive hardening
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

    # Validate config before restarting
    if sshd -t; then
        systemctl restart sshd
        log "SSH configured. Root login disabled, key auth only."
    else
        error "sshd config validation failed — check /etc/ssh/sshd_config.d/99-easyclaw-hardening.conf"
    fi
    warn "Make sure you have SSH key access before disconnecting!"
}

setup_firewall() {
    log "Configuring UFW firewall..."

    ufw default deny incoming
    ufw default allow outgoing
    ufw allow "$SSH_PORT/tcp"
    ufw allow 80/tcp
    ufw allow 443/tcp

    # Only open OpenClaw port if installing OpenClaw; Tailscale is recommended for remote access
    if [ "$INSTALL_OPENCLAW" = true ]; then
        ufw allow "$OPENCLAW_PORT/tcp"
    fi

    ufw --force enable
    log "Firewall enabled. Allowed ports: $SSH_PORT (SSH), 80/443 (HTTP/HTTPS)$([ "$INSTALL_OPENCLAW" = true ] && echo ", $OPENCLAW_PORT (OpenClaw)")"
}

setup_fail2ban() {
    log "Configuring Fail2ban..."

    # Create custom jail config
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
    log "Fail2ban configured and started"
}

install_homebrew() {
    log "Installing Homebrew..."

    if command -v brew &> /dev/null; then
        warn "Homebrew already installed"
        return
    fi

    # Install Homebrew (Linuxbrew)
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    # Add to path for current session and new user
    if ! grep -q 'linuxbrew' /root/.bashrc 2>/dev/null; then
        echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' >> /root/.bashrc
    fi
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"

    # Also add to new user
    if ! grep -q 'linuxbrew' "/home/$NEW_USER/.bashrc" 2>/dev/null; then
        echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' >> "/home/$NEW_USER/.bashrc"
    fi
    chown "$NEW_USER:$NEW_USER" "/home/$NEW_USER/.bashrc"

    brew install gcc
    log "Homebrew installed"
}

install_docker() {
    log "Installing Docker..."

    if command -v docker &> /dev/null; then
        warn "Docker already installed"
        return
    fi

    # Remove old versions
    apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

    # Add Docker's official GPG key
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    # Add repository
    echo \
        "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
        "$(. /etc/os-release && echo "$VERSION_CODENAME")" stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Add user to docker group
    usermod -aG docker "$NEW_USER"

    systemctl enable docker
    systemctl start docker

    log "Docker installed. User $NEW_USER added to docker group."
}

install_node() {
    log "Installing Node.js 22.x (via Nodesource)..."

    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt-get install -y nodejs

    log "Node.js $(node --version) installed"
}

install_openclaw_deps() {
    log "Installing OpenClaw dependencies..."

    # Install bun as the target user directly (avoids mv /root/.bun failures on re-run)
    su - "$NEW_USER" -c 'curl -fsSL https://bun.sh/install | bash'

    # Ensure bun is in PATH
    if ! grep -q '\.bun/bin' "/home/$NEW_USER/.bashrc" 2>/dev/null; then
        echo 'export PATH="$HOME/.bun/bin:$PATH"' >> "/home/$NEW_USER/.bashrc"
    fi

    log "OpenClaw dependencies installed"
}

install_openclaw() {
    log "Installing OpenClaw (as $NEW_USER)..."

    # Install as user to avoid dual-install issues with root vs user node_modules
    su - "$NEW_USER" -c "npm install -g openclaw"

    # Create config directory
    mkdir -p "/home/$NEW_USER/.config/openclaw"
    chown -R "$NEW_USER:$NEW_USER" "/home/$NEW_USER/.config"

    if [ -n "$OPENCLAW_CONFIG" ] && [ -f "$OPENCLAW_CONFIG" ]; then
        log "Using provided config: $OPENCLAW_CONFIG"
        cp "$OPENCLAW_CONFIG" "/home/$NEW_USER/.config/openclaw/config.json"
        chown "$NEW_USER:$NEW_USER" "/home/$NEW_USER/.config/openclaw/config.json"
    fi

    log "OpenClaw installed to user-local path"
}

setup_openclaw_service() {
    log "Creating OpenClaw gateway systemd service..."

    local OPENCLAW_BIN
    OPENCLAW_BIN=$(su - "$NEW_USER" -c "which openclaw" 2>/dev/null || echo "/home/$NEW_USER/.local/bin/openclaw")

    cat > /etc/systemd/system/openclaw-gateway.service << EOF
[Unit]
Description=OpenClaw Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$NEW_USER
WorkingDirectory=/home/$NEW_USER
EnvironmentFile=-/etc/openclaw-secrets
Environment=PATH=/home/$NEW_USER/.local/bin:/home/$NEW_USER/.bun/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=$OPENCLAW_BIN gateway start --foreground
Restart=always
RestartSec=3
StartLimitIntervalSec=300
StartLimitBurst=5
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/home/$NEW_USER/.openclaw /home/$NEW_USER/.config
PrivateTmp=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
SyslogIdentifier=openclaw-gateway
TimeoutStartSec=30
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable openclaw-gateway

    log "OpenClaw gateway service created"
    log "Start with: sudo systemctl start openclaw-gateway"
}

setup_swap() {
    log "Setting up swap..."

    if swapon --show | grep -q '/swapfile.img'; then
        warn "Swap already active at /swapfile.img"
        return
    fi

    # Dynamic swap sizing based on available RAM
    TOTAL_RAM_MB=$(grep MemTotal /proc/meminfo | awk '{print int($2/1024)}')
    if [ "$TOTAL_RAM_MB" -le 16384 ]; then
        SWAP_SIZE_MB=$TOTAL_RAM_MB
    else
        SWAP_SIZE_MB=16384
    fi

    if [ -f /swapfile.img ]; then
        warn "/swapfile.img exists but is not active, activating..."
        chmod 0600 /swapfile.img
        mkswap /swapfile.img
        swapon /swapfile.img
    else
        fallocate -l "${SWAP_SIZE_MB}M" /swapfile.img
        chmod 0600 /swapfile.img
        mkswap /swapfile.img
        swapon /swapfile.img
    fi

    # Persist in fstab
    if ! grep -q '/swapfile.img' /etc/fstab; then
        echo '/swapfile.img none swap sw 0 0' >> /etc/fstab
    fi

    # Lower swappiness — prefer RAM, use swap as safety net
    sysctl vm.swappiness=10
    if ! grep -q 'vm.swappiness' /etc/sysctl.conf; then
        echo 'vm.swappiness=10' >> /etc/sysctl.conf
    fi

    log "${SWAP_SIZE_MB}MB swap configured (swappiness=10)"
}

install_claude_code() {
    log "Installing Claude Code CLI..."
    su - "$NEW_USER" -c 'curl -fsSL https://claude.ai/install.sh | bash' || warn "Claude Code install failed — install manually later"
    log "Claude Code CLI install step completed"
}

install_codex() {
    log "Installing Codex CLI..."
    su - "$NEW_USER" -c "npm install -g @openai/codex" || warn "Codex install failed — install manually later"
    log "Codex CLI install step completed"
}

install_security_md() {
    log "Installing SECURITY.md template..."

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
    log "SECURITY.md installed at ~/.openclaw/workspace/SECURITY.md"
}

setup_secrets_file() {
    log "Setting up secrets file..."

    if [ -f /etc/openclaw-secrets ]; then
        warn "/etc/openclaw-secrets already exists, skipping"
        return
    fi

    cat > /etc/openclaw-secrets << 'EOF'
# OpenClaw secrets — managed by EasyClaw setup
# Add environment variables here; they are loaded by the openclaw-gateway service.
# OP_SERVICE_ACCOUNT_TOKEN=
EOF

    chmod 0600 /etc/openclaw-secrets
    chown root:root /etc/openclaw-secrets

    log "Created /etc/openclaw-secrets (root:root 600)"
    log "Edit it to add your OP_SERVICE_ACCOUNT_TOKEN or other secrets"
}

install_op_audit_wrapper() {
    log "Installing 1Password CLI audit wrapper..."

    local OP_REAL="/home/${NEW_USER}/.local/bin/op.real"
    local OP_PATH="/home/${NEW_USER}/.local/bin/op"

    # Only wrap if op is installed at the expected path
    if [ ! -f "$OP_PATH" ] || [ -f "$OP_REAL" ]; then
        warn "op not found at $OP_PATH or already wrapped, skipping"
        return
    fi

    mv "$OP_PATH" "$OP_REAL"

    cat > "$OP_PATH" << 'WRAPPER'
#!/bin/bash
# Audit wrapper for 1Password CLI — logs all invocations
LOG_DIR="$HOME/.openclaw/logs"
mkdir -p "$LOG_DIR"
echo "$(date -Iseconds) [op] $*" >> "$LOG_DIR/op-audit.log"
exec "$HOME/.local/bin/op.real" "$@"
WRAPPER

    chmod +x "$OP_PATH"
    chown "$NEW_USER:$NEW_USER" "$OP_PATH" "$OP_REAL"

    log "op audit wrapper installed (logs to ~/.openclaw/logs/op-audit.log)"
}

setup_auto_updates() {
    log "Configuring automatic security updates..."

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

    log "Automatic security updates enabled"
}

setup_tmp_cleanup() {
    log "Installing /tmp cleanup cron..."

    # Install the cleanup script
    local SCRIPT_DIR
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    mkdir -p "/home/$NEW_USER/.local/bin"
    if [ -f "$SCRIPT_DIR/scripts/tmp-cleanup.sh" ]; then
        cp "$SCRIPT_DIR/scripts/tmp-cleanup.sh" "/home/$NEW_USER/.local/bin/tmp-cleanup"
    else
        # Fetch from repo if running via curl pipe
        curl -fsSL https://raw.githubusercontent.com/hwells4/easyclaw/main/scripts/tmp-cleanup.sh \
            -o "/home/$NEW_USER/.local/bin/tmp-cleanup"
    fi
    chmod +x "/home/$NEW_USER/.local/bin/tmp-cleanup"
    chown "$NEW_USER:$NEW_USER" "/home/$NEW_USER/.local/bin/tmp-cleanup"

    # Ensure ~/.local/bin is in PATH
    if ! grep -q '\.local/bin' "/home/$NEW_USER/.bashrc" 2>/dev/null; then
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "/home/$NEW_USER/.bashrc"
    fi

    # Install cron job (as the service user, not root)
    local EXISTING_CRON
    EXISTING_CRON=$(su - "$NEW_USER" -c 'crontab -l 2>/dev/null' || true)
    if echo "$EXISTING_CRON" | grep -q 'tmp-cleanup'; then
        warn "tmp-cleanup cron already exists"
    else
        (echo "$EXISTING_CRON"; echo "0 4 * * * /home/$NEW_USER/.local/bin/tmp-cleanup >/dev/null 2>&1 # Safe /tmp cleanup (indexes CASS first)") \
            | su - "$NEW_USER" -c 'crontab -'
    fi

    # Also install CASS auto-index cron if cass is available
    if su - "$NEW_USER" -c 'command -v cass' &>/dev/null; then
        if ! echo "$EXISTING_CRON" | grep -q 'cass index'; then
            (su - "$NEW_USER" -c 'crontab -l 2>/dev/null'; echo "*/30 * * * * \$(command -v cass) index --json >/dev/null 2>&1 # Auto-index CASS sessions") \
                | su - "$NEW_USER" -c 'crontab -'
            log "CASS auto-index cron installed (every 30 minutes)"
        fi
    fi

    log "/tmp cleanup installed: runs daily at 4am, removes files older than 2 days"
    log "Manual usage: tmp-cleanup --dry-run --verbose"
}

print_summary() {
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║        EasyClaw Setup Complete!          ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
    echo ""
    echo "  User:        $NEW_USER"
    echo "  SSH port:    $SSH_PORT"
    echo "  Swap:        dynamic (based on RAM)"
    echo ""
    echo "  Installed:"
    echo "    - Node.js 22, Homebrew"
    [ "$INSTALL_DOCKER" = true ]      && echo "    - Docker"
    [ "$INSTALL_CLAUDE_CODE" = true ] && echo "    - Claude Code"
    [ "$INSTALL_CODEX" = true ]       && echo "    - Codex"
    [ "$INSTALL_OPENCLAW" = true ]    && echo "    - OpenClaw"
    echo ""

    if [ "$INSTALL_OPENCLAW" = true ]; then
        echo "  OpenClaw commands:"
        echo "    Start gateway:  sudo systemctl start openclaw-gateway"
        echo "    Check status:   sudo systemctl status openclaw-gateway"
        echo "    View logs:      sudo journalctl -u openclaw-gateway -f"
        echo ""
        echo "  Post-setup:"
        echo "    - Edit /etc/openclaw-secrets to add any extra secrets"
        echo "    - Review ~/.openclaw/workspace/SECURITY.md"
        echo ""
    else
        echo "  Next steps:"
        echo "    1. Copy your SSH key:"
        echo "       ssh-copy-id $NEW_USER@<server-ip>"
        echo ""
        echo "    2. Switch to the new user:"
        echo "       su - $NEW_USER"
        echo ""
        echo "    3. Install OpenClaw later:"
        echo "       npm install -g openclaw && openclaw onboard"
        echo ""
    fi

    echo -e "  ${YELLOW}IMPORTANT:${NC} Test SSH access as $NEW_USER before closing this session!"
    echo ""
}

# Main
main() {
    parse_args "$@"

    check_root

    # Run interactive wizard (unless --no-wizard or piped input)
    if [ "$RUN_WIZARD" = true ] && [ -t 0 ]; then
        run_wizard
    else
        log "Starting EasyClaw setup..."
    fi

    # System hardening (always)
    update_system
    create_user
    setup_ssh
    setup_firewall
    setup_fail2ban
    setup_swap
    setup_auto_updates

    # Package managers & tools
    install_homebrew
    install_node

    if [ "$INSTALL_DOCKER" = true ]; then
        install_docker
    fi

    if [ "$INSTALL_CLAUDE_CODE" = true ]; then
        install_claude_code
    fi

    if [ "$INSTALL_CODEX" = true ]; then
        install_codex
    fi

    # Cleanup
    setup_tmp_cleanup

    # OpenClaw (if selected)
    if [ "$INSTALL_OPENCLAW" = true ]; then
        install_openclaw_deps
        install_openclaw
        install_security_md

        # Launch OpenClaw's own onboarding (interactive)
        echo ""
        echo -e "${GREEN}── OpenClaw Onboarding ─────────────────────${NC}"
        echo ""
        echo "  OpenClaw will now run its own setup wizard."
        echo "  It will ask you to paste API keys for the services"
        echo "  you want to connect. Follow the prompts."
        echo ""
        su - "$NEW_USER" -c "openclaw onboard" || warn "openclaw onboard exited non-zero — continuing with post-onboarding setup"

        # Post-onboarding hardening (must run even if onboard failed)
        setup_secrets_file
        install_op_audit_wrapper
        setup_openclaw_service

        # Run security audit
        log "Running OpenClaw security audit..."
        su - "$NEW_USER" -c "openclaw security audit --fix" || warn "Security audit returned non-zero (review output above)"
    fi

    print_summary
}

# Run main if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
