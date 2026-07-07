#!/usr/bin/env bash
#
# smoke-all.sh - Post-update smoke for a multi-agent claudeclaw-os host.
# Proves: all agents active, the DB is writable+readable on the new code, the
# dashboard answers on loopback, and the watchdog crontab is un-paused.
# Read-only except for one throwaway DB probe row (deleted immediately).
#
# Usage (as the run user, after deploy/update.sh):
#   bash deploy/smoke-all.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${CLAUDECLAW_DEPLOY_CONF:-$SCRIPT_DIR/claudeclaw-deploy.conf}"
# shellcheck disable=SC1090
[[ -f "$CONF" ]] && { set -a; source "$CONF"; set +a; }

LIVE_DIR="${LIVE_DIR:-$HOME/claudeclaw-os}"
AGENTS="${AGENTS:-main groit-sales grokeroobot rob tedd}"
TESS_UNIT="${TESS_UNIT:-com.claudeclaw.agent-tess.service}"
DASHBOARD_PORT="${DASHBOARD_PORT:-3141}"
WATCHDOG_MARKER="${WATCHDOG_MARKER:-watchdog-main.sh}"

if [[ -t 1 ]]; then G=$'\e[32m'; R=$'\e[31m'; Z=$'\e[0m'; else G=''; R=''; Z=''; fi
pass=0; fail=0
chk(){ if eval "$2" >/dev/null 2>&1; then echo "  ${G}PASS${Z} $1"; pass=$((pass+1)); else echo "  ${R}FAIL${Z} $1"; fail=$((fail+1)); fi; }

echo "== agent liveness =="
for a in $AGENTS; do chk "agent-$a active" "systemctl --user is-active --quiet com.claudeclaw.agent-$a.service"; done
chk "tess active" "systemctl --user is-active --quiet $TESS_UNIT"
chk "tutor process running" "pgrep -f 'index.js --agent tutor'"

echo "== DB read+write on the deployed code =="
chk "better-sqlite3 opens live DB" "cd '$LIVE_DIR' && node -e \"require('better-sqlite3')(require('path').join(process.cwd(),'store','claudeclaw.db')).prepare('select 1').get()\""
chk "DB is writable (throwaway table)" "cd '$LIVE_DIR' && node -e \"const d=require('better-sqlite3')(require('path').join(process.cwd(),'store','claudeclaw.db')); d.exec('create table if not exists _smoke_probe(x)'); d.prepare('insert into _smoke_probe values(1)').run(); d.exec('drop table _smoke_probe');\""

echo "== dashboard =="
chk "dashboard answers on loopback:$DASHBOARD_PORT" "curl -fsS -o /dev/null -m 5 http://127.0.0.1:$DASHBOARD_PORT/ || curl -fsS -o /dev/null -m 5 -w '%{http_code}' http://127.0.0.1:$DASHBOARD_PORT/healthz"

echo "== watchdog un-paused =="
chk "watchdog crontab line active (not PAUSED-BY-UPDATE)" "crontab -l 2>/dev/null | grep '$WATCHDOG_MARKER' | grep -qv 'PAUSED-BY-UPDATE'"

echo
if [[ $fail -eq 0 ]]; then echo "${G}SMOKE GREEN: $pass checks passed${Z}"; exit 0
else echo "${R}SMOKE RED: $fail failed, $pass passed${Z}"; exit 1; fi
