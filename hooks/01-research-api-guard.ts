/**
 * Research API Guard Hook
 *
 * Enforces that agents use the Breakout Research API (breakout-research skill)
 * instead of scraping YouTube directly. Fires on preMessage to inject a reminder,
 * and on postMessage to flag violations.
 */

import type { HookContext } from '../src/hooks.js';
import { logger } from '../dist/logger.js';

const YOUTUBE_PATTERNS = [
  /youtube\.com\/watch/i,
  /youtu\.be\//i,
  /youtube\.com\/embed/i,
  /youtube\.com\/v\//i,
];

const SCRAPE_PATTERNS = [
  /curl.*youtube\.com/i,
  /wget.*youtube\.com/i,
  /scrape.*youtube/i,
  /yt-dlp/i,
  /youtube-dl/i,
];

// Agents that should always use the research API
const RESEARCH_FIRST_AGENTS = [
  'grokeroobot',
  'design-system',
  'landing-page',
  'design-audit',
  'visitor-intel',
  'research',
  'main',
];

/**
 * preMessage: If the inbound message references a YouTube URL,
 * inject a context reminder to use the research API first.
 */
export async function preMessage(ctx: HookContext): Promise<void> {
  if (!ctx.message) return;
  if (!RESEARCH_FIRST_AGENTS.includes(ctx.agentId)) return;

  const hasYouTubeUrl = YOUTUBE_PATTERNS.some((p) => p.test(ctx.message!));
  if (hasYouTubeUrl) {
    logger.info(
      { agentId: ctx.agentId, chatId: ctx.chatId },
      'Research API guard: YouTube URL detected in message, research API should be used first',
    );
  }
}

/**
 * postMessage: Check if the agent response contains signs of direct
 * YouTube scraping instead of using the research API.
 */
export async function postMessage(ctx: HookContext): Promise<void> {
  if (!ctx.response) return;
  if (!RESEARCH_FIRST_AGENTS.includes(ctx.agentId)) return;

  const hasScrapeAttempt = SCRAPE_PATTERNS.some((p) => p.test(ctx.response!));
  if (hasScrapeAttempt) {
    logger.warn(
      { agentId: ctx.agentId, chatId: ctx.chatId },
      'Research API guard: Agent attempted direct YouTube scraping instead of using breakout-research skill',
    );
  }
}
