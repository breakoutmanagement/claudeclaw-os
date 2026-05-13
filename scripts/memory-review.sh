#!/usr/bin/env bash
# Memory database review — lightweight, no Claude session needed.
# Checks for duplicates, conflicts, growth, and staleness.
# Usage: bash scripts/memory-review.sh [--notify]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$PROJECT_ROOT/.env"
DB="$PROJECT_ROOT/store/claudeclaw.db"

NOTIFY=false
for arg in "$@"; do
  [[ "$arg" == "--notify" ]] && NOTIFY=true
done

parse_env() {
  grep -E "^${1}=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'"
}
TELEGRAM_BOT_TOKEN=$(parse_env "TELEGRAM_BOT_TOKEN")
ALLOWED_CHAT_ID=$(parse_env "ALLOWED_CHAT_ID")

if [[ ! -f "$DB" ]]; then
  echo "ERROR: Database not found at $DB"
  exit 1
fi

# ── Stats ────────────────────────────────────────────────────────────────
TOTAL=$(sqlite3 "$DB" "SELECT COUNT(*) FROM memories;")
PINNED=$(sqlite3 "$DB" "SELECT COUNT(*) FROM memories WHERE pinned=1;" 2>/dev/null || echo "0")
UNPINNED=$(sqlite3 "$DB" "SELECT COUNT(*) FROM memories WHERE pinned=0 OR pinned IS NULL;" 2>/dev/null || echo "0")

# Memories added in last 7 days
RECENT=$(sqlite3 "$DB" "SELECT COUNT(*) FROM memories WHERE created_at > strftime('%s','now') - 604800;")

# Memories by agent
BY_AGENT=$(sqlite3 "$DB" "SELECT agent_id || ':' || COUNT(*) FROM memories GROUP BY agent_id ORDER BY COUNT(*) DESC;" 2>/dev/null | tr '\n' ' ')

# ── Potential duplicates (same summary substring) ─────────────────────────
DUPES=$(sqlite3 "$DB" "
  SELECT COUNT(*) FROM (
    SELECT substr(summary, 1, 80) as s, COUNT(*) as c
    FROM memories
    GROUP BY s
    HAVING c > 1
  );
")

# ── Stale memories (not accessed in 14+ days) ────────────────────────────
STALE=$(sqlite3 "$DB" "SELECT COUNT(*) FROM memories WHERE accessed_at < strftime('%s','now') - 1209600;" 2>/dev/null || echo "0")

# ── High importance low salience ─────────────────────────────────────────
BURIED=$(sqlite3 "$DB" "SELECT COUNT(*) FROM memories WHERE importance >= 0.8 AND salience <= 1.0;" 2>/dev/null || echo "0")

# ── Consolidation count ──────────────────────────────────────────────────
CONSOL=$(sqlite3 "$DB" "SELECT COUNT(*) FROM consolidation_insights;" 2>/dev/null || echo "0")

# ── Report ───────────────────────────────────────────────────────────────
NOW=$(date '+%Y-%m-%d %H:%M %Z')
REPORT="Memory Review — $NOW
Total: $TOTAL (pinned: $PINNED, unpinned: $UNPINNED)
Added last 7d: $RECENT | Consolidations: $CONSOL
By agent: $BY_AGENT
Potential dupes: $DUPES groups
Stale (14d+): $STALE | Buried (high-imp/low-sal): $BURIED"

echo "$REPORT"

# Flag issues
ISSUES=0
[[ "$DUPES" -gt 5 ]] && echo "WARNING: $DUPES duplicate groups found — run manual review" && ((ISSUES++)) || true
[[ "$STALE" -gt 20 ]] && echo "WARNING: $STALE stale memories — consider pruning" && ((ISSUES++)) || true
[[ "$BURIED" -gt 5 ]] && echo "WARNING: $BURIED high-importance low-salience memories — may need re-pinning" && ((ISSUES++)) || true
[[ "$UNPINNED" -gt 10 ]] && echo "WARNING: $UNPINNED unpinned memories — policy requires all pinned" && ((ISSUES++)) || true

# ── Telegram ─────────────────────────────────────────────────────────────
if $NOTIFY && [[ "$ISSUES" -gt 0 ]]; then
  [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$ALLOWED_CHAT_ID" ]] && exit 0
  MSG="🧠 <b>Memory Review</b> — $(date '+%H:%M %Z')
Total: $TOTAL | +${RECENT} this week
Dupes: $DUPES | Stale: $STALE | Buried: $BURIED
Issues: $ISSUES — needs manual review"
  curl -sf --max-time 10 -X POST \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${ALLOWED_CHAT_ID}" \
    -d "parse_mode=HTML" \
    --data-urlencode "text=$MSG" > /dev/null 2>&1 || true
fi

[[ "$ISSUES" -gt 0 ]] && exit 1
exit 0
