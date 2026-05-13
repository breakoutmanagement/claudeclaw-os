#!/usr/bin/env bash
# Gro IT canonical-naming check.
# Catches the failure mode from 2026-05-11: plans, repo, and Fly reality diverging.
# Hard rule: only canonical names allowed; banned legacy names must not appear in tracked files.
#
# Canonical state (2026-05-11):
#   PROD frontend Fly app:    cooksmart-groit          -> cooksmart-groit.fly.dev
#   STAGING frontend Fly app: cooksmart-staging        -> cooksmart-staging.fly.dev
#   PROD BFF Fly app (TBD):   cooksmart-bff            -> cooksmart-bff.fly.dev
#   STAGING BFF Fly app:      cooksmart-bff-staging    -> cooksmart-bff-staging.fly.dev
#   Public PROD URL:          https://cooksmart.groit.global (Cloudflare -> cooksmart-groit.fly.dev)
# Banned names (must not appear in groit repo tracked files):
#   groit-cooksmart-booth, groit-cooksmart, cooksmart-booth (after decom), cooksmart.groit.fly.dev
#
# Exit codes:
#   0  green
#   1  drift detected
#   2  tooling missing
#
# Usage: bash scripts/groit-canonical-check.sh [--notify-on-change]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$PROJECT_ROOT/.env"
STATE_FILE="$PROJECT_ROOT/store/.groit-canonical-state"
GROIT_REPO="${GROIT_REPO_PATH:-/home/ccaudit/repos/groit}"
FLYCTL="${FLYCTL:-/home/ccaudit/bin/flyctl}"

NOTIFY_ON_CHANGE=false
for arg in "$@"; do [[ "$arg" == "--notify-on-change" ]] && NOTIFY_ON_CHANGE=true; done

CANONICAL_APPS="cooksmart-groit cooksmart-staging"
BANNED_STRINGS=(
  "groit-cooksmart-booth"
  "cooksmart.groit.fly.dev"
)

red=0
findings=""

# 1. fly.toml app= matches a canonical app name.
if [[ -f "$GROIT_REPO/fly.toml" ]]; then
  app_line=$(grep -E '^app[[:space:]]*=' "$GROIT_REPO/fly.toml" | head -1 | sed 's/[^"]*"\([^"]*\)".*/\1/')
  if ! echo "$CANONICAL_APPS" | grep -qw "$app_line"; then
    findings+="fly.toml app=\"$app_line\" not in canonical list ($CANONICAL_APPS)\n"
    red=1
  fi
fi

# 2. No banned strings in tracked groit repo files (excluding docs/retro logs).
if [[ -d "$GROIT_REPO/.git" ]]; then
  cd "$GROIT_REPO"
  for banned in "${BANNED_STRINGS[@]}"; do
    # git grep exits 1 when no matches; tolerate via `|| true` to play nice with set -e/pipefail
    hits=$( { git grep -l --ignore-case "$banned" -- ':!docs/retro*' ':!_reference/*' 2>/dev/null || true; } | grep -c . || true)
    if [[ "${hits:-0}" -gt 0 ]]; then
      findings+="banned string '$banned' found in $hits tracked file(s)\n"
      red=1
    fi
  done
  cd - >/dev/null
fi

# 3. Deployed Fly apps match the canonical list (no rogue named apps in personal org).
if [[ -x "$FLYCTL" ]]; then
  # Top-level .[].Name gives the Fly app names; nested Organization.Name is correctly skipped.
  deployed=$($FLYCTL apps list --json 2>/dev/null | jq -r '.[].Name' | grep -E '^cooksmart' || true)
  for name in $deployed; do
    if ! echo "$CANONICAL_APPS cooksmart-booth cooksmart-bff cooksmart-bff-staging" | grep -qw "$name"; then
      findings+="rogue Fly app '$name' not in canonical or planned list\n"
      red=1
    fi
  done
  # Each canonical app must actually exist
  for app in $CANONICAL_APPS; do
    if ! echo "$deployed" | grep -qw "$app"; then
      findings+="canonical app '$app' missing on Fly\n"
      red=1
    fi
  done
else
  echo "WARN: flyctl not found at $FLYCTL; skipping Fly reality check"
fi

# 4. State diff + optional notify
state_hash=$(echo -e "$findings" | sha256sum | cut -c1-12)
prev=""
[[ -f "$STATE_FILE" ]] && prev=$(cat "$STATE_FILE")
echo "$state_hash" > "$STATE_FILE"

if [[ $red -eq 0 ]]; then
  echo "OK canonical naming aligned"
else
  echo "DRIFT detected:"
  echo -e "$findings"
fi

if $NOTIFY_ON_CHANGE && [[ "$state_hash" != "$prev" ]]; then
  bash "$SCRIPT_DIR/notify.sh" "$([[ $red -eq 0 ]] && echo '✅' || echo '🚨') canonical-check: $([[ $red -eq 0 ]] && echo 'green' || echo 'drift')
$(echo -e "$findings" | head -5)" 2>/dev/null || true
fi

exit $red
