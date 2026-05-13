#!/usr/bin/env bash
# Gro IT V1 build status check — lightweight, no Claude session needed.
# Checks: PR state, endpoint health, deploy status.
# Usage: bash scripts/groit-build-check.sh [--notify] [--notify-on-change]
#   --notify           always send to Telegram
#   --notify-on-change only send when state differs from last run

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$PROJECT_ROOT/.env"
STATE_FILE="$PROJECT_ROOT/store/.groit-build-state"

# ── Args ─────────────────────────────────────────────────────────────────
NOTIFY=false
NOTIFY_ON_CHANGE=false
for arg in "$@"; do
  case "$arg" in
    --notify)           NOTIFY=true ;;
    --notify-on-change) NOTIFY_ON_CHANGE=true ;;
  esac
done

# ── Env ──────────────────────────────────────────────────────────────────
parse_env() {
  grep -E "^${1}=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'"
}
TELEGRAM_BOT_TOKEN=$(parse_env "TELEGRAM_BOT_TOKEN")
ALLOWED_CHAT_ID=$(parse_env "ALLOWED_CHAT_ID")

# ── Endpoints ────────────────────────────────────────────────────────────
check_url() {
  curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$1" 2>/dev/null || echo "000"
}

PROD_URL="https://cooksmart-groit.fly.dev"
STG_URL="https://cooksmart-staging.fly.dev"
PUB_URL="https://cooksmart.groit.global"

PROD_LIVEZ=$(check_url "$PROD_URL/livez")
PROD_ROOT=$(check_url "$PROD_URL/")
STG_LIVEZ=$(check_url "$STG_URL/livez")
PUB_LIVEZ=$(check_url "$PUB_URL/livez")

# ── GitHub PRs ───────────────────────────────────────────────────────────
OPEN_PRS=$(gh pr list --repo breakoutmanagement/groit --state open --json number,title --jq 'length' 2>/dev/null || echo "?")
MERGED_RECENT=$(gh pr list --repo breakoutmanagement/groit --state merged --limit 5 --json number,title,mergedAt --jq '.[0].title // "none"' 2>/dev/null || echo "?")

# ── GH Actions last run ─────────────────────────────────────────────────
LAST_RUN=$(gh run list --repo breakoutmanagement/groit --limit 1 --json conclusion,name,createdAt --jq '.[0] | "\(.conclusion // "running") (\(.name))"' 2>/dev/null || echo "?")

# ── Build state fingerprint ──────────────────────────────────────────────
STATE="prod=$PROD_LIVEZ stg=$STG_LIVEZ pub=$PUB_LIVEZ ci=$LAST_RUN prs=$OPEN_PRS"
PREV_STATE=""
[[ -f "$STATE_FILE" ]] && PREV_STATE=$(cat "$STATE_FILE")
CHANGED=false
[[ "$STATE" != "$PREV_STATE" ]] && CHANGED=true

echo "$STATE" > "$STATE_FILE"

# ── Report ───────────────────────────────────────────────────────────────
NOW=$(date '+%Y-%m-%d %H:%M %Z')
REPORT="Gro IT V1 — $NOW
prod livez:$PROD_LIVEZ root:$PROD_ROOT | stg livez:$STG_LIVEZ | pub:$PUB_LIVEZ
Open PRs: $OPEN_PRS | Last merge: $MERGED_RECENT
CI: $LAST_RUN
Changed: $CHANGED"

echo "$REPORT"

# ── Telegram ─────────────────────────────────────────────────────────────
send_notify() {
  [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$ALLOWED_CHAT_ID" ]] && return
  curl -sf --max-time 10 -X POST \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${ALLOWED_CHAT_ID}" \
    -d "parse_mode=HTML" \
    --data-urlencode "text=$1" > /dev/null 2>&1 || true
}

if $NOTIFY || ($NOTIFY_ON_CHANGE && $CHANGED); then
  ICON="📦"
  [[ "$PROD_LIVEZ" == "200" && "$STG_LIVEZ" == "200" ]] && ICON="✅"
  [[ "$PROD_LIVEZ" == "000" || "$STG_LIVEZ" == "000" ]] && ICON="🚨"

  MSG="${ICON} <b>Gro IT V1 Build</b> — $(date '+%H:%M %Z')
prod: ${PROD_LIVEZ} | stg: ${STG_LIVEZ} | pub: ${PUB_LIVEZ}
CI: ${LAST_RUN}
PRs open: ${OPEN_PRS}"
  send_notify "$MSG"
fi
