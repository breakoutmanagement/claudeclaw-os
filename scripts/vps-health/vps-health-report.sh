#!/bin/bash
# VPS stack health report — collect + render a self-contained HTML.
# Used for the weekly cron run AND ad-hoc (just run it).
#
# Weekly cron (Mondays 08:00):
#   0 8 * * 1 /home/ccaudit/claudeclaw-os/scripts/vps-health/vps-health-report.sh >> /var/log/vps-health.log 2>&1
#
# Ad-hoc:
#   bash scripts/vps-health/vps-health-report.sh
#   (path to the generated HTML is printed on the last line)
#
# Add/remove targets by editing the --target lines below.
set -euo pipefail
export PATH="/usr/bin:/usr/local/bin:/bin:$PATH"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORTS="$DIR/reports"
mkdir -p "$REPORTS"

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$REPORTS/vps-health-$STAMP.html"
JSON="$REPORTS/vps-health-$STAMP.json"

# Live targets are pulled directly (assistant has ACL access to these).
# Prod boxes (breakoutclaw-prod, buddy-breakout-prod) report via agentless push:
# each runs deploy/push-local-health.sh on its own cron -> Taildrop -> intake dir.
INTAKE="${VPS_HEALTH_INTAKE:-$HOME/health-intake}"
mkdir -p "$INTAKE"

# pull any freshly Taildropped JSON into the intake dir (no-op if none waiting)
tailscale file get "$INTAKE" >/dev/null 2>&1 || true

python3 "$DIR/collect_and_render.py" \
  --out "$OUT" \
  --json "$JSON" \
  --intake "$INTAKE" \
  --target "ts-cc-os-vanilla (agents)=local" \
  --target "trading-desk-lon1=trading-desk-lon1"

# keep a stable "latest" pointer
ln -sf "$OUT"  "$REPORTS/latest.html"
ln -sf "$JSON" "$REPORTS/latest.json"

# retention: keep last 12 reports
ls -1t "$REPORTS"/vps-health-*.html 2>/dev/null | tail -n +13 | xargs -r rm -f
ls -1t "$REPORTS"/vps-health-*.json 2>/dev/null | tail -n +13 | xargs -r rm -f

echo "REPORT: $OUT"
