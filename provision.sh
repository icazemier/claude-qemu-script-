#!/bin/bash
# provision.sh — First-boot provisioner for the Claude Dev VM (QEMU edition)
# Runs via cloud-init on first boot. Safe to re-run (idempotent).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ─── Error handling ──────────────────────────────────────────────────────────

trap 'log "PROVISION FAILED at line $LINENO (exit code $?)"; exit 1' ERR

# ─── Logging ─────────────────────────────────────────────────────────────────

PROVISION_START=$SECONDS
TOTAL_PROVISION_STEPS=15
PROVISION_STEP=0

log() {
  local elapsed=$(( SECONDS - PROVISION_START ))
  local ts=$(printf "%02d:%02d:%02d" $((elapsed/3600)) $(((elapsed%3600)/60)) $((elapsed%60)))
  echo "[$ts] $*"
}

provision_step() {
  PROVISION_STEP=$((PROVISION_STEP + 1))
  log "[$PROVISION_STEP/$TOTAL_PROVISION_STEPS] $1"
}

# ─── Retry helper for network operations ─────────────────────────────────────

retry() {
  local attempts=3 delay=5 attempt=1
  while true; do
    if "$@"; then
      return 0
    fi
    if [ "$attempt" -ge "$attempts" ]; then
      log "Command failed after $attempts attempts: $*"
      return 1
    fi
    log "Attempt $attempt failed, retrying in ${delay}s..."
    sleep "$delay"
    delay=$((delay * 2))
    attempt=$((attempt + 1))
  done
}

# ─── Fix BOOT partition fstab issue ─────────────────────────────────────────
# Ubuntu 24.04 cloud images reference LABEL=BOOT which doesn't exist on
# QEMU virtio disks, causing boot failures / maintenance mode.

provision_step "Fixing fstab entries..."
if ! blkid -L BOOT &>/dev/null; then
  sed -i '/^LABEL=BOOT/d' /etc/fstab
  log "Removed non-existent LABEL=BOOT from /etc/fstab"
else
  log "LABEL=BOOT partition exists, fstab OK"
fi

# ─── Create / configure claude user ──────────────────────────────────────────

provision_step "Configuring claude user..."
if ! id claude &>/dev/null; then
  useradd -m -u 1001 -s /bin/bash claude
fi

echo "claude:claude" | chpasswd
usermod -aG sudo claude
echo "claude ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/claude
chmod 440 /etc/sudoers.d/claude

# ─── Ensure system clock is synced before any network/TLS operations ─────────

provision_step "Syncing system clock..."
timedatectl set-ntp true 2>/dev/null || true
chronyc makestep 2>/dev/null || true
# Wait up to 60s for the clock to be within range
for i in $(seq 1 60); do
  year=$(date +%Y)
  if [ "$year" -ge 2024 ]; then
    log "Clock synced: $(date)"
    break
  fi
  [ "$i" -eq 60 ] && log "WARNING: Clock still not synced after 60s (year=$year)"
  sleep 1
done
timedatectl status 2>/dev/null || true

# ─── Update packages ──────────────────────────────────────────────────────────

provision_step "Updating packages..."
retry apt-get update
apt-get upgrade -y

# ─── Install apt packages ─────────────────────────────────────────────────────

provision_step "Installing apt packages..."
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
  x11-xserver-utils \
  gitg

# ─── Azure CLI ───────────────────────────────────────────────────────────────

provision_step "Installing Azure CLI..."
retry curl -sLS --connect-timeout 30 --max-time 300 \
  https://packages.microsoft.com/keys/microsoft.asc \
  | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg
chmod go+r /etc/apt/keyrings/microsoft.gpg
echo "Types: deb
URIs: https://packages.microsoft.com/repos/azure-cli/
Suites: $(lsb_release -cs)
Components: main
Architectures: $(dpkg --print-architecture)
Signed-by: /etc/apt/keyrings/microsoft.gpg" \
  > /etc/apt/sources.list.d/azure-cli.sources
retry apt-get update
apt-get install -y azure-cli

# ─── Enable SSH password authentication ──────────────────────────────────────

provision_step "Configuring SSH..."
CLOUDSSH=/etc/ssh/sshd_config.d/60-cloudimg-settings.conf
if [ -f "$CLOUDSSH" ]; then
  sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' "$CLOUDSSH"
  grep -q "^PasswordAuthentication" "$CLOUDSSH" || echo "PasswordAuthentication yes" >> "$CLOUDSSH"
else
  echo "PasswordAuthentication yes" > "$CLOUDSSH"
fi

systemctl enable ssh
systemctl restart ssh
# Verify SSH is running
if systemctl is-active --quiet ssh; then
  log "SSH service is active"
else
  log "WARNING: SSH service failed to start"
fi

# ─── Firewall (UFW) ───────────────────────────────────────────────────────────

provision_step "Configuring firewall..."
apt-get install -y ufw

ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow from 10.0.2.0/24
ufw --force enable

# ─── Configure LightDM auto-login ────────────────────────────────────────────

provision_step "Configuring desktop..."
groupadd -f nopasswdlogin
usermod -aG nopasswdlogin claude

cat > /etc/lightdm/lightdm.conf << 'EOF'
[Seat:*]
autologin-user=claude
autologin-user-timeout=0
autologin-session=xfce
EOF

# ─── Install nvm and Node.js 22 for claude user ───────────────────────────────

provision_step "Installing Node.js 22 via nvm..."
su - claude -c 'retry_inner() { local i; for i in 1 2 3; do "$@" && return 0; sleep $((i*5)); done; return 1; }; retry_inner curl --connect-timeout 30 --max-time 300 -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash'
su - claude -c 'source ~/.nvm/nvm.sh && nvm install 22 && nvm alias default 22'

# ─── Install npm globals (as claude, via nvm) ─────────────────────────────────

provision_step "Installing npm global packages..."
su - claude -c 'source ~/.nvm/nvm.sh && npm install -g yarn'
su - claude -c 'source ~/.nvm/nvm.sh && npm install -g @anthropic-ai/claude-code'
su - claude -c 'source ~/.nvm/nvm.sh && npm install -g claude-flow@alpha'
su - claude -c 'source ~/.nvm/nvm.sh && npm install -g playwright'

# Playwright system deps (apt, as root) then install browser as claude
apt-get install -y \
  libnss3 libatk-bridge2.0-0 libdrm2 libxcomposite1 \
  libxdamage1 libxrandr2 libgbm1 libpango-1.0-0 libcairo2 \
  libasound2t64 libxshmfence1 libx11-xcb1 2>/dev/null || true
su - claude -c 'source ~/.nvm/nvm.sh && npx playwright install chromium'

# ─── Install .NET SDK 8.0 for claude user ────────────────────────────────

provision_step "Installing .NET SDK 8.0..."
su - claude -c 'curl -fsSL https://dot.net/v1/dotnet-install.sh | bash /dev/stdin --channel 8.0'

# ─── Auto-resize display for virtio-gpu ──────────────────────────────────────

provision_step "Setting up display auto-resize..."
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
# Verify LightDM started
if systemctl is-active --quiet lightdm; then
  log "LightDM service is active"
else
  log "WARNING: LightDM service failed to start"
fi
systemctl start virtio-autoresize

# ─── Shared folder via virtio-9p ─────────────────────────────────────────────

mkdir -p /home/claude/shared
chown claude:claude /home/claude/shared

if ! grep -q "shared.*9p" /etc/fstab; then
  echo "shared /home/claude/shared 9p trans=virtio,version=9p2000.L,rw,_netdev,nofail 0 0" >> /etc/fstab
fi
mount /home/claude/shared 2>/dev/null || true

# ─── Write .bashrc (complete, with git branch prompt) ────────────────────────

cat > /home/claude/.bashrc << 'BASHRC'
# ~/.bashrc: executed by bash(1) for non-login shells.
# see /usr/share/doc/bash/examples/startup-files (in the package bash-doc)
# for examples

# .NET SDK
export DOTNET_ROOT="$HOME/.dotnet"
export PATH="$PATH:$DOTNET_ROOT"

# If not running interactively, don't do anything
case $- in
    *i*) ;;
      *) return;;
esac

# don't put duplicate lines or lines starting with space in the history.
# See bash(1) for more options
HISTCONTROL=ignoreboth

# append to the history file, don't overwrite it
shopt -s histappend

# for setting history length see HISTSIZE and HISTFILESIZE in bash(1)
HISTSIZE=1000
HISTFILESIZE=2000

# check the window size after each command and, if necessary,
# update the values of LINES and COLUMNS.
shopt -s checkwinsize

# If set, the pattern "**" used in a pathname expansion context will
# match all files and zero or more directories and subdirectories.
#shopt -s globstar

# make less more friendly for non-text input files, see lesspipe(1)
[ -x /usr/bin/lesspipe ] && eval "$(SHELL=/bin/sh lesspipe)"

# set variable identifying the chroot you work in (used in the prompt below)
if [ -z "${debian_chroot:-}" ] && [ -r /etc/debian_chroot ]; then
    debian_chroot=$(cat /etc/debian_chroot)
fi

# set a fancy prompt (non-color, unless we know we "want" color)
case "$TERM" in
    xterm-color|*-256color) color_prompt=yes;;
esac

# uncomment for a colored prompt, if the terminal has the capability; turned
# off by default to not distract the user: the focus in a terminal window
# should be on the output of commands, not on the prompt
#force_color_prompt=yes

if [ -n "$force_color_prompt" ]; then
    if [ -x /usr/bin/tput ] && tput setaf 1 >&/dev/null; then
    # We have color support; assume it's compliant with Ecma-48
    # (ISO/IEC-6429). (Lack of such support is extremely rare, and such
    # a case would tend to support setf rather than setaf.)
    color_prompt=yes
    else
    color_prompt=
    fi
fi

# Git branch in prompt
parse_git_branch() {
  git branch 2>/dev/null | sed -n 's/* \(.*\)/ (\1)/p'
}

if [ "$color_prompt" = yes ]; then
    PS1='${debian_chroot:+($debian_chroot)}\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[33m\]$(parse_git_branch)\[\033[00m\]\$ '
else
    PS1='${debian_chroot:+($debian_chroot)}\u@\h:\w$(parse_git_branch)\$ '
fi
unset color_prompt force_color_prompt

# If this is an xterm set the title to user@host:dir
case "$TERM" in
xterm*|rxvt*)
    PS1="\[\e]0;${debian_chroot:+($debian_chroot)}\u@\h: \w\a\]$PS1"
    ;;
*)
    ;;
esac

# enable color support of ls and also add handy aliases
if [ -x /usr/bin/dircolors ]; then
    test -r ~/.dircolors && eval "$(dircolors -b ~/.dircolors)" || eval "$(dircolors -b)"
    alias ls='ls --color=auto'
    #alias dir='dir --color=auto'
    #alias vdir='vdir --color=auto'

    alias grep='grep --color=auto'
    alias fgrep='fgrep --color=auto'
    alias egrep='egrep --color=auto'
fi

# colored GCC warnings and errors
#export GCC_COLORS='error=01;31:warning=01;35:note=01;36:caret=01;32:locus=01:quote=01'

# some more ls aliases
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'

# Add an "alert" alias for long running commands.  Use like so:
#   sleep 10; alert
alias alert='notify-send --urgency=low -i "$([ $? = 0 ] && echo terminal || echo error)" "$(history|tail -n1|sed -e '\''s/^\s*[0-9]\+\s*//;s/[;&|]\s*alert$//'\'')"'

# Alias definitions.
# You may want to put all your additions into a separate file like
# ~/.bash_aliases, instead of adding them here directly.
# See /usr/share/doc/bash-doc/examples in the bash-doc package.

if [ -f ~/.bash_aliases ]; then
    . ~/.bash_aliases
fi

# enable programmable completion features (you don't need to enable
# this, if it's already enabled in /etc/bash.bashrc and /etc/profile
# sources /etc/bash.bashrc).
if ! shopt -oq posix; then
  if [ -f /usr/share/bash-completion/bash_completion ]; then
    . /usr/share/bash-completion/bash_completion
  elif [ -f /etc/bash_completion ]; then
    . /etc/bash_completion
  fi
fi

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion

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
echo "║    dotnet         .NET SDK 8.0                          ║"
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

# ─── Swap (4 GB) ─────────────────────────────────────────────────────────────

provision_step "Setting up swap..."
if [ ! -f /swapfile ]; then
  # Check available disk space (need at least 5 GB free for 4 GB swap + headroom)
  avail_kb=$(df / --output=avail | tail -1 | tr -d ' ')
  if [ "$avail_kb" -ge 5242880 ]; then
    fallocate -l 4G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    if ! grep -q '/swapfile' /etc/fstab; then
      echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    log "4 GB swap created"
  else
    log "WARNING: Not enough disk space for swap (${avail_kb}KB available, need 5GB)"
  fi
else
  log "Swap already exists"
fi

# ─── Raise inotify file-watch limit ──────────────────────────────────────────

echo 'fs.inotify.max_user_watches=524288' > /etc/sysctl.d/99-inotify-watches.conf
sysctl --system

# ─── Clean up caches ──────────────────────────────────────────────────────────

provision_step "Cleaning up..."
apt-get clean
rm -rf /var/lib/apt/lists/*
su - claude -c 'source ~/.nvm/nvm.sh && npm cache clean --force && yarn cache clean' || true

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Provisioning complete!                                  ║"
echo "║  Log in as: claude / claude                              ║"
echo "║  Run 'claude' to authenticate and get started           ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
