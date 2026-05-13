# Slice 001 — Memory policy enforcement in code, not in rows

> ## HANDOVER — for [agent:main]
>
> **Origin**: Drafted by [agent:product-owner] (Gro IT PO) during a Telegram session on 2026-05-13.
> **Scope correction**: Claudeclaw-os development is OUT of scope for PO (Gro IT). This slice is handed to [agent:main] who owns claudeclaw-os infrastructure. PO will not action this directly.
> **What PO has done**: problem diagnosis, upstream check, Path B decision (local fork + courtesy upstream PR), drafted slice, identified pre-flight blockers.
> **What main agent needs to do**:
> 1. Verify upstream check is still current (PR #59 hasn't merged, no new policy-related commits)
> 2. Resolve the two pre-flight blockers PO flagged (see "Pre-flight blockers" at bottom)
> 3. Execute the implementation order
> 4. Open courtesy PR upstream after fork patch lands
> 5. Update slice header status from `proposed` → `in-progress` → `pr-open #NN` → `merged-fork` as you go
> 6. Log to hive_mind under `agent_id='main'` at each status transition
>
> **Decision authority**: main agent has full authority to deviate from this slice (adjust thresholds, change scope, split into multiple PRs) if a better path emerges during implementation. PO is available for product-level questions but technical calls are main's.

---

**Status**: proposed — handed to [agent:main]
**Filed by**: [agent:product-owner] (Gro IT PO) — handover only
**Owner**: [agent:main]
**Date**: 2026-05-13
**Repo**: local fork of earlyaidopters/claudeclaw-os (we are not the upstream maintainer)
**Strategy**: Path B — apply patches to our local fork now, open a courtesy PR upstream for possible adoption. We do not block on upstream acceptance.
**Estimate**: S (single file changes across 2-3 modules + tests + 1 new script)
**Upstream check (2026-05-13)**: No release, PR, or issue upstream addresses this. Adjacent open PR #59 wires ingestion into scheduler paths but does not touch policy. Safe to proceed on our fork; pull origin/main first for clean base.

## Problem

The memory system has documented policies stored as rows in the `memories` table ("always pin", "dedup before insert", "weekly prune"). Nothing in the ingest code reads them. They function as advice to humans and AI assistants, not as enforcement on the writer.

Observed consequences:
- 154 memories, only 40 pinned (26%) despite the standing rule "always pin"
- Near-duplicate memories on the same topic (e.g. memory IDs 142, 166 both restating "GitHub is canonical bus")
- No supersession chain — enhancements either become duplicates or get silently dropped
- Dedup silently skipped when Gemini embedding generation fails (quota errors → duplicates land)
- "Weekly prune cron" referenced in memory #61 does not exist in any crontab

## Root cause

Policy lives in data, not in code. The INSERT path (`saveStructuredMemory` in `src/db.ts:818`) hard-codes column list and never includes `pinned`, so all auto-ingested rows default to `pinned=0`. The dedup check in `src/memory-ingest.ts:219-232` uses a 0.85 cosine threshold and skips entirely on embedding failure. There is no supersession write path.

## In scope (single slice, single PR)

### A. Pin-by-default at the INSERT
- Add `pinned` column to `saveStructuredMemory` INSERT (db.ts ~line 818)
- Default value sourced from a hardcoded `MEMORY_POLICY.pinByDefault = true` constant
- Migration unnecessary — column already exists (db.ts:668)

### B. Tighten dedup
- Lower threshold to 0.78 (from 0.85)
- Add topic-set Jaccard fallback: if cosine 0.65–0.78 AND topic overlap ≥ 0.6, treat as duplicate
- Both thresholds live in `MEMORY_POLICY` constant

### C. Supersession path
- When dedup matches, do NOT silently drop the new memory
- Insert the new row with `superseded_by = existing.id`
- Update the existing row's `accessed_at` to mark continued relevance
- Existing schema already has `superseded_by` column (db.ts already references it in queries)

### D. Fail-closed on embedding errors
- If `embedText` throws, do not ingest at all (return false)
- Log structured warning, allow retry on next conversation turn
- Better to lose a memory than create an unsuppressible duplicate

### E. Policy module
- Create `src/memory-policy.ts` exporting `MEMORY_POLICY` constant:
  - `pinByDefault: true`
  - `cosineThreshold: 0.78`
  - `jaccardFallback: 0.6`
  - `cosineJaccardZone: 0.65`
  - `pruneIntervalDays: 7`
- All four call sites in `memory-ingest.ts` and `db.ts` read from this module
- Policy memories (#60, #61, #72, #73, etc.) become audit history, no longer load-bearing

### F. Weekly prune cron (actually scheduled)
- Add `scripts/memory-prune.sh` that runs in dry-run mode by default
- Reports: unpinned memories older than `pruneIntervalDays`, duplicate clusters by cosine ≥ 0.78, orphaned superseded chains
- Wire into existing 5-script cron suite (heartbeat, memory-drift, fly-access, canonical-check, build-check)
- Posts diff to Telegram via `notify.sh`; deletion requires manual approval

## Out of scope

- Backfill of existing 114 unpinned memories (separate cleanup — flag for human review per standing rule)
- Memory consolidation rewrites (current consolidator stays as-is)
- Cross-agent memory sharing changes (issue #14 territory, already closed)
- Embedding model swap (separate decision)
- **Upstream acceptance**: this slice does NOT depend on earlyaidopters/claudeclaw-os merging the change. Our fork is the source of truth for our deployment. The upstream PR is a courtesy contribution only.

## Fork hygiene

We maintain a long-lived local fork of earlyaidopters/claudeclaw-os. Patches in this slice land on our fork first, courtesy PR opened upstream.

**Branch naming**
- Patch branches: `fork/<slice-number>-<short-name>` (e.g. `fork/001-memory-policy`)
- Integration branch: `main` (our main tracks our patched state, not vanilla upstream)
- Upstream sync branch: `upstream/main` (read-only mirror of earlyaidopters origin)

**Rebase cadence**
- Pull upstream weekly (Mondays). `git fetch upstream && git rebase upstream/main` on our main.
- If a fork patch conflicts with upstream, the patch owner (filed-by in slice header) resolves before next merge.
- If upstream merges a patch we already carry, drop the local commit on next rebase.

**Patch tracker**
- `docs/slices/` is the source of truth for what we carry vs vanilla.
- Each slice header notes upstream status: `proposed`, `pr-open #NN`, `merged-upstream` (drop on next rebase), `rejected-upstream` (carry indefinitely).
- Monthly review: PO walks `docs/slices/` and reconciles status against upstream PR state.

**Upstream PR opening**
- After fork patch is verified working, open PR upstream from a fresh branch in our fork: `upstream-contribution/<slice-number>-<short-name>`.
- PR description references the slice doc by URL.
- Tag PR `enhancement` or `bug` per upstream's conventions.
- Do not chase or pressure upstream for review. If they merge, great. If not, we keep carrying.

## Acceptance criteria

1. **Pin-by-default test**: Insert a new memory via `ingestConversationTurn`, assert resulting row has `pinned = 1`. Existing test suite extended.
2. **Dedup test**: Insert 10 near-duplicate memories on the same topic in sequence. After all writes complete:
   - Exactly 1 row has `superseded_by IS NULL`
   - 9 rows have `superseded_by` pointing back through the chain
   - Zero unsuperseded duplicates exist
3. **Fail-closed test**: Mock `embedText` to throw. Assert `ingestConversationTurn` returns false and `memories` row count is unchanged.
4. **Policy module test**: Assert all four call sites import from `memory-policy.ts`, no inline magic numbers remain in `memory-ingest.ts` or `db.ts` for these thresholds.
5. **Prune script smoke**: Run `scripts/memory-prune.sh --dry-run` against a seeded DB with known duplicates. Exit 0, output identifies the duplicates correctly, no rows deleted.
6. **Manual verification**: After merge, run the 5-whys sequence we just completed. Memory consolidator must not create a near-duplicate of an existing memory; it must either skip or supersede.

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Dedup threshold 0.78 too aggressive, drops legitimate distinct memories | Medium | Add `MEMORY_POLICY` constant so the value is tunable in one place; ship with dry-run logging for 1 week before relying on it |
| Supersession chain grows infinite if every turn restates same fact | Low | Cap chain depth at 5; if new memory would be 6th, mark all prior as low-importance and only keep newest |
| Fail-closed on embedding errors increases memory loss during Gemini outages | Medium | Add metric/log line so we can see how often this fires. Acceptable trade-off vs duplicate proliferation. |
| Existing tests assume pinned=0 default | Low | Audit + update existing tests in same PR |
| Policy module becomes another rules-as-data trap | Low | Constant, not config file. Compiled in. No reload semantics. |

## Implementation order

1. Set up `upstream` remote pointing at earlyaidopters/claudeclaw-os (if not present); fetch
2. Confront/stash existing uncommitted local modifications on a separate branch
3. Rebase our `main` onto `upstream/main` (currently 2 commits behind)
4. Create branch `fork/001-memory-policy` off our main
5. Create `src/memory-policy.ts` with constants
6. Patch `saveStructuredMemory` INSERT to include `pinned`
7. Patch `memory-ingest.ts` dedup block: new thresholds, supersession write, fail-closed embedding
8. Add tests for all four behaviors (pin default, supersession, fail-closed, policy isolation)
9. Add `scripts/memory-prune.sh` (dry-run)
10. Wire prune script into cron suite
11. Merge `fork/001-memory-policy` into our `main` (fork is now patched)
12. Open courtesy PR upstream from `upstream-contribution/001-memory-policy` branch
13. Update slice header status to `pr-open #NN`

## Why this matters now

Every conversation today produced at least one near-duplicate memory event. The PO 5-whys at 2026-05-13 12:00 UTC about "why don't I see architect work" wrote one entry; the same conversation at 16:10 UTC wrote a second near-duplicate (#166 vs #142). Without this slice, the database drifts further from the standing rules every day.

## Test cohort (organic verification)

The deploy-cleanup umbrella (groit#142) already has a "3 organic PRs flow through" gate. This slice will create at least 3 memory writes during its own implementation (slice plan, PR description, post-merge retro). Asserting those 3 produce 1 row + 2 superseded references (or zero new rows if covered by existing memories) is itself the acceptance evidence.

## Pre-flight blockers (PO flagged, main agent to resolve before step 1)

1. **Uncommitted local state.** Working tree at `/home/ccaudit/claudeclaw-os` has modifications to `src/bot.ts`, `src/config.ts`, `src/dashboard.ts`, `src/env.ts`, `src/gemini.ts`, `src/index.ts`, `agents/_template/CLAUDE.md`, `package-lock.json`, plus untracked directories: `agents/anthropic-scout/`, `agents/ci-agent/`, `agents/code-reviewer/`, `agents/design-audit/`, `agents/design-system/`, `agents/dev-agent/`, `agents/landing-page/`, `agents/product-owner/`, `agents/tech-lead/`, `agents/tutor/`, `agents/visitor-intel/`, `hooks/`. Main agent must determine which are deliberate fork patches (commit to fork main) vs in-progress work (stash to separate branch) before rebasing onto upstream.

2. **Fork remote not configured.** `git remote -v` shows only `origin → https://github.com/earlyaidopters/claudeclaw-os.git`. There is no separate fork remote. Either:
   - (a) Our `origin` IS already a separate fork repo and earlyaidopters is upstream we need to add as a second remote, OR
   - (b) We are running directly against upstream and need to first fork to e.g. `breakoutmanagement/claudeclaw-os` or `earlyaidopters-fork/claudeclaw-os`, push our patched state there, and re-point origin.
   PO does not know which is the case. Main agent must verify before opening the courtesy upstream PR (step 12) — without a fork repo, there is no branch to PR from.

## Handover log

| Date | Agent | Action |
|---|---|---|
| 2026-05-13 | product-owner | Slice drafted, handed to main |
| | main | (to fill in) |
