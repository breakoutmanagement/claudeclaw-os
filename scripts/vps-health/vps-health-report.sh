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

python3 "$DIR/collect_and_render.py" \
  --out "$OUT" \
  --json "$JSON" \
  --target "ts-cc-os-vanilla (agents)=local" \
  --target "trading-desk-lon1=trading-desk-lon1" \
  --target "breakoutclaw-prod=breakoutclaw-prod" \
  --target "buddy-breakout-prod=buddy-breakout-prod"
  # NOTE: the two prod boxes will render OFFLINE until the assistant has SSH
  # access. That needs either (a) tagging them + an ACL grant tag:assistant->
  # tag:<prod> tcp:22, or (b) the agentless push model (collector runs locally
  # on each box via its own cron, writing JSON the report aggregates).

# keep a stable "latest" pointer
ln -sf "$OUT"  "$REPORTS/latest.html"
ln -sf "$JSON" "$REPORTS/latest.json"

# retention: keep last 12 reports
ls -1t "$REPORTS"/vps-health-*.html 2>/dev/null | tail -n +13 | xargs -r rm -f
ls -1t "$REPORTS"/vps-health-*.json 2>/dev/null | tail -n +13 | xargs -r rm -f

echo "REPORT: $OUT"
