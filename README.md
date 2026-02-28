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

## License

MIT
