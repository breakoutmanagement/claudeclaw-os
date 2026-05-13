#!/usr/bin/env bash
# Agent heartbeat check.
# Catches the failure mode from 2026-05-11: main agent deployed Fly apps without writing
# to hive_mind, leaving PO blind to what it was doing.
# Every active agent must log at least one hive_mind entry per 24h.
#
# Exit codes: 0 green, 1 silent agent detected.
# Usage: bash scripts/agent-heartbeat-check.sh [--notify-on-change]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DB="$PROJECT_ROOT/store/claudeclaw.db"
STATE_FILE="$PROJECT_ROOT/store/.agent-heartbeat-state"

NOTIFY_ON_CHANGE=false
for arg in "$@"; do [[ "$arg" == "--notify-on-change" ]] && NOTIFY_ON_CHANGE=true; done

# Agents expected to be active. Exclude paused/dormant agents.
ACTIVE_AGENTS="main product-owner architect rob"
WINDOW_SECONDS=$((24 * 3600))
NOW=$(date +%s)
CUTOFF=$((NOW - WINDOW_SECONDS))

red=0
findings=""

for agent in $ACTIVE_AGENTS; do
  last=$(sqlite3 "$DB" "SELECT COALESCE(MAX(created_at), 0) FROM hive_mind WHERE agent_id = '$agent';" 2>/dev/null || echo 0)
  if [[ "$last" -lt "$CUTOFF" ]]; then
    age_h=$(( (NOW - last) / 3600 ))
    if [[ "$last" == "0" ]]; then
      findings+="agent '$agent' has NEVER written to hive_mind\n"
    else
      findings+="agent '$agent' silent ${age_h}h (last: $(date -d @$last '+%Y-%m-%d %H:%M' 2>/dev/null || echo unknown))\n"
    fi
    red=1
  fi
done

state_hash=$(echo -e "$findings" | sha256sum | cut -c1-12)
prev=""
[[ -f "$STATE_FILE" ]] && prev=$(cat "$STATE_FILE")
echo "$state_hash" > "$STATE_FILE"

if [[ $red -eq 0 ]]; then
  echo "OK all active agents heard from in last 24h"
else
  echo "SILENT AGENTS:"
  echo -e "$findings"
fi

if $NOTIFY_ON_CHANGE && [[ "$state_hash" != "$prev" ]]; then
  bash "$SCRIPT_DIR/notify.sh" "$([[ $red -eq 0 ]] && echo '✅' || echo '🔇') heartbeat: $([[ $red -eq 0 ]] && echo 'all live' || echo 'silent agent')
$(echo -e "$findings" | head -5)" 2>/dev/null || true
fi

exit $red
