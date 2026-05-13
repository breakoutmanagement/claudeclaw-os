#!/usr/bin/env bash
# Memory drift check.
# Catches the failure mode where pinned memories continue surfacing banned/superseded
# facts after a directive overrides them. Scans pinned memories for known banned strings.
#
# Exit codes: 0 green, 1 drift detected.
# Usage: bash scripts/memory-drift-check.sh [--notify-on-change]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DB="$PROJECT_ROOT/store/claudeclaw.db"
STATE_FILE="$PROJECT_ROOT/store/.memory-drift-state"

NOTIFY_ON_CHANGE=false
for arg in "$@"; do [[ "$arg" == "--notify-on-change" ]] && NOTIFY_ON_CHANGE=true; done

# Banned facts that, if present in any high-salience pinned memory without STALE tag, are drift.
BANNED_FACTS=(
  "groit-cooksmart-booth"
  "cooksmart.groit.fly.dev"
  "trade-shows-whitelabel"
  "trade-shows-groit"
)

red=0
findings=""

# Exempt policy/directive memories that DOCUMENT the rule (the banned string appears
# alongside words like "banned", "legacy", "do not", "deprecated"). Those are the
# rule itself, not stale facts.
for fact in "${BANNED_FACTS[@]}"; do
  hits=$(sqlite3 "$DB" "SELECT COUNT(*) FROM memories
    WHERE pinned=1
      AND salience >= 0.5
      AND (summary LIKE '%${fact}%' OR raw_text LIKE '%${fact}%')
      AND (topics IS NULL OR topics NOT LIKE '%STALE-%')
      AND (topics IS NULL OR topics NOT LIKE '%directive%')
      AND (topics IS NULL OR topics NOT LIKE '%policy%')
      AND raw_text NOT LIKE '%banned%'
      AND raw_text NOT LIKE '%legacy%'
      AND raw_text NOT LIKE '%do not use%'
      AND raw_text NOT LIKE '%deprecated%';" 2>/dev/null || echo 0)
  if [[ "${hits:-0}" != "0" ]]; then
    findings+="$hits pinned high-salience non-policy memory(ies) still reference banned: $fact\n"
    red=1
  fi
done

state_hash=$(echo -e "$findings" | sha256sum | cut -c1-12)
prev=""
[[ -f "$STATE_FILE" ]] && prev=$(cat "$STATE_FILE")
echo "$state_hash" > "$STATE_FILE"

if [[ $red -eq 0 ]]; then
  echo "OK no memory drift"
else
  echo "DRIFT:"
  echo -e "$findings"
fi

if $NOTIFY_ON_CHANGE && [[ "$state_hash" != "$prev" ]]; then
  bash "$SCRIPT_DIR/notify.sh" "$([[ $red -eq 0 ]] && echo '✅' || echo '🧠') memory-drift: $([[ $red -eq 0 ]] && echo 'green' || echo 'drift')
$(echo -e "$findings" | head -5)" 2>/dev/null || true
fi

exit $red
