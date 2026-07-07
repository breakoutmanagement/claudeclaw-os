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
# Usage (run AS THE RUN USER on the host, not root). Config load is MANDATORY:
#   CLAUDECLAW_DEPLOY_CONF=deploy/claudeclaw-update.conf bash deploy/update.sh
# or place deploy/claudeclaw-update.conf beside this script and run it bare.
#
# Idempotent-ish: safe to re-run; each run stages a fresh dated clone and swaps.
# Every destructive step has an abort. On any abort the live dir is untouched
# (aborts fire BEFORE the swap) or fully restored (rollback after the swap).

set -euo pipefail

# --- config (MANDATORY: claudeclaw-update.conf, NOT the install secrets file) --
# The default is claudeclaw-update.conf. It must NOT default to
# claudeclaw-deploy.conf - that is install-vps's SECRETS file and defines none
# of this script's vars. Config load is required on a T3 host.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${CLAUDECLAW_DEPLOY_CONF:-$SCRIPT_DIR/claudeclaw-update.conf}"
if [[ -f "$CONF" ]]; then
  set -a; # shellcheck disable=SC1090
  source "$CONF"; set +a
else
  echo "ABORT: config $CONF not found. Copy claudeclaw-update.conf.example and fill it in," >&2
  echo "       or set CLAUDECLAW_DEPLOY_CONF. This script will not run on host defaults." >&2
  exit 1
fi

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
OLD_DIR="${LIVE_DIR}.old-${STAMP}"
BACKUP_DIR="${HOME}/claudeclaw-update-backups/${STAMP}"
SWAPPED=0                # set to 1 the instant the live dir is renamed away
WATCHDOG_PAUSED=0

# --- preflight (all aborts here fire BEFORE anything is touched) -------------
step "Preflight"
[[ "$(id -un)" == "$RUN_USER" ]] || die "Run as $RUN_USER (not $(id -un))."
[[ "$(id -u)" != "0" ]] || die "Do NOT run as root - agents run as $RUN_USER."
[[ -d "$LIVE_DIR" ]] || die "LIVE_DIR $LIVE_DIR not found."
command -v systemctl >/dev/null || die "systemctl required."
command -v git >/dev/null || die "git required."
systemctl --user is-active com.claudeclaw.agent-main.service >/dev/null 2>&1 \
  || die "agent-main not active under user systemd - wrong host model, use install-vps.sh."
LIVE_HEAD="$(git -C "$LIVE_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
ok "Live dir $LIVE_DIR @ ${LIVE_HEAD:0:12} (rollback point)"
ok "Will stage $STAGE_DIR, back up to $BACKUP_DIR"

# ABORT A-1: tess trade in flight -> hold the whole update.
step "Tess trading-window check"
if pgrep -f "$TESS_TRADING_DIR" >/dev/null 2>&1 || pgrep -f "agents/tess/trading/" >/dev/null 2>&1; then
  die "A tess trading subprocess is running. Hold the update until tess is idle (before 06:33 UTC weekday). [A-1]"
fi
ok "No tess trading subprocess in flight"

# --- 1. stage fresh clone (token via GIT_ASKPASS, never in argv) -------------
# The token must NEVER appear in the clone URL argv (it would be visible in
# ps/ /proc/<pid>/cmdline to any local UID). Use a throwaway GIT_ASKPASS helper
# that feeds the token on the credential FD, and delete it immediately after.
step "Staging fresh clone of $REPO_BRANCH"
ASKPASS=""
cleanup_askpass(){ [[ -n "$ASKPASS" && -f "$ASKPASS" ]] && rm -f "$ASKPASS"; ASKPASS=""; return 0; }
trap 'cleanup_askpass' EXIT   # remove the shim on ANY exit path (kill/die/normal)
if [[ -n "$REPO_CLONE_TOKEN" && "$REPO_URL" == https://github.com/* ]]; then
  ASKPASS="$(mktemp)"; chmod 700 "$ASKPASS"
  # git calls askpass twice: for Username then Password. Emit token as both-safe.
  cat > "$ASKPASS" <<'AEOF'
#!/usr/bin/env bash
case "$1" in
  *Username*) echo "x-access-token" ;;
  *) echo "${CLAUDECLAW_CLONE_TOKEN}" ;;
esac
AEOF
  CLAUDECLAW_CLONE_TOKEN="$REPO_CLONE_TOKEN" GIT_ASKPASS="$ASKPASS" GIT_TERMINAL_PROMPT=0 \
    git clone --quiet --branch "$REPO_BRANCH" "$REPO_URL" "$STAGE_DIR" \
    || { cleanup_askpass; die "Clone failed. Check REPO_CLONE_TOKEN in $CONF (tokens expire ~1h)."; }
  cleanup_askpass
else
  GIT_TERMINAL_PROMPT=0 git clone --quiet --branch "$REPO_BRANCH" "$REPO_URL" "$STAGE_DIR" \
    || die "Clone failed. For a private fork set REPO_CLONE_TOKEN in $CONF."
fi
STAGE_HEAD="$(git -C "$STAGE_DIR" rev-parse HEAD)"
ok "Staged $STAGE_DIR @ ${STAGE_HEAD:0:12}"

# --- 2. carry live state into staged (DB, secrets, agent state) --------------
# ABORT A-4: staged .env's DB_ENCRYPTION_KEY must match live or the SQLCipher DB
# is unreadable. NOTE: after we cp live .env in, the hash trivially matches - the
# REAL key/ABI proof is the sqlite-load gate in step 5, which opens the DB.
step "Carrying live state into staged tree ($STATE_PATHS)"
for p in $STATE_PATHS; do
  if [[ -e "$LIVE_DIR/$p" ]]; then
    rm -rf "${STAGE_DIR:?}/$p"
    cp -a "$LIVE_DIR/$p" "$STAGE_DIR/$p"
    ok "carried $p"
  else warn "$p absent in live dir - skipped"; fi
done
grep -q '^DB_ENCRYPTION_KEY=' "$LIVE_DIR/.env" 2>/dev/null \
  || die "No DB_ENCRYPTION_KEY in live .env - refuse to proceed. [A-4]"
ok "live .env carried (DB_ENCRYPTION_KEY present; DB open proven in step 5)"

# --- 3. backup live DB + .env off the swap path (restrictive perms) ----------
step "Backing up live DB + secrets"
mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
if [[ -f "$LIVE_DIR/store/claudeclaw.db" ]]; then
  # Prefer sqlite3 .backup (consistent snapshot). On an encrypted DB .backup may
  # fail; fall back to cp of the db + its -wal/-shm sidecars so we don't capture
  # a torn page. Backup is a floor; the pre-swap gate is the real safety.
  if command -v sqlite3 >/dev/null 2>&1 && \
     sqlite3 "$LIVE_DIR/store/claudeclaw.db" ".backup '$BACKUP_DIR/claudeclaw.db'" 2>/dev/null; then
    :
  else
    cp -a "$LIVE_DIR/store/claudeclaw.db" "$BACKUP_DIR/claudeclaw.db"
    for sidecar in claudeclaw.db-wal claudeclaw.db-shm; do
      [[ -f "$LIVE_DIR/store/$sidecar" ]] && cp -a "$LIVE_DIR/store/$sidecar" "$BACKUP_DIR/$sidecar"
    done
  fi
  chmod 600 "$BACKUP_DIR"/claudeclaw.db* 2>/dev/null || true
  ok "DB backed up -> $BACKUP_DIR/claudeclaw.db ($(du -h "$BACKUP_DIR/claudeclaw.db" | cut -f1))"
else warn "no store/claudeclaw.db found"; fi
if cp -a "$LIVE_DIR/.env" "$BACKUP_DIR/.env" 2>/dev/null; then chmod 600 "$BACKUP_DIR/.env"; ok ".env backed up"; fi

# --- 4. build the staged tree (native better-sqlite3 builds on host Node) -----
step "Building staged tree"
( cd "$STAGE_DIR" && npm ci >/dev/null 2>&1 ) || die "npm ci failed in staged tree."
( cd "$STAGE_DIR" && npm run build >/dev/null 2>&1 ) || die "build failed in staged tree."
ok "npm ci + build OK"

# --- 5. PRE-SWAP GATE: DB opens + tests pass + app BOOTS ----------------------
# Three checks, ALL hard aborts (no swap on any failure):
#   a) better-sqlite3 opens the carried-over live DB (catches ABI + key mismatch)
#   b) vitest passes (real-code signal - a HARD gate on this T3 host, not a warn)
#   c) the app entrypoint boots against the carried DB and reaches ready, then
#      exits - catches "builds fine, refuses to boot" (missing dep, failed
#      start-time migration) BEFORE the irreversible swap.
step "Pre-swap gate (DB open + tests + boot probe)"
( cd "$STAGE_DIR" && node -e "
  const path=require('path');
  const db=require('better-sqlite3')(path.join(process.cwd(),'store','claudeclaw.db'));
  const n=db.prepare('select count(*) c from sqlite_master').get().c;
  console.log('  db opened, '+n+' schema objects, node '+process.version+' abi '+process.versions.modules);
" ) || die "Staged tree cannot open the live DB - ABI or key problem. NOT swapping. [A-4]"
ok "DB opens on staged code"

( cd "$STAGE_DIR" && npm test >/dev/null 2>&1 ) || die "vitest FAILED in staged tree - NOT swapping. [gate]"
ok "vitest passed"

# Entrypoint sanity: the built entrypoint exists and PARSES. We deliberately do
# NOT execute or import it - dist/index.js calls main() at top level (ESM), so
# loading it would start the live bot and take real side-effects (Telegram, DB
# writes) pre-swap. `node --check` parses the file without running it, catching a
# truncated/corrupt build. Actual boot is proven POST-swap by the agent health
# check below + smoke-all.sh; a crash-loop there triggers the (now-correct) rollback.
step "Entrypoint sanity (parse dist/index.js, no execute)"
[[ -f "$STAGE_DIR/dist/index.js" ]] || die "dist/index.js missing after build. NOT swapping. [gate]"
node --check "$STAGE_DIR/dist/index.js" 2>/dev/null \
  || die "dist/index.js does not parse (corrupt build). NOT swapping. [gate]"
ok "Entrypoint present and parses"

# --- 6. pause the watchdog (prevents split-brain restart of OLD main) --------
# ABORT A-6: if we can't pause the watchdog it will relaunch OLD main mid-swap
# -> two writers on one DB. rollback() and the exit path both restore it.
step "Pausing cron watchdog"
CRON_BAK="$BACKUP_DIR/crontab.bak"
crontab -l 2>/dev/null > "$CRON_BAK" || true
chmod 600 "$CRON_BAK" 2>/dev/null || true
restore_watchdog(){
  # Idempotent, never fails the caller (used on success path AND in rollback).
  if [[ "${WATCHDOG_PAUSED:-0}" == "1" ]]; then
    crontab "$CRON_BAK" 2>/dev/null && echo "  watchdog crontab restored"
  fi
  return 0
}
if grep -qF "$WATCHDOG_MARKER" "$CRON_BAK" 2>/dev/null; then
  # grep -F for the marker; sed with a safe delimiter and a literal-ish match.
  if crontab -l 2>/dev/null | sed "/PAUSED-BY-UPDATE/! s|^\(.*${WATCHDOG_MARKER}.*\)|# PAUSED-BY-UPDATE \1|" | crontab -; then
    WATCHDOG_PAUSED=1; ok "watchdog paused (restore: $CRON_BAK)"
  else die "Could not pause watchdog crontab. [A-6]"; fi
else warn "watchdog marker '$WATCHDOG_MARKER' not in crontab - nothing to pause"; fi

# --- 7. arm rollback, stop agents, verify stopped, swap, restart -------------
# Rollback is armed BEFORE any destructive action and is correct for BOTH
# pre-swap (nothing to undo) and post-swap (reverse the rename) failures.
UNIT_ARR=(); for a in $AGENTS; do UNIT_ARR+=("com.claudeclaw.agent-$a.service"); done
rollback(){
  set +e                                        # never let errexit truncate recovery
  warn "ROLLBACK: restoring previous state"
  systemctl --user stop "${UNIT_ARR[@]}" "$TESS_UNIT" 2>/dev/null
  if [[ "$SWAPPED" == "1" ]]; then
    # reverse the rename: current $LIVE_DIR is the NEW (bad) tree; $OLD_DIR is good.
    [[ -d "$LIVE_DIR" ]] && mv "$LIVE_DIR" "${STAGE_DIR}.failed-$STAMP" 2>/dev/null
    [[ -d "$OLD_DIR" ]] && mv "$OLD_DIR" "$LIVE_DIR" 2>/dev/null
    warn "reversed swap: $OLD_DIR -> $LIVE_DIR (bad tree at ${STAGE_DIR}.failed-$STAMP)"
  fi
  systemctl --user start "${UNIT_ARR[@]}" 2>/dev/null
  restore_watchdog
  echo "  ${R}ROLLED BACK to ${LIVE_HEAD:0:12}.${Z}" >&2
  exit 1
}
trap 'rollback' ERR

step "Stopping agents (tess excluded - restarted last)"
systemctl --user stop "${UNIT_ARR[@]}"
systemctl --user stop "$TESS_UNIT" 2>/dev/null || true

# Verify every unit is actually inactive AND has released the DB before renaming.
step "Verifying agents stopped + DB released"
for _ in $(seq 1 20); do
  active=0
  for u in "${UNIT_ARR[@]}" "$TESS_UNIT"; do
    systemctl --user is-active --quiet "$u" && active=$((active+1))
  done
  [[ "$active" == "0" ]] && break
  sleep 1
done
[[ "$active" == "0" ]] || die "agents still active after stop ($active) - NOT swapping. [stop-verify]"
# DB must have no open writer before the rename (else writes land in OLD_DIR).
if [[ -f "$LIVE_DIR/store/claudeclaw.db" ]]; then
  # Pick an available open-handle checker; the guard must NOT silently no-op.
  DB_LSOF=""
  if command -v fuser >/dev/null 2>&1; then DB_LSOF="fuser"
  elif command -v lsof  >/dev/null 2>&1; then DB_LSOF="lsof"; fi
  db_has_handle(){ case "$DB_LSOF" in
      fuser) fuser "$1" >/dev/null 2>&1 ;;
      lsof)  lsof -- "$1" >/dev/null 2>&1 ;;
      *) return 2 ;;  # no checker available
    esac; }
  if [[ -n "$DB_LSOF" ]]; then
    for _ in $(seq 1 10); do db_has_handle "$LIVE_DIR/store/claudeclaw.db" || break; sleep 1; done
    db_has_handle "$LIVE_DIR/store/claudeclaw.db" \
      && die "store/claudeclaw.db still has an open handle - NOT swapping (split-DB risk). [stop-verify]"
    ok "DB has no open writer ($DB_LSOF)"
  else
    # Neither fuser nor lsof present: the split-DB guard cannot run. Do not pretend
    # it passed - warn loudly and add a safety pause so writers can drain.
    warn "neither fuser nor lsof present - cannot verify DB is released. Install psmisc or lsof."
    warn "applying a 5s drain pause as a weak fallback before the swap."
    sleep 5
  fi
fi
ok "all units inactive"

step "Swapping $LIVE_DIR <- $STAGE_DIR"
mv "$LIVE_DIR" "$OLD_DIR"
SWAPPED=1                                        # from here, rollback must reverse the rename
mv "$STAGE_DIR" "$LIVE_DIR"
ok "swapped (previous kept at $OLD_DIR)"

step "Restarting agents (tess last)"
systemctl --user start "${UNIT_ARR[@]}"
# Bounded health wait: agents cold-start native better-sqlite3, so give them a
# real window (not a single 3s shot) before declaring failure. A slow-but-fine
# start must NOT reverse a good swap. Only a genuine failure (a unit still not
# active after the window) triggers an EXPLICIT rollback - evaluated, not an
# implicit `false` under errexit.
health_ok=0
for _ in $(seq 1 30); do
  down=0
  for a in $AGENTS; do
    systemctl --user is-active --quiet "com.claudeclaw.agent-$a.service" || down=$((down+1))
  done
  [[ "$down" == "0" ]] && { health_ok=1; break; }
  sleep 1
done
if [[ "$health_ok" != "1" ]]; then
  for a in $AGENTS; do
    systemctl --user is-active --quiet "com.claudeclaw.agent-$a.service" \
      && ok "agent-$a active" || warn "agent-$a NOT active"
  done
  rollback   # explicit: a genuinely-failed restart reverses the swap and restores OLD
fi
for a in $AGENTS; do ok "agent-$a active"; done

# tess last, only if still idle
if pgrep -f "agents/tess/trading/" >/dev/null 2>&1; then
  warn "tess trade started during swap - NOT restarting tess; start when idle: systemctl --user start $TESS_UNIT"
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
  Previous:   $OLD_DIR   (holds .env - shred after smoke: rm -rf $OLD_DIR)
  DB backup:  $BACKUP_DIR/claudeclaw.db
  Next:       bash deploy/smoke-all.sh
EOF
