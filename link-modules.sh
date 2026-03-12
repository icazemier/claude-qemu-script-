#!/bin/bash
# link-modules.sh — Relocate node_modules to the VM's local filesystem
# Run this INSIDE the VM, from your project directory on /home/claude/shared.
#
# Usage:
#   cd /home/claude/shared/my-project
#   ~/link-modules.sh          # creates symlink + runs npm install
#   ~/link-modules.sh --clean  # removes symlink and local modules for this project
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'

LOCAL_BASE="$HOME/.local-modules"
PROJECT_DIR="$(pwd)"
PROJECT_NAME="$(basename "$PROJECT_DIR")"
LOCAL_DIR="$LOCAL_BASE/$PROJECT_NAME"

# ─── Clean mode ──────────────────────────────────────────────────────────────

if [[ "${1:-}" == "--clean" ]]; then
  if [ -L "$PROJECT_DIR/node_modules" ]; then
    rm "$PROJECT_DIR/node_modules"
    printf "${GREEN}Removed node_modules symlink${NC}\n"
  fi
  if [ -d "$LOCAL_DIR" ]; then
    rm -rf "$LOCAL_DIR"
    printf "${GREEN}Removed local modules: $LOCAL_DIR${NC}\n"
  fi
  exit 0
fi

# ─── Sanity checks ──────────────────────────────────────────────────────────

if [ ! -f "$PROJECT_DIR/package.json" ]; then
  printf "${RED}ERROR:${NC} No package.json in current directory.\n" >&2
  echo "  Run this from your project root on the shared folder." >&2
  exit 1
fi

case "$PROJECT_DIR" in
  /home/*/shared/*) ;;
  *)
    printf "${YELLOW}WARNING:${NC} Not on the shared folder — symlink may not be needed.\n"
    read -rp "Continue anyway? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || exit 0
    ;;
esac

# ─── Setup ───────────────────────────────────────────────────────────────────

# Remove existing node_modules (directory or broken symlink)
if [ -d "$PROJECT_DIR/node_modules" ] && [ ! -L "$PROJECT_DIR/node_modules" ]; then
  printf "Removing existing node_modules directory...\n"
  rm -rf "$PROJECT_DIR/node_modules"
elif [ -L "$PROJECT_DIR/node_modules" ]; then
  rm "$PROJECT_DIR/node_modules"
fi

# Create local directory and symlink
mkdir -p "$LOCAL_DIR"
ln -s "$LOCAL_DIR" "$PROJECT_DIR/node_modules"

printf "${GREEN}Symlinked:${NC} node_modules -> $LOCAL_DIR\n"

# ─── Install ─────────────────────────────────────────────────────────────────

printf "Running npm install...\n\n"
npm install
