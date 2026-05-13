#!/usr/bin/env bash
# ClaudeClaw Health Check
# Checks all agents, Telegram channels, and infrastructure dependencies.
# Usage: bash scripts/healthcheck.sh [--quiet] [--notify]
#   --quiet    suppress colour output (for cron/log use)
#   --notify   send summary to Telegram regardless of status
#   --notify-on-fail  send to Telegram only when something is down

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$PROJECT_ROOT/.env"

# ── Args ────────────────────────────────────────────────────────────────────
QUIET=false
NOTIFY=false
NOTIFY_ON_FAIL=false
for arg in "$@"; do
  case "$arg" in
    --quiet)          QUIET=true ;;
    --notify)         NOTIFY=true ;;
    --notify-on-fail) NOTIFY_ON_FAIL=true ;;
  esac
done

# ── Colours ─────────────────────────────────────────────────────────────────
if $QUIET; then
  GRN="" YLW="" RED="" CYN="" BLD="" DIM="" RST=""
else
  GRN="\033[32m" YLW="\033[33m" RED="\033[31m" CYN="\033[36m"
  BLD="\033[1m"  DIM="\033[2m"  RST="\033[0m"
fi

PASS=0; WARN=0; FAIL=0
REPORT_LINES=()

ok()   { echo -e "  ${GRN}✓${RST}  $1"; REPORT_LINES+=("✅ $1"); ((PASS++)) || true; }
warn() { echo -e "  ${YLW}⚠${RST}  $1"; REPORT_LINES+=("⚠️ $1"); ((WARN++)) || true; }
fail() { echo -e "  ${RED}✗${RST}  $1"; REPORT_LINES+=("❌ $1"); ((FAIL++)) || true; }
hdr()  { echo -e "\n${BLD}${CYN}$1${RST}"; REPORT_LINES+=(""); REPORT_LINES+=("$1"); }

# ── Parse .env ───────────────────────────────────────────────────────────────
parse_env() {
  local key="$1"
  grep -E "^${key}=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'"
}

TELEGRAM_BOT_TOKEN=$(parse_env "TELEGRAM_BOT_TOKEN")
ALLOWED_CHAT_ID=$(parse_env "ALLOWED_CHAT_ID")
DASHBOARD_URL=$(parse_env "DASHBOARD_URL")
GOOGLE_API_KEY=$(parse_env "GOOGLE_API_KEY")
ANTHROPIC_API_KEY=$(parse_env "ANTHROPIC_API_KEY")

# ── Agent registry ───────────────────────────────────────────────────────────
# Only check agents that are actually running. Ghost agents disabled 2026-05-11.
# To re-enable: rename agents/<name>/agent.yaml.disabled → agent.yaml and add here.
AGENTS=(
  "main|TELEGRAM_BOT_TOKEN|standalone"
  "tutor|TUTOR_BOT_TOKEN|standalone"
  "rob|ROB_BOT_TOKEN|standalone"
  "product-owner|PRODUCT_OWNER_BOT_TOKEN|standalone"
  "architect|ARCHITECT_BOT_TOKEN|standalone"
  "breakout-po|BREAKOUT_PO_BOT_TOKEN|standalone"
)

# ── Helpers ──────────────────────────────────────────────────────────────────
check_telegram_token() {
  local name="$1" token="$2"
  if [[ -z "$token" ]]; then
    warn "[$name] token not set in .env"
    return
  fi
  # Delegation-only agents use placeholder tokens — not real bots
  if [[ "$token" == placeholder:* ]]; then
    ok "[$name] delegation mode (no standalone Telegram channel)"
    return
  fi
  local resp
  resp=$(curl -s --max-time 5 "https://api.telegram.org/bot${token}/getMe" 2>/dev/null || echo "")
  if echo "$resp" | grep -q '"ok":true'; then
    local botname
    botname=$(echo "$resp" | grep -o '"username":"[^"]*"' | cut -d'"' -f4)
    ok "[$name] Telegram bot OK (@${botname})"
  else
    fail "[$name] Telegram bot unreachable or token invalid"
  fi
}

check_process() {
  local name="$1"
  local pids manager="process"

  # Check user systemd first (primary manager for main bot)
  export XDG_RUNTIME_DIR="/run/user/$(id -u)"
  export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
  local svc="com.claudeclaw.agent-${name}"
  if systemctl --user is-active "$svc" &>/dev/null; then
    local pid mem_kb mem_mb uptime
    pid=$(systemctl --user show "$svc" --property=MainPID --value 2>/dev/null || echo "?")
    mem_kb=$(ps -o rss= -p "$pid" 2>/dev/null || echo "0")
    mem_mb=$(( mem_kb / 1024 ))
    uptime=$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ' || echo "?")
    ok "[$name] user systemd active (PID $pid, ~${mem_mb}MB, up $uptime)"
    return
  fi

  # Fall back to process check (nohup / system systemd)
  if [[ "$name" == "main" ]]; then
    pids=$(pgrep -f "node.*dist/index.js$" 2>/dev/null || true)
  else
    pids=$(pgrep -f "node.*dist/index.js.*--agent ${name}" 2>/dev/null || true)
  fi

  if [[ -n "$pids" ]]; then
    local pid_list mem_kb mem_mb uptime
    pid_list=$(echo "$pids" | tr '\n' ',' | sed 's/,$//')
    mem_kb=$(ps -o rss= -p "$(echo "$pids" | head -1)" 2>/dev/null || echo "0")
    mem_mb=$(( mem_kb / 1024 ))
    uptime=$(ps -o etime= -p "$(echo "$pids" | head -1)" 2>/dev/null | tr -d ' ' || echo "?")
    warn "[$name] running via nohup/system-systemd (PID $pid_list, ~${mem_mb}MB) — user systemd inactive"
  else
    fail "[$name] NOT running. Restart: bash $PROJECT_ROOT/scripts/restart.sh $name"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
echo -e "${BLD}ClaudeClaw Health Check${RST} — $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo -e "${DIM}$PROJECT_ROOT${RST}"

# ── 1. System resources ──────────────────────────────────────────────────────
hdr "System Resources"
DISK_PCT=$(df "$PROJECT_ROOT" | awk 'NR==2{gsub(/%/,"",$5); print $5}')
if   (( DISK_PCT >= 90 )); then fail  "Disk: ${DISK_PCT}% used"
elif (( DISK_PCT >= 75 )); then warn  "Disk: ${DISK_PCT}% used"
else                             ok    "Disk: ${DISK_PCT}% used"
fi

MEM_FREE=$(free -m 2>/dev/null | awk '/^Mem:/{print int($7)}' || echo "0")
MEM_TOTAL=$(free -m 2>/dev/null | awk '/^Mem:/{print int($2)}' || echo "1")
MEM_PCT=$(( (MEM_TOTAL - MEM_FREE) * 100 / MEM_TOTAL ))
if   (( MEM_PCT >= 90 )); then fail "RAM: ${MEM_PCT}% used (${MEM_FREE}MB free)"
elif (( MEM_PCT >= 75 )); then warn "RAM: ${MEM_PCT}% used (${MEM_FREE}MB free)"
else                           ok   "RAM: ${MEM_PCT}% used (${MEM_FREE}MB free)"
fi

# ── 2. Network / Tailscale ───────────────────────────────────────────────────
hdr "Network"
if command -v tailscale &>/dev/null; then
  TS_JSON=$(tailscale status --json 2>/dev/null || echo "{}")
  TS_BACKEND=$(echo "$TS_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('BackendState','?'))" 2>/dev/null || echo "?")
  if [[ "$TS_BACKEND" == "Running" ]]; then
    TS_IP=$(tailscale ip -4 2>/dev/null || echo "?")
    ok "Tailscale running — IP: $TS_IP"
  else
    fail "Tailscale: state=$TS_BACKEND"
  fi
else
  warn "Tailscale: not installed"
fi

if curl -sf --max-time 5 "https://api.telegram.org" &>/dev/null; then
  ok "Telegram API reachable"
else
  fail "Telegram API unreachable — check network/DNS"
fi

# ── 3. SQLite database ───────────────────────────────────────────────────────
hdr "Database"
DB_PATH="$PROJECT_ROOT/store/claudeclaw.db"
if [[ -f "$DB_PATH" ]]; then
  DB_SIZE=$(du -sh "$DB_PATH" 2>/dev/null | cut -f1)
  TABLE_COUNT=$(sqlite3 "$DB_PATH" "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo "0")
  SESSION_COUNT=$(sqlite3 "$DB_PATH" "SELECT count(*) FROM sessions;" 2>/dev/null || echo "?")
  MEM_COUNT=$(sqlite3 "$DB_PATH" "SELECT count(*) FROM memories;" 2>/dev/null || echo "?")
  if [[ "$TABLE_COUNT" -gt 0 ]]; then
    ok "SQLite: $DB_SIZE — $TABLE_COUNT tables, $SESSION_COUNT sessions, $MEM_COUNT memories"
  else
    fail "SQLite: file exists but zero tables — may be corrupted"
  fi
else
  fail "SQLite: store/claudeclaw.db not found"
fi

# ── 4. Dashboard ─────────────────────────────────────────────────────────────
hdr "Dashboard"
if [[ -n "$DASHBOARD_URL" ]]; then
  HTTP_CODE=$(curl --max-time 5 -o /dev/null -w "%{http_code}" "$DASHBOARD_URL" 2>/dev/null || true)
  HTTP_CODE="${HTTP_CODE:-000}"
  if [[ "$HTTP_CODE" == "200" ]] || [[ "$HTTP_CODE" == "401" ]]; then
    ok "Dashboard responding — $DASHBOARD_URL (HTTP $HTTP_CODE)"
  elif [[ "$HTTP_CODE" == "000" ]]; then
    fail "Dashboard unreachable — $DASHBOARD_URL (check if main bot is running)"
  else
    warn "Dashboard returned HTTP $HTTP_CODE — $DASHBOARD_URL"
  fi
else
  warn "DASHBOARD_URL not set in .env"
fi

# ── 5. External APIs ─────────────────────────────────────────────────────────
hdr "External APIs"

# Claude / Anthropic
if [[ -n "$ANTHROPIC_API_KEY" ]]; then
  CLAUDE_STATUS=$(curl --max-time 8 \
    -H "x-api-key: $ANTHROPIC_API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -o /dev/null -w "%{http_code}" \
    "https://api.anthropic.com/v1/models" 2>/dev/null || true)
  CLAUDE_STATUS="${CLAUDE_STATUS:-000}"
  if [[ "$CLAUDE_STATUS" == "200" ]]; then
    ok "Anthropic API: reachable"
  elif [[ "$CLAUDE_STATUS" == "401" ]]; then
    fail "Anthropic API: invalid API key (HTTP 401)"
  else
    warn "Anthropic API: HTTP $CLAUDE_STATUS"
  fi
else
  # Check claude CLI auth as fallback
  if claude --version &>/dev/null 2>&1; then
    ok "Claude CLI: installed (using oauth, no ANTHROPIC_API_KEY)"
  else
    warn "Anthropic: no API key and claude CLI not found"
  fi
fi

# Gemini
if [[ -n "$GOOGLE_API_KEY" ]]; then
  GEMINI_STATUS=$(curl --max-time 8 \
    -o /dev/null -w "%{http_code}" \
    "https://generativelanguage.googleapis.com/v1beta/models?key=${GOOGLE_API_KEY}" 2>/dev/null || true)
  GEMINI_STATUS="${GEMINI_STATUS:-000}"
  if [[ "$GEMINI_STATUS" == "200" ]]; then
    # Check if deprecated model is still hardcoded
    if grep -q '"gemini-2.0-flash"' "$PROJECT_ROOT/src/gemini.ts" 2>/dev/null || \
       grep -q "gemini-2.0-flash'" "$PROJECT_ROOT/src/gemini.ts" 2>/dev/null; then
      warn "Gemini API: reachable BUT src/gemini.ts default model is gemini-2.0-flash (deprecated — returns 404 for new users)"
    else
      ok "Gemini API: reachable"
    fi
  elif [[ "$GEMINI_STATUS" == "400" ]] || [[ "$GEMINI_STATUS" == "403" ]]; then
    fail "Gemini API: auth error (HTTP $GEMINI_STATUS) — check GOOGLE_API_KEY"
  else
    warn "Gemini API: HTTP $GEMINI_STATUS"
  fi
else
  warn "GOOGLE_API_KEY not set — memory extraction disabled"
fi

# ── 6. Agent services + Telegram channels ────────────────────────────────────
hdr "Agents"
for entry in "${AGENTS[@]}"; do
  IFS='|' read -r agent_id token_env mode <<< "$entry"
  token=$(parse_env "$token_env")

  if [[ "$mode" == "standalone" ]]; then
    check_process "$agent_id"
  fi
  check_telegram_token "$agent_id" "$token"
done

# ── 7. Build artefact check ───────────────────────────────────────────────────
hdr "Build"
DIST_INDEX="$PROJECT_ROOT/dist/index.js"
if [[ -f "$DIST_INDEX" ]]; then
  SRC_TS=$(find "$PROJECT_ROOT/src" -name "*.ts" -newer "$DIST_INDEX" 2>/dev/null | head -1)
  if [[ -n "$SRC_TS" ]]; then
    warn "dist/ may be stale — src files newer than dist/index.js (run: npm run build)"
  else
    ok "dist/index.js present and up to date"
  fi
else
  fail "dist/index.js not found — run: npm run build"
fi

# ── 8. Scheduled / Mission tasks ─────────────────────────────────────────────
hdr "Task Queues"
if [[ -f "$DB_PATH" ]]; then
  SCHED_ACTIVE=$(sqlite3 "$DB_PATH" \
    "SELECT count(*) FROM scheduled_tasks WHERE status='active';" 2>/dev/null || echo "0")
  MISSION_PENDING=$(sqlite3 "$DB_PATH" \
    "SELECT count(*) FROM mission_tasks WHERE status IN ('queued','running');" 2>/dev/null || echo "0")
  MISSION_FAILED=$(sqlite3 "$DB_PATH" \
    "SELECT count(*) FROM mission_tasks WHERE status='failed';" 2>/dev/null || echo "0")
  ok "Scheduled tasks active: $SCHED_ACTIVE"
  ok "Mission tasks pending/running: $MISSION_PENDING"
  if [[ "$MISSION_FAILED" -gt 0 ]]; then
    warn "Mission tasks failed: $MISSION_FAILED (check dashboard)"
  else
    ok "Mission tasks failed: 0"
  fi
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLD}Summary:${RST} ${GRN}${PASS} ok${RST}  ${YLW}${WARN} warn${RST}  ${RED}${FAIL} fail${RST}"

OVERALL_STATUS="ok"
if (( FAIL > 0 )); then OVERALL_STATUS="fail"
elif (( WARN > 0 )); then OVERALL_STATUS="warn"
fi

# ── Telegram notification ─────────────────────────────────────────────────────
send_notify() {
  local msg="$1"
  if [[ -z "$TELEGRAM_BOT_TOKEN" ]] || [[ -z "$ALLOWED_CHAT_ID" ]]; then return; fi
  curl -sf --max-time 10 -X POST \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${ALLOWED_CHAT_ID}" \
    -d "parse_mode=HTML" \
    --data-urlencode "text=${msg}" > /dev/null 2>&1 || true
}

if $NOTIFY || ($NOTIFY_ON_FAIL && [[ "$OVERALL_STATUS" == "fail" ]]); then
  ICON="✅"
  if [[ "$OVERALL_STATUS" == "fail" ]]; then ICON="🚨"
  elif [[ "$OVERALL_STATUS" == "warn" ]]; then ICON="⚠️"
  fi
  MSG="${ICON} <b>ClaudeClaw Health</b> — $(date '+%H:%M %Z')
${PASS} ok · ${WARN} warn · ${FAIL} fail

$(printf '%s\n' "${REPORT_LINES[@]}" | grep -E "^[✅⚠️❌]" | head -20)"
  send_notify "$MSG"
fi

# Exit non-zero on any failures
if (( FAIL > 0 )); then exit 2; fi
if (( WARN > 0 )); then exit 1; fi
exit 0
