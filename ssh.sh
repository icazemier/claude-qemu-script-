#!/bin/bash
# ssh.sh — SSH into the Claude Dev VM as the claude user
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROVISION_KEY="$SCRIPT_DIR/provision_key"

KEY_OPT=()
[ -f "$PROVISION_KEY" ] && KEY_OPT=(-i "$PROVISION_KEY")

exec ssh -p 2222 \
  "${KEY_OPT[@]}" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o LogLevel=ERROR \
  claude@localhost "$@"
