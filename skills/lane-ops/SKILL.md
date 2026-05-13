# Lane Operations Skill

Orchestrate the autonomous dev team using lane-based parallel development. This skill defines the workflow for architect, dev-agent, code-reviewer, and ci-agent.

## Overview

The dev team operates in lanes - independent units of work that can execute in parallel without merge conflicts. The architect plans, dev-agents execute, code-reviewer reviews, and ci-agent validates.

## Workflow: Feature Implementation

### 1. Architect receives work
```bash
# Architect gets a mission task or direct request
# Example: "Add webhook support to the notification system"

# Step 1: Analyze the codebase
# Read relevant files, understand patterns, identify touch points

# Step 2: Create lanes
PROJECT_ROOT=$(git rev-parse --show-toplevel)
node "$PROJECT_ROOT/dist/mission-cli.js" create --agent dev-agent --priority 7 --title "Lane: webhook-types" \
  "LANE: webhook-types
BRANCH: feat/webhooks-types

## Objective
Create TypeScript interfaces and Zod schemas for webhook events.

## Files to create
- src/webhooks/types.ts - Event interfaces, payload schemas

## Acceptance criteria
- [ ] All event types defined with Zod validation
- [ ] Export barrel file updated
- [ ] Tests for schema validation"

node "$PROJECT_ROOT/dist/mission-cli.js" create --agent dev-agent --priority 7 --title "Lane: webhook-handler" \
  "LANE: webhook-handler
BRANCH: feat/webhooks-handler

## Objective
Implement the webhook dispatch and retry system.

## Files to create
- src/webhooks/dispatcher.ts - Queue, dispatch, retry logic

## Acceptance criteria
- [ ] Exponential backoff retry (3 attempts)
- [ ] Dead letter logging after max retries
- [ ] Tests for dispatch and retry"
```

### 2. Dev-agent executes a lane
```bash
# Dev-agent picks up mission task
# Creates branch, writes code, commits, pushes, creates PR

# Working in isolation:
git checkout -b feat/webhooks-types
# ... write code ...
git add src/webhooks/types.ts
git commit -m "feat(webhooks): add event type interfaces and Zod schemas"
git push -u origin feat/webhooks-types

export PATH="$HOME/bin:$PATH"
gh pr create --title "feat(webhooks): event type definitions" \
  --body "## Lane: webhook-types\n\n- Added TypeScript interfaces for all webhook events\n- Zod schemas for runtime validation\n\n## Testing\n- npm test passes\n- Schema validation tests added"
```

### 3. CI-agent validates
```bash
# CI-agent monitors for new PRs or pushes
# Runs the full pipeline on the PR branch

git fetch origin feat/webhooks-types
git checkout feat/webhooks-types
npm ci
npx tsc --noEmit
npm run lint
npm test

# Reports results via hive mind and PR comment
export PATH="$HOME/bin:$PATH"
gh pr comment <PR_NUMBER> --body "CI: All checks passed. Build, lint, and tests green."
```

### 4. Code-reviewer reviews
```bash
# Code-reviewer picks up PRs that pass CI
export PATH="$HOME/bin:$PATH"

# Read the diff
gh pr diff <PR_NUMBER>

# Review with inline comments
gh pr review <PR_NUMBER> --comment --body "[minor] Consider using a discriminated union for event types instead of string enum for better type narrowing."

# Or approve
gh pr review <PR_NUMBER> --approve --body "Clean implementation. Types are well-structured, schemas match interfaces. LGTM."

# Or request changes
gh pr review <PR_NUMBER> --request-changes --body "[blocker] Missing error handling in schema parse. Use safeParse and handle the error case."
```

### 5. Merge and cleanup
```bash
# After code-reviewer approves AND ci-agent confirms green:
export PATH="$HOME/bin:$PATH"
gh pr merge <PR_NUMBER> --squash --delete-branch
```

## Workflow: Bug Fix (single lane)

```bash
# Architect creates a single lane for the fix
PROJECT_ROOT=$(git rev-parse --show-toplevel)
node "$PROJECT_ROOT/dist/mission-cli.js" create --agent dev-agent --priority 9 --title "Fix: webhook retry overflow" \
  "LANE: fix-retry-overflow
BRANCH: fix/webhook-retry-overflow

## Bug
Retry counter overflows when server returns 429 with long Retry-After header.

## Root cause
parseInt on Retry-After doesn't clamp to MAX_RETRY_DELAY.

## Fix
Add Math.min(parsed, MAX_RETRY_DELAY) clamp in dispatcher.ts line 87.

## Files to modify
- src/webhooks/dispatcher.ts - Add clamp

## Acceptance criteria
- [ ] Retry delay never exceeds MAX_RETRY_DELAY
- [ ] Test for 429 with large Retry-After value
- [ ] Existing tests still pass"
```

## Inter-agent communication

All agents communicate via the hive mind:

```bash
# Log an action
sqlite3 store/claudeclaw.db "INSERT INTO hive_mind (agent_id, chat_id, action, summary, artifacts, created_at) VALUES ('AGENT_ID', 'CHAT_ID', 'ACTION', 'SUMMARY', NULL, strftime('%s','now'));"

# Check what others have done
sqlite3 store/claudeclaw.db "SELECT agent_id, action, summary, datetime(created_at, 'unixepoch') FROM hive_mind WHERE created_at > strftime('%s','now') - 3600 ORDER BY created_at DESC;"
```

## Conflict resolution

If two lanes must touch the same file:
1. Architect sequences them (Lane B waits for Lane A to merge)
2. Or architect refactors the plan to avoid the conflict
3. Never run two lanes that modify the same file in parallel

## Escalation paths

- Dev-agent stuck 3+ attempts -> hive mind + mission to architect
- Code-reviewer finds architectural issue -> mission to architect
- CI-agent finds flaky test -> hive mind entry, architect decides priority
- Any agent hits cost cap -> automatic throttle via cost-guard hook

## Key rules

1. Maximum 4 parallel lanes per feature
2. Each lane has exactly one dev-agent
3. No lane modifies files outside its spec without architect approval
4. CI must pass before code-reviewer approves
5. Code-reviewer must approve before merge
6. All communication goes through hive mind, not direct agent-to-agent
