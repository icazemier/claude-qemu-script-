#!/bin/bash
# up.sh — Start the Claude Dev VM (QEMU + HVF/KVM)
# Supports: macOS Apple Silicon, Linux arm64, Linux x86_64
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

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
    echo "Unsupported platform: ${PLATFORM}"
    echo "Supported: macOS Apple Silicon, Linux arm64, Linux x86_64"
    exit 1
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

# ─── Dependency checks ────────────────────────────────────────────────────────

die() { echo "ERROR: $*" >&2; exit 1; }

command -v "$QEMU_BIN" &>/dev/null || \
  die "$QEMU_BIN not found. Install QEMU: brew install qemu  (macOS) | sudo apt install qemu-system  (Linux)"

command -v qemu-img &>/dev/null || \
  die "qemu-img not found. Install QEMU utils: brew install qemu | sudo apt install qemu-utils"

[ -f "$FIRMWARE" ] || \
  die "UEFI firmware not found: $FIRMWARE
  macOS:      brew install qemu  (includes edk2 firmware)
  Linux arm64: sudo apt install qemu-efi-aarch64
  Linux x86_64: sudo apt install ovmf"

if [ "$ISO_TOOL" = "genisoimage" ]; then
  if ! command -v genisoimage &>/dev/null && ! command -v mkisofs &>/dev/null; then
    if command -v cloud-localds &>/dev/null; then
      ISO_TOOL=cloud-localds
    else
      die "ISO tool not found. Install one of: sudo apt install genisoimage  |  sudo apt install cloud-image-utils"
    fi
  fi
  # Prefer mkisofs if genisoimage is missing but mkisofs exists
  command -v genisoimage &>/dev/null || ISO_TOOL=mkisofs
fi

# ─── Check if VM is already running ──────────────────────────────────────────

if [ -f vm.pid ]; then
  PID=$(cat vm.pid)
  if kill -0 "$PID" 2>/dev/null; then
    echo "VM is already running (PID $PID)"
    echo "  SSH:  ./ssh.sh"
    echo "  VNC:  $VNC_OPEN_CMD"
    echo "  Stop: ./stop.sh"
    exit 0
  else
    echo "Removing stale vm.pid (process $PID is gone)..."
    rm -f vm.pid
  fi
fi

# ─── First run: create disk + cloud-init ISO ──────────────────────────────────

if [ ! -f disk.qcow2 ]; then
  echo "==> First run detected — setting up VM..."

  # Download base image
  mkdir -p images
  if [ ! -f "images/$IMAGE_NAME" ]; then
    echo "==> Downloading Ubuntu 24.04 cloud image (~600 MB)..."
    curl -L --progress-bar -o "images/$IMAGE_NAME.tmp" "$IMAGE_URL"
    mv "images/$IMAGE_NAME.tmp" "images/$IMAGE_NAME"
  else
    echo "==> Using cached image: images/$IMAGE_NAME"
  fi

  # Create 50 GB overlay disk
  echo "==> Creating 50 GB disk overlay..."
  qemu-img create -b "images/$IMAGE_NAME" -F qcow2 -f qcow2 disk.qcow2 50G

  # Generate cloud-init/user-data with provision.sh embedded as base64
  echo "==> Generating cloud-init user-data..."
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
  # macOS: create a FAT32 raw image labeled "cidata" — reliably detected by
  # Linux blkid/cloud-init (hdiutil makehybrid produces an HFS primary which
  # Linux reads first, hiding the ISO 9660 cidata label from cloud-init).
  echo "==> Building cloud-init seed disk..."
  case "$ISO_TOOL" in
    hdiutil)
      rm -f cloud-init.iso
      # Create a 1 MB FAT32 image, mount it, copy files, unmount, convert to raw
      hdiutil create -size 1m -fs MS-DOS -volname cidata \
        -o /tmp/cidata-seed.dmg 2>/dev/null
      hdiutil attach /tmp/cidata-seed.dmg -mountpoint /tmp/cidata-mount \
        -nobrowse -quiet
      cp cloud-init/user-data cloud-init/meta-data /tmp/cidata-mount/
      hdiutil detach /tmp/cidata-mount -quiet
      # Convert DMG → raw image (UDTO = raw CD/DVD, extension becomes .cdr)
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

  echo "==> First-run setup complete."
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
  -display vnc=127.0.0.1:0,lossy
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
if [ -n "$SHARED_FOLDER" ]; then
  if [ ! -d "$SHARED_FOLDER" ]; then
    echo "Warning: SHARED_FOLDER does not exist: $SHARED_FOLDER (skipping)"
  else
    QEMU_ARGS+=(-virtfs "local,path=${SHARED_FOLDER},mount_tag=shared,security_model=mapped-xattr")
  fi
fi

# ─── Start VM ─────────────────────────────────────────────────────────────────

FIRST_BOOT=false
[ ! -f disk.qcow2.initialized ] && FIRST_BOOT=true

echo "==> Starting VM (${VM_CPUS} CPUs, ${VM_MEMORY} MB RAM)..."
"$QEMU_BIN" "${QEMU_ARGS[@]}" &>/dev/null &
echo $! > vm.pid

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Claude Dev VM is starting!                              ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  SSH:   ./ssh.sh           (or: ssh -p 2222 claude@localhost)"
echo "  VNC:   $VNC_OPEN_CMD"
echo "  Stop:  ./stop.sh"
echo ""

if $FIRST_BOOT; then
  touch disk.qcow2.initialized
  echo "  First boot — waiting for SSH..."
  while ! nc -z localhost 2222 2>/dev/null; do
    sleep 3
  done
  echo "  SSH is up. Streaming provision log (password: claude):"
  echo ""

  SSH_OPTS="-p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
  # Wait for log file to appear, then tail it
  REMOTE_CMD='until [ -f /var/log/provision.log ]; do sleep 1; done; tail -f /var/log/provision.log'

  {
    if command -v sshpass &>/dev/null; then
      sshpass -p claude ssh $SSH_OPTS claude@localhost "$REMOTE_CMD" 2>/dev/null
    else
      ssh $SSH_OPTS claude@localhost "$REMOTE_CMD"
    fi
  } | while IFS= read -r line; do
      echo "  $line"
      [[ "$line" == *"Provisioning complete"* ]] && break
    done || true

  echo ""
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║  Provisioning complete — VM is ready!                   ║"
  echo "║  Run: ./ssh.sh                                          ║"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo ""
fi
