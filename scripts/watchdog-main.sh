#!/usr/bin/env bash
# Watchdog for the main ClaudeClaw bot.
# Normally user systemd (Restart=always) handles crashes automatically.
# This cron job is a belt-and-suspenders fallback for cases where
# systemd itself gets stuck (e.g. rapid restart loop throttle).
# Run every 5 minutes via cron.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."
LOG="$PROJECT_ROOT/store/watchdog-main.log"
AGENT_LOG="$PROJECT_ROOT/store/agent-main.log"

export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"

# Check user systemd first — this is the primary manager
if systemctl --user is-active com.claudeclaw.agent-main &>/dev/null; then
  exit 0
fi

# Not active — try to kick it via systemd
echo "[$(date '+%Y-%m-%d %H:%M:%S')] main bot not running — attempting systemd restart" >> "$LOG"
if systemctl --user restart com.claudeclaw.agent-main 2>/dev/null; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] restarted via user systemd" >> "$LOG"
  exit 0
fi

# Systemd unavailable — check if process is actually running despite systemd not seeing it
if pgrep -f "dist/index.js$" > /dev/null 2>&1; then
  exit 0
fi

# True fallback: nohup
echo "[$(date '+%Y-%m-%d %H:%M:%S')] systemd unavailable — falling back to nohup" >> "$LOG"
cd "$PROJECT_ROOT"
nohup /usr/bin/node dist/index.js >> "$AGENT_LOG" 2>&1 &
echo "[$(date '+%Y-%m-%d %H:%M:%S')] started PID $!" >> "$LOG"
