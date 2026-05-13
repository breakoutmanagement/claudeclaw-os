/**
 * Cost Guard Hook
 *
 * Tracks per-agent token usage and logs warnings when agents
 * approach budget thresholds. Prevents runaway delegation loops.
 */

import type { HookContext } from '../src/hooks.js';
import { logger } from '../dist/logger.js';

// Per-agent daily cost caps (USD). 0 = unlimited.
const AGENT_DAILY_CAPS: Record<string, number> = {
  'design-system': 5.0,
  'landing-page': 5.0,
  'design-audit': 5.0,
  'visitor-intel': 5.0,
  'tutor': 3.0,
  'research': 10.0,
  'comms': 5.0,
  'content': 5.0,
  'ops': 5.0,
  'architect': 10.0,
  'dev-agent': 15.0,
  'code-reviewer': 10.0,
  'ci-agent': 10.0,
  'product-owner': 5.0,
  'tech-lead': 5.0,
  'anthropic-scout': 2.0,
  'rob': 10.0,
  'breakout-po': 5.0,
};

// In-memory tracking (resets on restart)
const dailyUsage: Record<string, { cost: number; turns: number; resetDay: string }> = {};

function today(): string {
  return new Date().toISOString().slice(0, 10);
}

function getOrReset(agentId: string): { cost: number; turns: number } {
  const d = today();
  if (!dailyUsage[agentId] || dailyUsage[agentId].resetDay !== d) {
    dailyUsage[agentId] = { cost: 0, turns: 0, resetDay: d };
  }
  return dailyUsage[agentId];
}

export async function postMessage(ctx: HookContext): Promise<void> {
  if (!ctx.usage) return;

  const usage = getOrReset(ctx.agentId);
  const turnCost = ctx.usage['cost_usd'] ?? 0;
  usage.cost += turnCost;
  usage.turns += 1;

  const cap = AGENT_DAILY_CAPS[ctx.agentId] ?? 0;

  if (cap > 0 && usage.cost >= cap * 0.8) {
    const pct = Math.round((usage.cost / cap) * 100);
    logger.warn(
      {
        agentId: ctx.agentId,
        dailyCost: usage.cost.toFixed(2),
        cap,
        pct,
        turns: usage.turns,
      },
      `Cost guard: ${ctx.agentId} at ${pct}% of daily cap ($${usage.cost.toFixed(2)} / $${cap})`,
    );
  }

  // Hard warning at 50+ turns per day (runaway loop detection)
  if (usage.turns > 50) {
    logger.error(
      { agentId: ctx.agentId, turns: usage.turns },
      'Cost guard: possible runaway loop, 50+ turns today',
    );
  }
}
