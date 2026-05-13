#!/usr/bin/env bash
# groit-dispatch.sh — GitHub-bus dispatcher for breakoutmanagement/groit
#
# Polls GitHub issues and PRs, routes work to ClaudeClaw agents via mission_tasks.
# GitHub is the dispatch surface (CANONICAL §6); this script bridges GitHub events
# to the internal agent scheduler.
#
# Run via systemd timer every 60s, or cron.
#
# Claim mechanism:
#   - Issues: assigned to agent + labeled "claimed-by:<agent>"
#   - PRs:    labeled "review-requested:<agent>"
#
# Agents pick up work from the mission_tasks table (scheduler.ts polls every 60s).

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."
GH="/home/ccaudit/bin/gh"
REPO="breakoutmanagement/groit"
STATE_DIR="$PROJECT_ROOT/store/groit-dispatch"
LOG="$PROJECT_ROOT/store/groit-dispatch.log"

mkdir -p "$STATE_DIR"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"
}

# ── Helpers ──────────────────────────────────────────────────────────────────

already_dispatched() {
  local type="$1" id="$2"
  [ -f "$STATE_DIR/${type}-${id}.dispatched" ]
}

mark_dispatched() {
  local type="$1" id="$2"
  echo "$(date -u +%s)" > "$STATE_DIR/${type}-${id}.dispatched"
}

create_mission() {
  local agent="$1" title="$2" prompt="$3"
  node "$PROJECT_ROOT/dist/mission-cli.js" create \
    --agent "$agent" \
    --title "$title" \
    --priority 7 \
    "$prompt" 2>> "$LOG"
}

# ── Issue dispatch (architect) ───────────────────────────────────────────────
#
# Picks up issues that are:
#   - Open
#   - Not assigned to anyone
#   - Not labeled "claimed-by:architect" or "wontfix" or "duplicate"
#   - Labeled "enhancement" or "bug" (actionable work, not meta)
#
# Architect's job: read the issue, decompose into lane specs.

dispatch_issues_to_architect() {
  local issues
  issues=$($GH issue list --repo "$REPO" \
    --state open \
    --json number,title,labels,assignees \
    --limit 20 \
    --jq '.[] | select(
      (.assignees | length == 0) and
      (.labels | map(.name) | (
        (contains(["claimed-by:architect"]) | not) and
        (contains(["wontfix"]) | not) and
        (contains(["duplicate"]) | not) and
        (contains(["blocked"]) | not) and
        (contains(["needs-info"]) | not)
      ))
    ) | "\(.number)\t\(.title)"' 2>/dev/null) || return 0

  [ -z "$issues" ] && return 0

  while IFS=$'\t' read -r number title; do
    [ -z "$number" ] && continue
    already_dispatched "issue" "$number" && continue

    log "Dispatching issue #$number to architect: $title"

    # Claim: assign + label
    $GH issue edit "$number" --repo "$REPO" \
      --add-assignee "" \
      --add-label "claimed-by:architect" 2>> "$LOG" || true

    # Create mission task for architect
    create_mission "architect" \
      "Issue #$number: $title" \
      "GitHub issue #$number in $REPO needs architecture decomposition.

Read the issue:
  gh issue view $number --repo $REPO

Your job:
1. Read the full issue body and acceptance criteria
2. Assess complexity and break into lane specs if needed
3. For each lane, create a GitHub comment on the issue with the lane spec (use the lane spec format from your CLAUDE.md)
4. For simple issues (single lane), post the lane spec as a comment and label the issue 'lane-ready'
5. For multi-lane issues, create sub-issues linked to the parent, each labeled 'lane-ready'
6. Comment '[agent:architect] Decomposed into N lane(s)' when done

Prefix all your GitHub comments with [agent:architect].
Do NOT write code. Spec only."

    mark_dispatched "issue" "$number"

  done <<< "$issues"
}

# ── Lane dispatch (dev-agents) ───────────────────────────────────────────────
#
# Picks up issues labeled "lane-ready" that haven't been claimed by a dev-agent.

dispatch_lanes_to_dev_agent() {
  local lanes
  lanes=$($GH issue list --repo "$REPO" \
    --state open \
    --label "lane-ready" \
    --json number,title,labels,assignees \
    --limit 20 \
    --jq '.[] | select(
      (.labels | map(.name) | contains(["claimed-by:dev-agent"]) | not) and
      (.assignees | length == 0 or (.assignees | map(.login) | contains(["dev-agent"]) | not))
    ) | "\(.number)\t\(.title)"' 2>/dev/null) || return 0

  [ -z "$lanes" ] && return 0

  while IFS=$'\t' read -r number title; do
    [ -z "$number" ] && continue
    already_dispatched "lane" "$number" && continue

    log "Dispatching lane #$number to dev-agent: $title"

    # Claim
    $GH issue edit "$number" --repo "$REPO" \
      --add-label "claimed-by:dev-agent" 2>> "$LOG" || true

    # Create mission task
    create_mission "dev-agent" \
      "Lane #$number: $title" \
      "You have a lane assignment from the architect. GitHub issue #$number in $REPO.

Read the issue and any lane spec comments:
  gh issue view $number --repo $REPO --comments

Your job:
1. Read the lane spec carefully (look for [agent:architect] comments with the spec)
2. Clone the repo if needed and create the feature branch specified in the spec
3. Implement exactly what the spec says
4. Write tests
5. Commit with conventional commits
6. Create a PR linking to issue #$number
7. Comment on the issue: '[agent:dev-agent] PR #<number> submitted'

Use gh CLI for all GitHub operations. Prefix all comments with [agent:dev-agent].
Follow the spec precisely. Do not deviate without escalating to architect."

    mark_dispatched "lane" "$number"

  done <<< "$lanes"
}

# ── PR dispatch (code-reviewer) ──────────────────────────────────────────────
#
# Picks up PRs that:
#   - Are open
#   - Have no review yet (no approvals or change requests)
#   - Not labeled "reviewed" or "claimed-by:code-reviewer"

dispatch_prs_to_code_reviewer() {
  local prs
  prs=$($GH pr list --repo "$REPO" \
    --state open \
    --json number,title,labels,reviewRequests,reviews \
    --limit 20 \
    --jq '.[] | select(
      (.labels | map(.name) | (
        (contains(["claimed-by:code-reviewer"]) | not) and
        (contains(["no-review"]) | not)
      )) and
      (.reviews | length == 0)
    ) | "\(.number)\t\(.title)"' 2>/dev/null) || return 0

  [ -z "$prs" ] && return 0

  while IFS=$'\t' read -r number title; do
    [ -z "$number" ] && continue
    already_dispatched "pr" "$number" && continue

    log "Dispatching PR #$number to code-reviewer: $title"

    # Claim
    $GH pr edit "$number" --repo "$REPO" \
      --add-label "claimed-by:code-reviewer" 2>> "$LOG" || true

    # Create mission task
    create_mission "code-reviewer" \
      "Review PR #$number: $title" \
      "Review PR #$number in $REPO.

Read the PR:
  gh pr view $number --repo $REPO
  gh pr diff $number --repo $REPO
  gh pr checks $number --repo $REPO

Your job:
1. Read the PR description and linked issue/lane spec
2. Review the diff against your review checklist (correctness, security, performance, style, tests)
3. Post inline review comments where appropriate, prefixed with severity: [blocker], [major], [minor], [nit]
4. Either approve or request changes via gh pr review
5. Comment summary: '[agent:code-reviewer] Review complete — <APPROVED|CHANGES_REQUESTED>'

Prefix all comments with [agent:code-reviewer].
Be specific and actionable. One pass — list ALL issues, don't drip-feed."

    mark_dispatched "pr" "$number"

  done <<< "$prs"
}

# ── Cleanup old dispatch markers (>7 days) ───────────────────────────────────

cleanup_old_markers() {
  find "$STATE_DIR" -name "*.dispatched" -mtime +7 -delete 2>/dev/null || true
}

# ── Main ─────────────────────────────────────────────────────────────────────

log "Dispatch cycle starting"

dispatch_issues_to_architect
dispatch_lanes_to_dev_agent
dispatch_prs_to_code_reviewer
cleanup_old_markers

log "Dispatch cycle complete"
