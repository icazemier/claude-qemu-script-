#!/bin/bash
# provision.sh — First-boot provisioner for the Claude Dev VM (QEMU edition)
# Runs via cloud-init on first boot. Safe to re-run (idempotent).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ─── Create / configure claude user ──────────────────────────────────────────
# cloud-init may have already created the user; this block is idempotent.
if ! id claude &>/dev/null; then
  useradd -m -u 1001 -s /bin/bash claude
fi

echo "claude:claude" | chpasswd
usermod -aG sudo claude
echo "claude ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/claude
chmod 440 /etc/sudoers.d/claude

# ─── Ensure system clock is synced before any network/TLS operations ─────────
# Cloud-init runcmd can run before chrony/systemd-timesyncd has stepped the
# clock; TLS certificate validation fails if the date is stuck near epoch 0.
timedatectl set-ntp true 2>/dev/null || true
chronyc makestep 2>/dev/null || true
# Wait up to 30 s for the clock to be within 10 years of now
for _ in $(seq 1 30); do
  year=$(date +%Y)
  [ "$year" -ge 2024 ] && break
  sleep 1
done

# ─── Update packages ──────────────────────────────────────────────────────────
apt-get update
apt-get upgrade -y

# ─── Install apt packages ─────────────────────────────────────────────────────
apt-get install -y \
  build-essential \
  git \
  curl \
  wget \
  vim \
  openssh-server \
  ca-certificates \
  gnupg \
  xfwm4 \
  xfce4-panel \
  xfce4-session \
  xfce4-settings \
  xfdesktop4 \
  xfce4-terminal \
  xfconf \
  thunar \
  lightdm \
  lightdm-gtk-greeter \
  x11-xserver-utils

# ─── Azure CLI ───────────────────────────────────────────────────────────────
# MIT licensed. Installs via Microsoft's official apt repository.
curl -sLS https://packages.microsoft.com/keys/microsoft.asc \
  | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg
chmod go+r /etc/apt/keyrings/microsoft.gpg
echo "Types: deb
URIs: https://packages.microsoft.com/repos/azure-cli/
Suites: $(lsb_release -cs)
Components: main
Architectures: $(dpkg --print-architecture)
Signed-by: /etc/apt/keyrings/microsoft.gpg" \
  > /etc/apt/sources.list.d/azure-cli.sources
apt-get update
apt-get install -y azure-cli

# ─── Enable SSH password authentication ──────────────────────────────────────
# Ubuntu 24.04 cloud images disable password auth by default.
CLOUDSSH=/etc/ssh/sshd_config.d/60-cloudimg-settings.conf
if [ -f "$CLOUDSSH" ]; then
  sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' "$CLOUDSSH"
  grep -q "^PasswordAuthentication" "$CLOUDSSH" || echo "PasswordAuthentication yes" >> "$CLOUDSSH"
else
  echo "PasswordAuthentication yes" > "$CLOUDSSH"
fi

# ─── Enable services ──────────────────────────────────────────────────────────
systemctl enable ssh
systemctl restart ssh

# ─── Firewall (UFW) ───────────────────────────────────────────────────────────
apt-get install -y ufw

ufw default deny incoming
ufw default allow outgoing

# Allow SSH from anywhere
ufw allow 22/tcp

# Allow all traffic from QEMU user-mode NAT gateway
ufw allow from 10.0.2.0/24

ufw --force enable

# ─── Configure LightDM auto-login ────────────────────────────────────────────
groupadd -f nopasswdlogin
usermod -aG nopasswdlogin claude

cat > /etc/lightdm/lightdm.conf << 'EOF'
[Seat:*]
autologin-user=claude
autologin-user-timeout=0
autologin-session=xfce
EOF

# ─── Install nvm and Node.js 22 for claude user ───────────────────────────────
su - claude -c 'curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash'
su - claude -c 'source ~/.nvm/nvm.sh && nvm install 22 && nvm alias default 22'

# ─── Install npm globals (as claude, via nvm) ─────────────────────────────────
su - claude -c 'source ~/.nvm/nvm.sh && npm install -g @anthropic-ai/claude-code'
su - claude -c 'source ~/.nvm/nvm.sh && npm install -g claude-flow@alpha'
su - claude -c 'source ~/.nvm/nvm.sh && npm install -g playwright'

# Playwright system deps (apt, as root) then install browser as claude
apt-get install -y \
  libnss3 libatk-bridge2.0-0 libdrm2 libxcomposite1 \
  libxdamage1 libxrandr2 libgbm1 libpango-1.0-0 libcairo2 \
  libasound2t64 libxshmfence1 libx11-xcb1 2>/dev/null || true
su - claude -c 'source ~/.nvm/nvm.sh && npx playwright install chromium'

# ─── Auto-resize display for virtio-gpu ──────────────────────────────────────
# Polls xrandr and applies the preferred resolution when it changes.
# This replaces the VirtualBox vbox-autoresize service from the vagrant version.
cat > /usr/local/bin/virtio-autoresize << 'SCRIPT'
#!/bin/bash
while true; do
  output=$(DISPLAY=:0 xrandr 2>/dev/null) || { sleep 2; continue; }
  preferred=$(echo "$output" | grep -A1 "Virtual-1 connected" | tail -1 | awk '{print $1}')
  current=$(echo "$output" | grep "Virtual-1 connected" | grep -oP '\d+x\d+' | head -1)
  if [ -n "$preferred" ] && [ -n "$current" ] && [ "$preferred" != "$current" ]; then
    DISPLAY=:0 xrandr --output Virtual-1 --preferred 2>/dev/null || \
      DISPLAY=:0 xrandr --output Virtual-1 --auto 2>/dev/null || true
  fi
  sleep 2
done
SCRIPT
chmod +x /usr/local/bin/virtio-autoresize

cat > /etc/systemd/system/virtio-autoresize.service << 'UNIT'
[Unit]
Description=virtio-gpu display auto-resize
After=lightdm.service

[Service]
ExecStart=/usr/local/bin/virtio-autoresize
Restart=always
User=claude
Environment=XAUTHORITY=/home/claude/.Xauthority

[Install]
WantedBy=graphical.target
UNIT
systemctl enable virtio-autoresize

# ─── Start desktop ────────────────────────────────────────────────────────────
systemctl enable lightdm
systemctl set-default graphical.target
systemctl start lightdm
sleep 2
systemctl start virtio-autoresize

# ─── Shared folder via virtio-9p ─────────────────────────────────────────────
mkdir -p /home/claude/shared
chown claude:claude /home/claude/shared

# Add fstab entry with nofail — silently skipped if QEMU -virtfs is not present.
if ! grep -q "shared.*9p" /etc/fstab; then
  echo "shared /home/claude/shared 9p trans=virtio,version=9p2000.L,rw,_netdev,nofail 0 0" >> /etc/fstab
fi
mount /home/claude/shared 2>/dev/null || true

# ─── Welcome message in .bashrc ───────────────────────────────────────────────
cat >> /home/claude/.bashrc << 'BASHRC'

# ─── Start ssh-agent if not already running ───────────────────────────────
SSH_AGENT_SOCK="$HOME/.ssh/agent.sock"
export SSH_AUTH_SOCK="$SSH_AGENT_SOCK"
if [ ! -S "$SSH_AGENT_SOCK" ] || ! ssh-add -l &>/dev/null 2>&1; then
  rm -f "$SSH_AGENT_SOCK"
  eval "$(ssh-agent -a "$SSH_AGENT_SOCK" -s)" > /dev/null
fi

# ─── Claude Dev Environment ───────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Welcome to the Claude Dev VM!                          ║"
echo "║                                                         ║"
echo "║  To get started, run: claude                            ║"
echo "║                                                         ║"
echo "║  Authentication options:                                 ║"
echo "║    1. Claude.ai subscription — claude will prompt you   ║"
echo "║       to log in via the browser on first run            ║"
echo "║    2. API key — export ANTHROPIC_API_KEY=your-key       ║"
echo "║                                                         ║"
echo "║  Available tools:                                       ║"
echo "║    nvm            Node version manager                  ║"
echo "║    claude         Claude Code                           ║"
echo "║    claude-flow    claude-flow orchestrator               ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
BASHRC
chown claude:claude /home/claude/.bashrc

# ─── Desktop terminal shortcut ────────────────────────────────────────────────
mkdir -p /home/claude/Desktop
cat > /home/claude/Desktop/claude-terminal.desktop << 'DESKTOP'
[Desktop Entry]
Version=1.0
Type=Application
Name=Claude Terminal
Comment=Open terminal for Claude Code
Exec=xfce4-terminal
Icon=utilities-terminal
Terminal=false
Categories=System;TerminalEmulator;
DESKTOP
chmod +x /home/claude/Desktop/claude-terminal.desktop
chown -R claude:claude /home/claude/Desktop

# ─── Clean up caches ──────────────────────────────────────────────────────────
apt-get clean
rm -rf /var/lib/apt/lists/*
su - claude -c 'source ~/.nvm/nvm.sh && npm cache clean --force' || true

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Provisioning complete!                                  ║"
echo "║  Log in as: claude / claude                              ║"
echo "║  Run 'claude' to authenticate and get started           ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
