#!/bin/bash
# Agentless health PUSH — runs ON a prod box (breakoutclaw-prod, buddy-breakout-prod, ...).
# Collects this host's metrics locally and Taildrops the JSON to the assistant.
# No inbound SSH to this box is ever opened; push is governed by tailnet ACL.
#
# INSTALL (run once on each prod box, as a user with tailscale + python3):
#   sudo mkdir -p /opt/vps-health/deploy
#   # copy collect_and_render.py and this script into /opt/vps-health/ (+/deploy)
#   sudo chmod +x /opt/vps-health/deploy/push-local-health.sh
#   # add cron (every 6h is plenty; report reads the freshest):
#   ( crontab -l 2>/dev/null; echo '0 */6 * * * /opt/vps-health/deploy/push-local-health.sh >> /var/log/vps-health-push.log 2>&1' ) | crontab -
#
# Manual test:  /opt/vps-health/deploy/push-local-health.sh
set -euo pipefail
export PATH="/usr/bin:/usr/local/bin:/bin:$PATH"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # /opt/vps-health
ASSISTANT="${VPS_HEALTH_ASSISTANT:-ts-cc-os-vanilla}"     # assistant tailnet node
LABEL="${1:-$(hostname)}"
TMP="$(mktemp /tmp/health-XXXX.json)"
trap 'rm -f "$TMP"' EXIT

python3 "$DIR/collect_and_render.py" --emit-host "$LABEL" > "$TMP"
# rename so the receiving side stores a stable per-host filename
OUTNAME="/tmp/${LABEL// /_}.json"
cp "$TMP" "$OUTNAME"
tailscale file cp "$OUTNAME" "${ASSISTANT}:"
rm -f "$OUTNAME"
echo "$(date -Is) pushed $LABEL health to $ASSISTANT"
