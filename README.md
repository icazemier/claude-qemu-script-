# Claude Dev VM — QEMU Edition

A Claude Code development VM powered by QEMU with native hypervisor acceleration.

## Supported platforms

| Host | Accelerator |
|------|-------------|
| macOS Apple Silicon | HVF (Apple Hypervisor.framework) |
| Linux x86_64 | KVM |
| Linux arm64 | KVM |

---

## 1. Install prerequisites

**macOS:**
```bash
brew install qemu
brew install --cask vnc-viewer   # recommended VNC client
```

**Linux (Debian/Ubuntu):**
```bash
# x86_64
sudo apt install qemu-system-x86 qemu-utils genisoimage ovmf

# arm64 (add)
sudo apt install qemu-system-arm qemu-efi-aarch64
```

---

## 2. Start the VM

```bash
cd scripts/
./up.sh
```

First run downloads the Ubuntu 24.04 cloud image (~600 MB) and provisions the VM (~5 min). Subsequent starts take a few seconds.

---

## 3. Connect

```bash
./ssh.sh                  # SSH in as claude (password: claude)
```

**Desktop (VNC):**
```bash
# macOS — open RealVNC Viewer, connect to:
localhost:5900            # password: claude

# Linux
vncviewer localhost:5900
```

---

## 4. Daily commands

```bash
./up.sh          # Start VM
./stop.sh        # Graceful shutdown
./ssh.sh         # SSH in as claude
./destroy.sh     # Remove VM (keeps cached base image)
./destroy.sh --all  # Remove VM + base image (full clean)
```

**Inside the VM:**
```bash
claude           # Launch Claude Code
claude-flow      # Launch claude-flow orchestrator
```

---

## 5. Rebuild from scratch

To wipe the VM and start completely fresh (keeps the cached base image so no re-download):

```bash
./stop.sh
rm disk.qcow2 disk.qcow2.initialized cloud-init.iso cloud-init/user-data
./up.sh
```

To also re-download the Ubuntu base image:

```bash
./stop.sh
rm disk.qcow2 disk.qcow2.initialized cloud-init.iso cloud-init/user-data images/ubuntu-24.04-server-cloudimg-arm64.img
./up.sh
```

First boot takes ~5 min for cloud-init to provision. Watch progress:

```bash
./ssh.sh 'tail -f /var/log/provision.log'
```

---

## Configuration

Copy `.env.example` to `.env` to customise:

```bash
cp .env.example .env
```

| Variable | Default | Description |
|---|---|---|
| `SHARED_FOLDER` | _(none)_ | Host path mounted at `/home/claude/shared` in the VM |
| `FORWARDED_PORTS` | _(none)_ | Comma-separated ports to forward, e.g. `3000,5173` |
| `VM_MEMORY` | `8192` | RAM in MB |
| `VM_CPUS` | `4` | vCPU count |

Changes take effect after `./stop.sh && ./up.sh`.

---

## Credentials

| | |
|---|---|
| User | `claude` |
| Password | `claude` |
| SSH port | `2222` |
| VNC port | `5900` |

---

## What's installed

- **XFCE4** desktop with LightDM auto-login
- **nvm** v0.40.1 + Node.js 22
- **yarn** package manager
- **Claude Code** (`@anthropic-ai/claude-code`)
- **claude-flow** (`claude-flow@alpha`)
- **Playwright** + Chromium browser
- **Azure CLI** (`az`) via Microsoft apt repository
- **UFW** firewall (SSH open, QEMU NAT allowed)
- **OpenSSH** server with password auth enabled
- **virtio-9p** shared folder support

---

## Shared folder

Set `SHARED_FOLDER` in `.env`:

```
SHARED_FOLDER=/Users/you/myproject
```

The directory appears at `/home/claude/shared` inside the VM. If not set, `/home/claude/shared` is an empty directory.

---

## Port forwarding

Set `FORWARDED_PORTS` in `.env` to expose VM services on the host:

```
FORWARDED_PORTS=3000,3001,5173
```

Services are reachable at `localhost:<port>` on the host.

---

## Connecting to host services

Services running on your Mac/Linux host are reachable from inside the VM at the QEMU NAT gateway address:

```
10.0.2.2
```

For example, if you run a database on the host:

| Service | VM connection string |
|---------|----------------------|
| MongoDB | `mongodb://10.0.2.2:27017` |
| Redis | `redis://10.0.2.2:6379` |
| PostgreSQL | `postgresql://user:pass@10.0.2.2:5432/db` |
| Any HTTP API | `http://10.0.2.2:<port>` |

No extra configuration is needed — QEMU's user-mode NAT routes traffic to the host automatically.

---

## Troubleshooting

**VNC mouse not working:**
Ensure you are using RealVNC Viewer (`brew install --cask vnc-viewer`). macOS Screen Sharing can be slow and may have input issues with QEMU.

**SSH connection refused after `./up.sh`:**
First boot takes ~5 min for cloud-init provisioning. Check progress:
```bash
./ssh.sh 'tail -f /var/log/provision.log'
```

**VM won't start — firmware not found:**
- macOS: `brew reinstall qemu`
- Linux arm64: `sudo apt install qemu-efi-aarch64`
- Linux x86_64: `sudo apt install ovmf`

**Shared folder not appearing:**
Ensure `SHARED_FOLDER` is set in `.env` before starting the VM.

---

## Architecture

| Feature | Implementation |
|---------|---------------|
| Hypervisor | QEMU + HVF (macOS) / KVM (Linux) |
| Provisioning | Cloud-init (first boot only) |
| Display | VNC on port 5900 via `virtio-gpu-pci` |
| Mouse | `virtio-tablet-pci` (absolute positioning) |
| Display resize | `xrandr` polling service |
| Shared folders | `virtio-9p` (`-virtfs` flag) |
| Networking | QEMU user-mode NAT; host reachable at `10.0.2.2` |
| Disk | 50 GB qcow2 overlay on Ubuntu 24.04 cloud image |
| State | `disk.qcow2` + `vm.pid` |

---

## References

### Hypervisor & QEMU
- [QEMU documentation](https://www.qemu.org/docs/master/) — system emulator and virtualizer
- [QEMU user-mode networking](https://www.qemu.org/docs/master/system/net.html) — NAT, hostfwd, 10.0.2.2 gateway
- [Apple Hypervisor.framework (HVF)](https://developer.apple.com/documentation/hypervisor) — native acceleration on Apple Silicon
- [KVM (Kernel-based Virtual Machine)](https://www.linux-kvm.org/page/Documents) — native acceleration on Linux
- [EDK2 / OVMF UEFI firmware](https://github.com/tianocore/tianocore.github.io/wiki/OVMF) — UEFI for QEMU VMs
- [qcow2 disk image format](https://www.qemu.org/docs/master/system/images.html) — copy-on-write overlay disk

### virtio devices
- [virtio specification](https://docs.oasis-open.org/virtio/virtio/v1.2/virtio-v1.2.html) — standard paravirtualized device interface
- [virtio-gpu](https://www.qemu.org/docs/master/system/devices/virtio-gpu.html) — paravirtualized display adapter
- [virtio-9p / Plan 9 filesystem](https://wiki.qemu.org/Documentation/9psetup) — shared folder support (`-virtfs`)
- [virtio-net](https://wiki.qemu.org/Documentation/Networking) — paravirtualized network adapter

### Provisioning
- [Cloud-init documentation](https://cloudinit.readthedocs.io/) — first-boot VM provisioning
- [Cloud-init NoCloud datasource](https://cloudinit.readthedocs.io/en/latest/reference/datasources/nocloud.html) — seed disk via ISO/FAT image
- [Ubuntu cloud images](https://cloud-images.ubuntu.com/) — pre-built minimal Ubuntu images

### Desktop & display
- [XFCE4](https://www.xfce.org/) — lightweight desktop environment
- [LightDM](https://github.com/canonical/lightdm) — display manager with auto-login support
- [xrandr](https://www.x.org/wiki/Projects/XRandR/) — X display resize/configuration tool

### Tools installed in the VM
- [nvm](https://github.com/nvm-sh/nvm) — Node.js version manager
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code/overview) — Anthropic's agentic coding CLI
- [claude-flow](https://github.com/ruvnet/claude-flow) — multi-agent orchestration for Claude
- [Playwright](https://playwright.dev/) — browser automation framework
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/) — Microsoft Azure command-line tool

---

## License

MIT
