#!/bin/bash
# ssh.sh — SSH into the Claude Dev VM as the claude user
exec ssh -p 2222 \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o LogLevel=ERROR \
  claude@localhost "$@"
