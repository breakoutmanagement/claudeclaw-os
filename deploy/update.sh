#!/usr/bin/env bash
#
# update.sh - Safe in-place update of a LIVE multi-agent claudeclaw-os host.
#
# This is NOT install-vps.sh. install-vps.sh provisions a single-bot greenfield
# box (one system-systemd unit, /opt/claudeclaw, rewrites .env, resets ufw).
# THIS script updates a host that already runs N agents under USER systemd,
# with a live SQLite store and per-agent state - without touching firewall,
# secrets, or the DB, and with a clean rename-swap rollback.
#
# Model it assumes (verified for ts-cc-os-vanilla 2026-07-07):
#   - run user owns everything under $LIVE_DIR (a fixed real path, not a symlink)
#   - agents run as USER systemd units: com.claudeclaw.agent-<name>.service
#   - unit WorkingDirectory + ExecStart reference $LIVE_DIR by ABSOLUTE path,
#     so a whole-dir rename-swap makes the units pick up new code on restart
#   - a cron watchdog restarts agent-main; it MUST be paused during the swap
#   - live state to preserve: store/ (DB), .env (secrets incl DB_ENCRYPTION_KEY),
#     agents/ (real per-agent config/state, NOT the vanilla template dirs)
#
# Usage (run AS THE RUN USER on the host, not root):
#   bash deploy/update.sh               # reads deploy/claudeclaw-deploy.conf if present
#
# Idempotent-ish: safe to re-run; each run stages a fresh dated clone and swaps.
# Every destructive step has an abort. On any abort the live dir is untouched
# (aborts fire BEFORE the swap) or restored (rollback after the swap).

set -euo pipefail

# --- config (overridable via deploy/claudeclaw-deploy.conf or env) -----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${CLAUDECLAW_DEPLOY_CONF:-$SCRIPT_DIR/claudeclaw-deploy.conf}"
[[ -f "$CONF" ]] && { set -a; # shellcheck disable=SC1090
  source "$CONF"; set +a; }

RUN_USER="${RUN_USER:-$(id -un)}"
LIVE_DIR="${LIVE_DIR:-$HOME/claudeclaw-os}"
REPO_URL="${REPO_URL:-https://github.com/breakoutmanagement/claudeclaw-os.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
REPO_CLONE_TOKEN="${REPO_CLONE_TOKEN:-}"            # optional short-lived token for a private fork
# space-separated agent short-names that run as com.claudeclaw.agent-<name>.service
AGENTS="${AGENTS:-main groit-sales grokeroobot rob tedd}"
# tess is restarted LAST and only when idle (live trading) - see TESS_* below
TESS_UNIT="${TESS_UNIT:-com.claudeclaw.agent-tess.service}"
TESS_TRADING_DIR="${TESS_TRADING_DIR:-$LIVE_DIR/agents/tess/trading}"
WATCHDOG_MARKER="${WATCHDOG_MARKER:-watchdog-main.sh}"  # crontab line to pause during swap
STATE_PATHS="${STATE_PATHS:-store .env agents}"     # carried from live into staged before swap

# --- pretty ------------------------------------------------------------------
if [[ -t 1 ]]; then B=$'\e[1m'; R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; Z=$'\e[0m'
else B=''; R=''; G=''; Y=''; C=''; Z=''; fi
step(){ echo; echo "${B}${C}==> $*${Z}"; }
ok(){ echo "  ${G}OK${Z} $*"; }
warn(){ echo "  ${Y}!!${Z} $*"; }
die(){ echo "  ${R}ABORT: $*${Z}" >&2; exit 1; }

STAMP="$(date -u +%Y%m%d-%H%M%S)"
STAGE_DIR="${LIVE_DIR}-${STAMP}"
BACKUP_DIR="${HOME}/claudeclaw-update-backups/${STAMP}"

# --- preflight (all aborts here fire BEFORE anything is touched) -------------
step "Preflight"
[[ "$(id -un)" == "$RUN_USER" ]] || die "Run as $RUN_USER (not $(id -un))."
[[ "$(id -u)" != "0" ]] || die "Do NOT run as root - agents run as $RUN_USER."
[[ -d "$LIVE_DIR/.git" || -d "$LIVE_DIR" ]] || die "LIVE_DIR $LIVE_DIR not found."
command -v systemctl >/dev/null || die "systemctl required."
systemctl --user is-active com.claudeclaw.agent-main.service >/dev/null 2>&1 \
  || die "agent-main not active under user systemd - wrong host model, use install-vps.sh."
LIVE_HEAD="$(git -C "$LIVE_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
ok "Live dir $LIVE_DIR @ ${LIVE_HEAD:0:12} (rollback point)"
ok "Will stage $STAGE_DIR, back up to $BACKUP_DIR"

# ABORT A-1: tess trade in flight -> do not proceed to a full swap that restarts tess.
# The swap itself is tess-safe (tess restarted last, separately, only if idle), but
# a running trade subprocess means we hold the WHOLE update to avoid a half-updated
# tess picking up new code mid-trade. Fork trigger: presence of a trading subprocess.
step "Tess trading-window check"
if pgrep -f "agents/tess/trading" >/dev/null 2>&1; then
  die "A tess trading subprocess is running. Hold the update until tess is idle (before 06:33 UTC weekday). [A-1]"
fi
ok "No tess trading subprocess in flight"

# --- 1. stage fresh clone ----------------------------------------------------
step "Staging fresh clone of $REPO_BRANCH"
if [[ -n "$REPO_CLONE_TOKEN" && "$REPO_URL" == https://github.com/* ]]; then
  CLONE_URL="https://x-access-token:${REPO_CLONE_TOKEN}@${REPO_URL#https://}"
else CLONE_URL="$REPO_URL"; fi
git clone --quiet --branch "$REPO_BRANCH" "$CLONE_URL" "$STAGE_DIR" \
  || die "Clone failed. For a private fork set REPO_CLONE_TOKEN in $CONF."
git -C "$STAGE_DIR" remote set-url origin "$REPO_URL"   # scrub any token from .git/config
STAGE_HEAD="$(git -C "$STAGE_DIR" rev-parse HEAD)"
ok "Staged $STAGE_DIR @ ${STAGE_HEAD:0:12}"
unset CLONE_URL

# --- 2. carry live state into staged (DB, secrets, agent state) --------------
# ABORT A-4: the staged .env's DB_ENCRYPTION_KEY must be byte-identical to live,
# or the 37MB SQLCipher DB becomes unreadable ciphertext. We COPY live .env in,
# then verify the key hash matches. Compare by hash - never print the secret.
step "Carrying live state into staged tree ($STATE_PATHS)"
for p in $STATE_PATHS; do
  if [[ -e "$LIVE_DIR/$p" ]]; then
    rm -rf "${STAGE_DIR:?}/$p"
    cp -a "$LIVE_DIR/$p" "$STAGE_DIR/$p"
    ok "carried $p"
  else warn "$p absent in live dir - skipped"; fi
done
LIVE_KEY_H="$(grep '^DB_ENCRYPTION_KEY=' "$LIVE_DIR/.env"  2>/dev/null | sha256sum | cut -c1-32 || true)"
STAGE_KEY_H="$(grep '^DB_ENCRYPTION_KEY=' "$STAGE_DIR/.env" 2>/dev/null | sha256sum | cut -c1-32 || true)"
[[ -n "$LIVE_KEY_H" ]] || die "No DB_ENCRYPTION_KEY in live .env - refuse to proceed. [A-4]"
[[ "$LIVE_KEY_H" == "$STAGE_KEY_H" ]] \
  || die "Staged DB_ENCRYPTION_KEY does not match live - DB would be unreadable. [A-4]"
ok "DB_ENCRYPTION_KEY preserved (hash match)"

# --- 3. backup live DB + .env off the swap path ------------------------------
step "Backing up live DB + secrets"
mkdir -p "$BACKUP_DIR"
if [[ -f "$LIVE_DIR/store/claudeclaw.db" ]]; then
  # sqlite-safe copy: .backup if sqlite3 present, else cp (agents may be mid-write;
  # cp of a WAL db is acceptable as a floor, .backup is preferred)
  if command -v sqlite3 >/dev/null 2>&1; then
    sqlite3 "$LIVE_DIR/store/claudeclaw.db" ".backup '$BACKUP_DIR/claudeclaw.db'" \
      || cp -a "$LIVE_DIR/store/claudeclaw.db" "$BACKUP_DIR/claudeclaw.db"
  else cp -a "$LIVE_DIR/store/claudeclaw.db" "$BACKUP_DIR/claudeclaw.db"; fi
  ok "DB backed up -> $BACKUP_DIR/claudeclaw.db ($(du -h "$BACKUP_DIR/claudeclaw.db" | cut -f1))"
else warn "no store/claudeclaw.db found"; fi
cp -a "$LIVE_DIR/.env" "$BACKUP_DIR/.env" 2>/dev/null && chmod 600 "$BACKUP_DIR/.env" && ok ".env backed up"

# --- 4. build the staged tree (native better-sqlite3 builds on host Node) -----
step "Building staged tree"
( cd "$STAGE_DIR" && npm ci >/dev/null 2>&1 ) || die "npm ci failed in staged tree."
( cd "$STAGE_DIR" && npm run build >/dev/null 2>&1 ) || die "build failed in staged tree."
ok "npm ci + build OK"

# --- 5. PRE-SWAP GATE: prove the staged tree loads the live DB ---------------
# The load-bearing gate. If better-sqlite3 can't open the CARRIED-OVER live DB
# on this host's Node, DO NOT swap. This catches ABI mismatch AND key mismatch.
step "Pre-swap gate (sqlite load of live DB on host Node)"
( cd "$STAGE_DIR" && node -e "
  const path=require('path');
  const db=require('better-sqlite3')(path.join(process.cwd(),'store','claudeclaw.db'));
  const n=db.prepare('select count(*) c from sqlite_master').get().c;
  console.log('  OK db opened, '+n+' schema objects, node '+process.version+' abi '+process.versions.modules);
" ) || die "Staged tree cannot open the live DB - ABI or key problem. NOT swapping. [A-4]"
( cd "$STAGE_DIR" && npm test >/dev/null 2>&1 ) && ok "vitest passed" || warn "vitest non-zero (review before trusting) - continuing per operator risk-accept"

# --- 6. pause the watchdog (prevents split-brain restart of OLD main) --------
# ABORT A-6: if we can't pause the watchdog, it will relaunch OLD main mid-swap
# -> two writers on one DB. Comment its crontab line; restore in the trap.
step "Pausing cron watchdog"
CRON_BAK="$BACKUP_DIR/crontab.bak"
crontab -l 2>/dev/null > "$CRON_BAK" || true
if grep -q "$WATCHDOG_MARKER" "$CRON_BAK" 2>/dev/null; then
  crontab -l 2>/dev/null | sed "s#^\(.*$WATCHDOG_MARKER.*\)#\# PAUSED-BY-UPDATE \1#" | crontab - \
    || die "Could not pause watchdog crontab. [A-6]"
  ok "watchdog paused (restore: $CRON_BAK)"
  WATCHDOG_PAUSED=1
else warn "watchdog marker '$WATCHDOG_MARKER' not in crontab - nothing to pause"; WATCHDOG_PAUSED=0; fi

restore_watchdog(){ [[ "${WATCHDOG_PAUSED:-0}" == "1" ]] && crontab "$CRON_BAK" 2>/dev/null && echo "  watchdog crontab restored"; }

# --- 7. stop agents, swap dirs, restart (tess handled separately) ------------
# Rename-swap: units reference $LIVE_DIR by absolute path, so swapping the dir
# contents at that path makes a restart pick up new code. Rollback = reverse rename.
OLD_DIR="${LIVE_DIR}.old-${STAMP}"
# Build the unit list once (word-split into args deliberately at the call sites).
UNIT_ARR=(); for a in $AGENTS; do UNIT_ARR+=("com.claudeclaw.agent-$a.service"); done
rollback(){
  warn "ROLLBACK: restoring previous live dir"
  systemctl --user stop "${UNIT_ARR[@]}" "$TESS_UNIT" 2>/dev/null || true
  if [[ -d "$OLD_DIR" && ! -d "$LIVE_DIR" ]]; then mv "$STAGE_DIR" "${STAGE_DIR}.failed-$STAMP" 2>/dev/null || true; mv "$OLD_DIR" "$LIVE_DIR"; fi
  systemctl --user start "${UNIT_ARR[@]}" 2>/dev/null || true
  restore_watchdog
  die "Rolled back to ${LIVE_HEAD:0:12}. Staged tree kept at ${STAGE_DIR}.failed-$STAMP for inspection."
}
trap 'rollback' ERR

step "Stopping agents (tess excluded - restarted last)"
systemctl --user stop "${UNIT_ARR[@]}"
systemctl --user stop "$TESS_UNIT" || true
ok "stopped: ${UNIT_ARR[*]} + tess"

step "Swapping $LIVE_DIR <- $STAGE_DIR"
mv "$LIVE_DIR" "$OLD_DIR"
mv "$STAGE_DIR" "$LIVE_DIR"
ok "swapped (previous kept at $OLD_DIR)"

step "Restarting agents (tess last)"
systemctl --user start "${UNIT_ARR[@]}"
sleep 3
for a in $AGENTS; do
  systemctl --user is-active --quiet "com.claudeclaw.agent-$a.service" \
    && ok "agent-$a active" || { warn "agent-$a NOT active"; false; }
done
# tess last, only if still idle
if pgrep -f "agents/tess/trading" >/dev/null 2>&1; then
  warn "tess trade started during swap - NOT restarting tess; start manually when idle: systemctl --user start $TESS_UNIT"
else
  systemctl --user start "$TESS_UNIT"; sleep 2
  systemctl --user is-active --quiet "$TESS_UNIT" && ok "tess active" || warn "tess NOT active - check journalctl --user -u $TESS_UNIT"
fi

# tutor via its @reboot cron mechanism (not a persistently-enabled unit)
if ! pgrep -f "index.js --agent tutor" >/dev/null 2>&1; then
  ( cd "$LIVE_DIR" && nohup /usr/bin/node dist/index.js --agent tutor >> store/agent-tutor.log 2>&1 & ) && ok "tutor relaunched" || warn "tutor relaunch failed"
else ok "tutor already running"; fi

trap - ERR
restore_watchdog

# --- 8. summary --------------------------------------------------------------
step "Update complete"
NEW_HEAD="$(git -C "$LIVE_DIR" rev-parse HEAD)"
cat <<EOF

  ${G}Updated ${LIVE_HEAD:0:12} -> ${NEW_HEAD:0:12}${Z}
  Live dir:   $LIVE_DIR
  Previous:   $OLD_DIR   (remove after smoke passes: rm -rf $OLD_DIR)
  DB backup:  $BACKUP_DIR/claudeclaw.db
  Next:       bash deploy/smoke-all.sh
EOF
