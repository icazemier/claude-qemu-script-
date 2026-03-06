#!/bin/bash
# up.sh — Start the Claude Dev VM (QEMU + HVF/KVM)
# Supports: macOS Apple Silicon, Linux arm64, Linux x86_64
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# ─── Output helpers ──────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'
TOTAL_STEPS=5
CURRENT_STEP=0

die() { printf "${RED}ERROR:${NC} %s\n" "$*" >&2; exit 1; }

step() {
  CURRENT_STEP=$((CURRENT_STEP + 1))
  printf "${BOLD}[%d/%d]${NC} %s" "$CURRENT_STEP" "$TOTAL_STEPS" "$1"
}

ok() {
  local extra=""
  [ $# -gt 0 ] && extra=" ${CYAN}($1)${NC}"
  printf " ${GREEN}✓${NC}%b\n" "$extra"
}

fail() {
  printf " ${RED}✗${NC}\n"
  [ $# -gt 0 ] && printf "      ${RED}%s${NC}\n" "$1"
}

spinner_wait() {
  # Usage: spinner_wait "message" <timeout_secs> <check_command...>
  local msg="$1" timeout="$2"; shift 2
  local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local start=$SECONDS elapsed=0
  while ! "$@" 2>/dev/null; do
    elapsed=$(( SECONDS - start ))
    if [ "$elapsed" -ge "$timeout" ]; then
      return 1
    fi
    local i=$(( elapsed % ${#spin} ))
    printf "\r${BOLD}[%d/%d]${NC} %s ${CYAN}%s${NC} (%ds) " \
      "$CURRENT_STEP" "$TOTAL_STEPS" "$msg" "${spin:i:1}" "$elapsed"
    sleep 0.2
  done
  elapsed=$(( SECONDS - start ))
  printf "\r${BOLD}[%d/%d]${NC} %s" "$CURRENT_STEP" "$TOTAL_STEPS" "$msg"
  ok "took ${elapsed}s"
  return 0
}

# ─── Platform detection ───────────────────────────────────────────────────────

OS=$(uname -s | tr '[:upper:]' '[:lower:]')   # darwin | linux
ARCH=$(uname -m)                               # arm64 | aarch64 | x86_64
[ "$ARCH" = "aarch64" ] && ARCH=arm64          # normalise

PLATFORM="${OS}-${ARCH}"

case "$PLATFORM" in
  darwin-arm64)
    QEMU_BIN=qemu-system-aarch64
    MACHINE="virt,accel=hvf"
    FIRMWARE=/opt/homebrew/share/qemu/edk2-aarch64-code.fd
    FIRMWARE_TYPE=bios
    IMAGE_NAME=ubuntu-24.04-server-cloudimg-arm64.img
    IMAGE_URL=https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-arm64.img
    ISO_TOOL=hdiutil
    VNC_OPEN_CMD='open vnc://localhost:5900'
    ;;
  linux-arm64)
    QEMU_BIN=qemu-system-aarch64
    MACHINE="virt,accel=kvm"
    FIRMWARE=/usr/share/qemu-efi-aarch64/QEMU_EFI.fd
    FIRMWARE_TYPE=bios
    IMAGE_NAME=ubuntu-24.04-server-cloudimg-arm64.img
    IMAGE_URL=https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-arm64.img
    ISO_TOOL=genisoimage
    VNC_OPEN_CMD='vncviewer localhost:5900'
    ;;
  linux-x86_64)
    QEMU_BIN=qemu-system-x86_64
    MACHINE="q35,accel=kvm"
    FIRMWARE=/usr/share/OVMF/OVMF_CODE.fd
    FIRMWARE_TYPE=pflash
    IMAGE_NAME=ubuntu-24.04-server-cloudimg-amd64.img
    IMAGE_URL=https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img
    ISO_TOOL=genisoimage
    VNC_OPEN_CMD='vncviewer localhost:5900'
    ;;
  *)
    die "Unsupported platform: ${PLATFORM}. Supported: macOS Apple Silicon, Linux arm64, Linux x86_64"
    ;;
esac

# ─── Load .env ────────────────────────────────────────────────────────────────

if [ -f .env ]; then
  # shellcheck disable=SC1091
  set -a; source .env; set +a
fi

VM_MEMORY=${VM_MEMORY:-8192}
VM_CPUS=${VM_CPUS:-4}
SHARED_FOLDER=${SHARED_FOLDER:-}
FORWARDED_PORTS=${FORWARDED_PORTS:-}

# ─── File locking — prevent concurrent execution ─────────────────────────────

LOCKDIR="$SCRIPT_DIR/.up.lock"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  # Check if the owning process is still alive
  if [ -f "$LOCKDIR/pid" ]; then
    OLD_PID=$(cat "$LOCKDIR/pid" 2>/dev/null)
    if [ -n "$OLD_PID" ] && ! kill -0 "$OLD_PID" 2>/dev/null; then
      printf "${YELLOW}WARNING:${NC} Removing stale lock (PID $OLD_PID no longer running).\n" >&2
      rm -rf "$LOCKDIR"
      mkdir "$LOCKDIR" || die "Failed to acquire lock."
    else
      die "Another instance of up.sh is already running (PID $OLD_PID)."
    fi
  else
    rm -rf "$LOCKDIR"
    mkdir "$LOCKDIR" || die "Failed to acquire lock."
  fi
fi
echo $$ > "$LOCKDIR/pid"
trap 'rm -rf "$LOCKDIR" 2>/dev/null' EXIT

# ─── Step 1: Validate dependencies & environment ─────────────────────────────

step "Checking dependencies..."

command -v "$QEMU_BIN" &>/dev/null || \
  { fail; die "$QEMU_BIN not found. Install QEMU: brew install qemu (macOS) | sudo apt install qemu-system (Linux)"; }

command -v qemu-img &>/dev/null || \
  { fail; die "qemu-img not found. Install QEMU utils: brew install qemu | sudo apt install qemu-utils"; }

[ -f "$FIRMWARE" ] || \
  { fail; die "UEFI firmware not found: $FIRMWARE"; }

if [ "$ISO_TOOL" = "genisoimage" ]; then
  if ! command -v genisoimage &>/dev/null && ! command -v mkisofs &>/dev/null; then
    if command -v cloud-localds &>/dev/null; then
      ISO_TOOL=cloud-localds
    else
      fail; die "ISO tool not found. Install: sudo apt install genisoimage | sudo apt install cloud-image-utils"
    fi
  fi
  command -v genisoimage &>/dev/null || ISO_TOOL=mkisofs
fi

# Validate .env variables
if [ -n "$SHARED_FOLDER" ] && [ ! -d "$SHARED_FOLDER" ]; then
  fail; die "SHARED_FOLDER does not exist: $SHARED_FOLDER"
fi

if [ -n "$FORWARDED_PORTS" ]; then
  for port in ${FORWARDED_PORTS//,/ }; do
    port="${port// /}"
    [ -z "$port" ] && continue
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
      fail; die "Invalid port in FORWARDED_PORTS: $port"
    fi
  done
fi

# Check if key ports are already in use
check_port_free() {
  if bash -c "echo >/dev/tcp/localhost/$1" 2>/dev/null; then
    fail; die "Port $1 is already in use on the host. Stop the conflicting service first."
  fi
}
check_port_free 2222
check_port_free 5900

ok

# ─── Check if VM is already running ──────────────────────────────────────────

if [ -f vm.pid ]; then
  PID=$(cat vm.pid)
  if kill -0 "$PID" 2>/dev/null; then
    echo ""
    printf "${GREEN}VM is already running${NC} (PID $PID)\n"
    echo "  SSH:  ./ssh.sh"
    echo "  VNC:  $VNC_OPEN_CMD"
    echo "  Stop: ./stop.sh"
    exit 0
  else
    rm -f vm.pid
  fi
fi

# ─── Provision SSH key (passwordless access during first boot) ────────────────

PROVISION_KEY="$SCRIPT_DIR/provision_key"
if [ ! -f "$PROVISION_KEY" ]; then
  ssh-keygen -t ed25519 -f "$PROVISION_KEY" -N "" -C "claude-qemu-provision" -q
fi
PROVISION_PUBKEY=$(cat "${PROVISION_KEY}.pub")

# ─── First run: create disk + cloud-init ISO ──────────────────────────────────

if [ ! -f disk.qcow2 ]; then
  echo ""
  printf "${BOLD}First run detected — setting up VM...${NC}\n"

  # Download base image (resumable)
  mkdir -p images
  if [ ! -f "images/$IMAGE_NAME" ]; then
    echo "  Downloading Ubuntu 24.04 cloud image (~600 MB)..."
    curl -L -C - --progress-bar --connect-timeout 30 --max-time 600 \
      -o "images/$IMAGE_NAME.tmp" "$IMAGE_URL"
    # Verify image integrity — must be >100MB
    FILE_SIZE=$(stat -f%z "images/$IMAGE_NAME.tmp" 2>/dev/null || stat -c%s "images/$IMAGE_NAME.tmp" 2>/dev/null || echo 0)
    if [ "$FILE_SIZE" -lt 104857600 ]; then
      rm -f "images/$IMAGE_NAME.tmp"
      die "Downloaded image is too small (${FILE_SIZE} bytes). Download may be corrupt — try again."
    fi
    mv "images/$IMAGE_NAME.tmp" "images/$IMAGE_NAME"
  else
    echo "  Using cached image: images/$IMAGE_NAME"
  fi

  # Create 50 GB overlay disk
  echo "  Creating 50 GB disk overlay..."
  qemu-img create -b "images/$IMAGE_NAME" -F qcow2 -f qcow2 disk.qcow2 50G

  # Generate cloud-init/user-data with provision.sh embedded as base64
  echo "  Generating cloud-init user-data..."
  PROVISION_B64=$(base64 < provision.sh | tr -d '\n')

  cat > cloud-init/user-data << USERDATA
#cloud-config
hostname: claude-dev
ssh_pwauth: true

users:
  - name: claude
    uid: 1001
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: sudo
    shell: /bin/bash
    lock_passwd: false
    ssh_authorized_keys:
      - ${PROVISION_PUBKEY}

chpasswd:
  list: |
    claude:claude
  expire: false

write_files:
  - path: /tmp/provision.sh
    encoding: b64
    content: ${PROVISION_B64}
    permissions: '0755'

runcmd:
  - bash /tmp/provision.sh > /var/log/provision.log 2>&1
USERDATA

  # Build cloud-init seed disk
  echo "  Building cloud-init seed disk..."
  case "$ISO_TOOL" in
    hdiutil)
      rm -f cloud-init.iso
      hdiutil create -size 1m -fs MS-DOS -volname cidata \
        -o /tmp/cidata-seed.dmg 2>/dev/null
      hdiutil attach /tmp/cidata-seed.dmg -mountpoint /tmp/cidata-mount \
        -nobrowse -quiet
      cp cloud-init/user-data cloud-init/meta-data /tmp/cidata-mount/
      hdiutil detach /tmp/cidata-mount -quiet
      hdiutil convert /tmp/cidata-seed.dmg -format UDTO \
        -o /tmp/cidata-seed 2>/dev/null
      mv /tmp/cidata-seed.cdr cloud-init.iso
      rm -f /tmp/cidata-seed.dmg
      ;;
    genisoimage|mkisofs)
      "$ISO_TOOL" -output cloud-init.iso \
        -volid cidata \
        -joliet -rock \
        cloud-init/user-data cloud-init/meta-data \
        2>/dev/null
      ;;
    cloud-localds)
      cloud-localds cloud-init.iso cloud-init/user-data cloud-init/meta-data
      ;;
  esac

  echo "  First-run setup complete."
  echo ""
fi

# ─── Build QEMU arguments ─────────────────────────────────────────────────────

QEMU_ARGS=(
  -machine "$MACHINE"
  -cpu host
  -smp "$VM_CPUS"
  -m "$VM_MEMORY"
  -drive "file=disk.qcow2,format=qcow2,if=virtio"
  -drive "file=cloud-init.iso,format=raw,if=virtio,readonly=on"
  -device virtio-net-pci,netdev=net0
  -device virtio-gpu-pci \
  -device virtio-tablet-pci
  -device virtio-keyboard-pci
  -display vnc=127.0.0.1:0,lossy=on
  -k en-us
  -nographic
  -monitor unix:qemu-monitor.sock,server,nowait
)

# Firmware
case "$FIRMWARE_TYPE" in
  bios)
    QEMU_ARGS+=(-bios "$FIRMWARE")
    ;;
  pflash)
    QEMU_ARGS+=(-drive "if=pflash,format=raw,readonly=on,file=$FIRMWARE")
    ;;
esac

# Networking — build hostfwd string
NET="user,id=net0,hostfwd=tcp::2222-:22,hostfwd=tcp::5900-:5900"
if [ -n "$FORWARDED_PORTS" ]; then
  for port in ${FORWARDED_PORTS//,/ }; do
    port="${port// /}"
    [ -n "$port" ] && NET+=",hostfwd=tcp::${port}-:${port}"
  done
fi
QEMU_ARGS+=(-netdev "$NET")

# Shared folder via virtio-9p
if [ -n "$SHARED_FOLDER" ] && [ -d "$SHARED_FOLDER" ]; then
  QEMU_ARGS+=(-virtfs "local,path=${SHARED_FOLDER},mount_tag=shared,security_model=mapped-xattr")
fi

# ─── Step 2: Start QEMU ─────────────────────────────────────────────────────

FIRST_BOOT=false
[ ! -f disk.qcow2.initialized ] && FIRST_BOOT=true

step "Starting QEMU (${VM_CPUS} CPUs, ${VM_MEMORY} MB RAM)..."
QEMU_LOG=$(mktemp /tmp/qemu-err.XXXXXX)
"$QEMU_BIN" "${QEMU_ARGS[@]}" >"$QEMU_LOG" 2>&1 &
QEMU_PID=$!
echo "$QEMU_PID" > vm.pid

# Give QEMU a moment to fail on bad args / missing firmware, then verify it's alive
sleep 0.5
if ! kill -0 "$QEMU_PID" 2>/dev/null; then
  rm -f vm.pid
  fail
  echo "QEMU output:" >&2
  grep -v '^$\|warning:' "$QEMU_LOG" | head -5 >&2
  rm -f "$QEMU_LOG"
  die "QEMU exited immediately."
fi
rm -f "$QEMU_LOG"
ok "PID $QEMU_PID"

# ─── Step 3: Wait for SSH ────────────────────────────────────────────────────

# Check if sshd banner is present (not just TCP port open)
ssh_banner_check() {
  local banner
  # nc -w3 works on macOS and Linux (netcat-openbsd, ncat); avoid 'timeout' (missing on macOS)
  banner=$(echo "" | nc -w3 localhost 2222 2>/dev/null || true)
  [[ "$banner" == SSH-2.0-* ]]
}

CURRENT_STEP=$((CURRENT_STEP + 1))
if ! spinner_wait "Waiting for SSH..." 120 ssh_banner_check; then
  fail "Timed out after 120s"
  rm -f vm.pid
  kill "$QEMU_PID" 2>/dev/null || true
  die "SSH did not become available. Check VNC: $VNC_OPEN_CMD"
fi
# spinner_wait already incremented step and printed ok; undo double-count
CURRENT_STEP=$((CURRENT_STEP - 1))

# ─── SSH options used for provisioning ───────────────────────────────────────

SSH_OPTS=(-p 2222 -i "$PROVISION_KEY"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o BatchMode=yes
  -o ConnectTimeout=10
  -o ServerAliveInterval=5
  -o ServerAliveCountMax=3)

# ─── Step 4: First-boot provisioning ────────────────────────────────────────

if $FIRST_BOOT; then
  step "Provisioning VM (first boot)..."
  echo ""
  PROVISION_TIMEOUT=600  # 10 minutes max
  PROVISION_START=$SECONDS

  # Wait until the SSH key is actually accepted (cloud-init may still be writing authorized_keys)
  KEY_DEADLINE=$(( SECONDS + 120 ))
  while ! ssh "${SSH_OPTS[@]}" claude@localhost true 2>/dev/null; do
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
      rm -f vm.pid
      die "QEMU died while waiting for SSH key auth."
    fi
    if [ "$SECONDS" -ge "$KEY_DEADLINE" ]; then
      die "SSH key auth not accepted after 120s. Check VNC: $VNC_OPEN_CMD"
    fi
    sleep 2
  done

  # Stream provision log, watching for success/failure markers
  REMOTE_CMD='until [ -f /var/log/provision.log ]; do sleep 1; done
tail -n +1 -f /var/log/provision.log | while IFS= read -r line; do
  echo "$line"
  case "$line" in
    *"Provisioning complete"*) echo "__PROVISION_OK__"; break;;
    *"PROVISION FAILED"*) echo "__PROVISION_FAIL__"; break;;
  esac
done'

  PROVISION_RESULT=0
  ssh "${SSH_OPTS[@]}" claude@localhost "$REMOTE_CMD" \
    | while IFS= read -r line; do
        case "$line" in
          __PROVISION_OK__)   exit 0;;
          __PROVISION_FAIL__) exit 1;;
          *)
            elapsed=$(( SECONDS - PROVISION_START ))
            if [ "$elapsed" -ge "$PROVISION_TIMEOUT" ]; then
              echo "  ${RED}Provisioning timed out after ${PROVISION_TIMEOUT}s${NC}" >&2
              exit 1
            fi
            printf "      %s\n" "$line"
            ;;
        esac
      done || PROVISION_RESULT=$?

  if [ "$PROVISION_RESULT" -ne 0 ]; then
    printf "  ${RED}✗ Provisioning failed!${NC}\n"
    echo "  Check logs: ./ssh.sh 'cat /var/log/provision.log'"
    echo "  VNC: $VNC_OPEN_CMD"
    die "Provisioning did not complete successfully. The VM is running but not fully set up. Fix the issue and run: rm -f disk.qcow2.initialized && ./stop.sh && ./up.sh"
  fi

  # Only mark as initialized AFTER provisioning succeeds
  touch disk.qcow2.initialized

  printf "  ${GREEN}✓ Provisioning complete${NC}\n"
  echo ""
fi

# ─── Step 5: Done ────────────────────────────────────────────────────────────

if ! $FIRST_BOOT; then
  CURRENT_STEP=4  # skip provisioning step number
fi

step "VM ready!"
ok
echo ""
printf "  ${BOLD}SSH:${NC}   ./ssh.sh           (or: ssh -p 2222 claude@localhost)\n"
printf "  ${BOLD}VNC:${NC}   $VNC_OPEN_CMD\n"
printf "  ${BOLD}Stop:${NC}  ./stop.sh\n"
echo ""
