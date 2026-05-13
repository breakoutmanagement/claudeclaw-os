#!/usr/bin/env bash
# Fly deploy-readiness check.
# Catches the failure mode from 2026-05-10/11: no FLY_API_TOKEN reachable on Linux box,
# resulting in ~24h of CI deploy failures before anyone noticed.
#
# Greens when:
#   - flyctl binary present and auth whoami succeeds
#   - FLY_API_TOKEN present and non-empty in claudeclaw .env
#   - canonical apps reachable via flyctl
#
# Exit codes: 0 green, 1 red, 2 tooling missing.
# Usage: bash scripts/fly-access-check.sh [--notify-on-change]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$PROJECT_ROOT/.env"
STATE_FILE="$PROJECT_ROOT/store/.fly-access-state"
FLYCTL="${FLYCTL:-/home/ccaudit/bin/flyctl}"

NOTIFY_ON_CHANGE=false
for arg in "$@"; do [[ "$arg" == "--notify-on-change" ]] && NOTIFY_ON_CHANGE=true; done

CANONICAL_APPS="cooksmart-groit cooksmart-staging"
red=0
findings=""

# 1. flyctl exists and is authenticated
if [[ ! -x "$FLYCTL" ]]; then
  findings+="flyctl missing at $FLYCTL\n"; red=1
else
  whoami=$($FLYCTL auth whoami 2>&1 || true)
  if [[ "$whoami" != *"@"* ]]; then
    findings+="flyctl not authenticated: $whoami\n"; red=1
  fi
fi

# 2. FLY_API_TOKEN present in claudeclaw .env (for CI/agent deploys without device-code flow)
if ! grep -qE '^FLY_API_TOKEN=.+' "$ENV_FILE" 2>/dev/null; then
  findings+="FLY_API_TOKEN missing or empty in $ENV_FILE\n"; red=1
fi

# 3. Each canonical app reachable via Fly API
if [[ -x "$FLYCTL" ]] && [[ $red -eq 0 || "$findings" != *"not authenticated"* ]]; then
  for app in $CANONICAL_APPS; do
    if ! $FLYCTL status -a "$app" >/dev/null 2>&1; then
      findings+="canonical app '$app' not reachable via flyctl\n"; red=1
    fi
  done
fi

state_hash=$(echo -e "$findings" | sha256sum | cut -c1-12)
prev=""
[[ -f "$STATE_FILE" ]] && prev=$(cat "$STATE_FILE")
echo "$state_hash" > "$STATE_FILE"

if [[ $red -eq 0 ]]; then
  echo "OK fly access ready"
else
  echo "BLOCKED:"
  echo -e "$findings"
fi

if $NOTIFY_ON_CHANGE && [[ "$state_hash" != "$prev" ]]; then
  bash "$SCRIPT_DIR/notify.sh" "$([[ $red -eq 0 ]] && echo '✅' || echo '🚨') fly-access: $([[ $red -eq 0 ]] && echo 'green' || echo 'blocked')
$(echo -e "$findings" | head -5)" 2>/dev/null || true
fi

exit $red
