/**
 * Rob Identity Reload Hook (Post-Compaction)
 *
 * When the Claude Agent SDK auto-compacts Rob's context window, identity
 * drifts: the conversation history is summarized away, custom rules in
 * memory/identity.md may decay, and recent insights from insights.md may
 * collapse to a one-line summary. After compaction Rob can:
 *   - forget he must use the Breakout Research API (not direct YouTube)
 *   - forget routing rules (tech-lead for patterns, product-owner for product)
 *   - reintroduce stale priors that newer insights have already corrected
 *
 * This hook detects compaction via the `compaction_events` table (which
 * bot.ts populates after every turn that triggered SDK compaction — see
 * src/bot.ts saveCompactionEvent call) and writes a high-importance
 * memory entry. The standard memory pipeline (buildMemoryContext) will
 * surface that memory on Rob's NEXT preMessage, instructing him to
 * re-read his identity files before responding.
 *
 * Scope: only fires for agentId === 'rob'. Other agents have different
 * identity postures (CLAUDE.md only) and would need their own hook
 * variants — keeping this scoped avoids cross-agent surprises.
 *
 * Idempotency: only fires once per ~2-minute window per chat. Without
 * this guard, every postMessage in the minute after compaction would
 * write another reload memory and bloat the memory store.
 *
 * Origin: pattern documented in
 *   /home/ccaudit/.claudeclaw/agents/rob/memory/knowledge/insights.md
 *   ("Build Your Agentic OS Better Than The 99%", 2026-05-09 entry)
 */

import path from 'path';
import Database from 'better-sqlite3';
import type { HookContext } from '../src/hooks.js';
import { logger } from '../dist/logger.js';
import { saveStructuredMemory } from '../dist/db.js';

const TARGET_AGENT = 'rob';
// How far back to look for a compaction event before declaring "we just compacted".
// 90s is generous — covers the time between bot.ts saving the event and the
// hook firing in postMessage on the same turn (essentially the same instant).
const COMPACTION_LOOKBACK_SECONDS = 90;
// How far back to look for a previously-written reload memory before re-firing.
// Slightly larger than the compaction window so quick follow-up turns within
// the same compaction don't double-write.
const DEDUPE_LOOKBACK_SECONDS = 120;

const RELOAD_BODY = [
  '[Identity Reload — context just compacted]',
  'The SDK just auto-compressed your conversation history. Identity may have drifted.',
  'Before doing anything else on the next message, re-read in this order:',
  '  1. /home/ccaudit/.claudeclaw/agents/rob/memory/identity.md  (who you are, rules)',
  '  2. /home/ccaudit/.claudeclaw/agents/rob/memory/knowledge/insights.md  (top 60 lines — what you already know)',
  '  3. /home/ccaudit/.claudeclaw/agents/rob/memory/state/queue.md  (what is pending)',
  'Re-grounding now prevents drift. Do not skip this. Continue with the user request after.',
].join('\n');

/**
 * Resolve the ClaudeClaw SQLite path. Mirrors the resolution logic the
 * rest of the system uses — env override first, then a HOME-relative
 * default. Avoids importing src/config.ts (which would create a circular
 * load risk for hooks loaded from dist).
 */
function resolveDbPath(): string {
  const root =
    process.env.CLAUDECLAW_PROJECT_ROOT ??
    path.join(process.env.HOME ?? '', 'claudeclaw-os');
  return path.join(root, 'store', 'claudeclaw.db');
}

/**
 * postMessage: After every turn for Rob, check if a compaction was just
 * recorded for the active session. If yes (and we haven't already written
 * a reload memory recently), persist a high-importance memory so the
 * next preMessage's buildMemoryContext surfaces it.
 */
export async function postMessage(ctx: HookContext): Promise<void> {
  if (ctx.agentId !== TARGET_AGENT) return;
  if (!ctx.sessionId) return;

  const now = Math.floor(Date.now() / 1000);
  const compactionCutoff = now - COMPACTION_LOOKBACK_SECONDS;
  const dedupeCutoff = now - DEDUPE_LOOKBACK_SECONDS;

  let shouldFire = false;
  try {
    const db = new Database(resolveDbPath(), { readonly: true });
    try {
      const recent = db
        .prepare(
          `SELECT 1 AS hit FROM compaction_events
           WHERE session_id = ? AND created_at >= ?
           LIMIT 1`,
        )
        .get(ctx.sessionId, compactionCutoff) as { hit: number } | undefined;

      if (!recent) return;

      // Idempotency check: did we already write a reload memory recently
      // for this chat? If so, skip — avoids bloating memories on rapid
      // post-compaction turns.
      const dupe = db
        .prepare(
          `SELECT 1 AS hit FROM memories
           WHERE chat_id = ?
             AND agent_id = ?
             AND source = 'compaction-hook'
             AND created_at >= ?
           LIMIT 1`,
        )
        .get(ctx.chatId, TARGET_AGENT, dedupeCutoff) as
        | { hit: number }
        | undefined;

      shouldFire = !dupe;
    } finally {
      db.close();
    }
  } catch (err) {
    logger.warn(
      { error: err instanceof Error ? err.message : String(err) },
      'rob-identity-reload: DB read failed, skipping',
    );
    return;
  }

  if (!shouldFire) return;

  try {
    saveStructuredMemory(
      ctx.chatId,
      RELOAD_BODY,
      'Re-read identity files: context compaction detected',
      ['rob', 'identity', 'compaction'],
      ['identity-reload', 'agentic-os', 'post-compaction'],
      0.95, // high importance — surfaces ahead of normal-salience memories
      'compaction-hook',
      TARGET_AGENT,
    );
    logger.info(
      { chatId: ctx.chatId, sessionId: ctx.sessionId },
      'rob-identity-reload: queued reload memory after compaction',
    );
  } catch (err) {
    logger.warn(
      { error: err instanceof Error ? err.message : String(err) },
      'rob-identity-reload: failed to write reload memory',
    );
  }
}
