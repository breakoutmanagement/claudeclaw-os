#!/usr/bin/env bash
# Restart ClaudeClaw bots — no sudo required.
# Main bot uses user systemd (Restart=always handles crashes automatically).
# Tutor bot uses system systemd (managed by root, but can be restarted here via pkill fallback).
#
# Usage: bash scripts/restart.sh [main|tutor|all]

set -euo pipefail
TARGET="${1:-all}"
PROJECT="/home/ccaudit/claudeclaw-os"

# User systemd needs XDG_RUNTIME_DIR
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"

restart_main() {
  echo "Restarting main bot via user systemd..."
  if systemctl --user restart com.claudeclaw.agent-main 2>/dev/null; then
    echo "Main bot restarted (user systemd)"
  else
    # Fallback: pkill + nohup (should not normally be needed)
    echo "User systemd unavailable — using pkill fallback"
    pkill -f "node.*dist/index\.js$" 2>/dev/null || true
    sleep 2
    cd "$PROJECT"
    nohup /usr/bin/node dist/index.js >> store/agent-main.log 2>&1 &
    echo "Main bot started (PID: $!)"
  fi
}

restart_tutor() {
  echo "Restarting tutor bot..."
  # Try user systemd first (if set up), then system systemd status check, then pkill
  if systemctl --user restart com.claudeclaw.agent-tutor 2>/dev/null; then
    echo "Tutor restarted (user systemd)"
  elif systemctl is-active claudeclaw-agent-tutor.service &>/dev/null; then
    echo "Tutor is running under system systemd — restart requires sudo (skipping)"
  else
    echo "Tutor not running — starting via nohup"
    pkill -f "node.*--agent tutor" 2>/dev/null || true
    sleep 2
    cd "$PROJECT"
    nohup /usr/bin/node dist/index.js --agent tutor >> store/agent-tutor.log 2>&1 &
    echo "Tutor started (PID: $!)"
  fi
}

case "$TARGET" in
  main)  restart_main ;;
  tutor) restart_tutor ;;
  all)   restart_main; sleep 2; restart_tutor ;;
  *)     echo "Usage: $0 [main|tutor|all]"; exit 1 ;;
esac
