#!/usr/bin/env bash
# Memory prune — identifies duplicates, unpinned, and stale memories.
# DRY-RUN by default. Never deletes without --confirm flag.
# Usage: bash scripts/memory-prune.sh [--dry-run] [--confirm] [--notify]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$PROJECT_ROOT/.env"
DB="$PROJECT_ROOT/store/claudeclaw.db"

DRY_RUN=true
NOTIFY=false
for arg in "$@"; do
  case "$arg" in
    --confirm) DRY_RUN=false ;;
    --notify)  NOTIFY=true ;;
    --dry-run) DRY_RUN=true ;;
  esac
done

parse_env() {
  grep -E "^${1}=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'"
}

if [[ ! -f "$DB" ]]; then
  echo "ERROR: Database not found at $DB"
  exit 1
fi

echo "=== Memory Prune $(date '+%Y-%m-%d %H:%M %Z') ==="
[[ "$DRY_RUN" == "true" ]] && echo "MODE: dry-run (use --confirm to delete)"

# ── 1. Unpinned memories (policy: all should be pinned) ──────────────
UNPINNED=$(sqlite3 "$DB" "SELECT COUNT(*) FROM memories WHERE pinned=0 OR pinned IS NULL;")
echo ""
echo "Unpinned memories: $UNPINNED"
if [[ "$UNPINNED" -gt 0 ]]; then
  echo "  Top 5 unpinned:"
  sqlite3 "$DB" "SELECT id, substr(summary, 1, 80) FROM memories WHERE pinned=0 OR pinned IS NULL ORDER BY created_at DESC LIMIT 5;" | while IFS='|' read -r id summary; do
    echo "    [$id] $summary"
  done
  if [[ "$DRY_RUN" == "false" ]]; then
    sqlite3 "$DB" "UPDATE memories SET pinned=1 WHERE pinned=0 OR pinned IS NULL;"
    echo "  FIXED: Set all $UNPINNED to pinned=1"
  fi
fi

# ── 2. Orphaned superseded chains (superseded_by points to deleted row) ─
ORPHANED=$(sqlite3 "$DB" "SELECT COUNT(*) FROM memories WHERE superseded_by IS NOT NULL AND superseded_by NOT IN (SELECT id FROM memories);")
echo ""
echo "Orphaned supersession refs: $ORPHANED"
if [[ "$ORPHANED" -gt 0 && "$DRY_RUN" == "false" ]]; then
  sqlite3 "$DB" "UPDATE memories SET superseded_by=NULL WHERE superseded_by IS NOT NULL AND superseded_by NOT IN (SELECT id FROM memories);"
  echo "  FIXED: Cleared $ORPHANED orphaned refs"
fi

# ── 3. Duplicate clusters (same summary prefix) ─────────────────────
echo ""
echo "Potential duplicate clusters (same first 80 chars of summary):"
sqlite3 "$DB" "
  SELECT COUNT(*) as c, substr(summary, 1, 80) as s
  FROM memories
  WHERE superseded_by IS NULL
  GROUP BY s
  HAVING c > 1
  ORDER BY c DESC
  LIMIT 10;
" | while IFS='|' read -r count summary; do
  echo "  [$count dupes] $summary"
done

# ── 4. Stale memories (not accessed in 14+ days, not pinned) ─────────
STALE=$(sqlite3 "$DB" "SELECT COUNT(*) FROM memories WHERE accessed_at < strftime('%s','now') - 1209600 AND pinned=0;")
echo ""
echo "Stale (14d+, unpinned): $STALE"

# ── 5. Stats ─────────────────────────────────────────────────────────
TOTAL=$(sqlite3 "$DB" "SELECT COUNT(*) FROM memories;")
ACTIVE=$(sqlite3 "$DB" "SELECT COUNT(*) FROM memories WHERE superseded_by IS NULL;")
SUPERSEDED=$(sqlite3 "$DB" "SELECT COUNT(*) FROM memories WHERE superseded_by IS NOT NULL;")
PINNED=$(sqlite3 "$DB" "SELECT COUNT(*) FROM memories WHERE pinned=1;")
echo ""
echo "Total: $TOTAL | Active: $ACTIVE | Superseded: $SUPERSEDED | Pinned: $PINNED"

# ── Telegram ─────────────────────────────────────────────────────────
if $NOTIFY; then
  TELEGRAM_BOT_TOKEN=$(parse_env "TELEGRAM_BOT_TOKEN")
  ALLOWED_CHAT_ID=$(parse_env "ALLOWED_CHAT_ID")
  if [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$ALLOWED_CHAT_ID" ]]; then
    ISSUES=0
    [[ "$UNPINNED" -gt 0 ]] && ((ISSUES++)) || true
    [[ "$ORPHANED" -gt 0 ]] && ((ISSUES++)) || true
    if [[ "$ISSUES" -gt 0 ]]; then
      MSG="🧹 <b>Memory Prune</b> — $(date '+%H:%M %Z')
Total: $TOTAL | Active: $ACTIVE | Superseded: $SUPERSEDED
Unpinned: $UNPINNED | Orphaned refs: $ORPHANED
Mode: $(if $DRY_RUN; then echo 'dry-run'; else echo 'applied'; fi)"
      curl -sf --max-time 10 -X POST \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${ALLOWED_CHAT_ID}" \
        -d "parse_mode=HTML" \
        --data-urlencode "text=$MSG" > /dev/null 2>&1 || true
    fi
  fi
fi

echo ""
echo "Done."
