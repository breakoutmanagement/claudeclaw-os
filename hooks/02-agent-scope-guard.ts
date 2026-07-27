/**
 * Agent Scope Guard Hook
 *
 * Prevents agents from performing actions outside their defined role.
 * Logs violations when design agents try to send emails, make purchases,
 * modify system config, etc.
 */

import type { HookContext } from '../src/hooks.js';
import { logger } from '../dist/logger.js';

// Actions that design agents should never perform
const DESIGN_AGENTS = ['grokeroobot', 'design-system', 'landing-page', 'design-audit', 'visitor-intel'];

const FORBIDDEN_PATTERNS_DESIGN: Array<{ pattern: RegExp; reason: string }> = [
  { pattern: /gmail|send.*email|reply.*email|inbox/i, reason: 'Design agents must not access email' },
  { pattern: /slack.*send|post.*slack/i, reason: 'Design agents must not send Slack messages' },
  { pattern: /whatsapp|wa_messages/i, reason: 'Design agents must not access WhatsApp' },
  { pattern: /stripe|payment|invoice|billing/i, reason: 'Design agents must not access payments' },
  { pattern: /systemctl|launchctl|service.*restart/i, reason: 'Design agents must not manage system services' },
  { pattern: /rm\s+-rf|dd\s+if=|mkfs|fdisk/i, reason: 'Design agents must not run destructive system commands' },
  { pattern: /\.env.*write|\.env.*edit|echo.*>.*\.env/i, reason: 'Design agents must not modify .env' },
  { pattern: /git\s+push|git\s+commit/i, reason: 'Design agents must not push to git' },
];

// Tutor agent protections
const TUTOR_FORBIDDEN: Array<{ pattern: RegExp; reason: string }> = [
  { pattern: /gmail|send.*email|inbox/i, reason: 'Tutor must not access email' },
  { pattern: /stripe|payment|invoice|billing/i, reason: 'Tutor must not access payments' },
  { pattern: /systemctl|launchctl|service/i, reason: 'Tutor must not manage system services' },
  { pattern: /\.env|DB_ENCRYPTION|BOT_TOKEN/i, reason: 'Tutor must not access secrets or config' },
  { pattern: /git\s+push|git\s+commit/i, reason: 'Tutor must not push to git' },
  { pattern: /rm\s+-rf|dd\s+if=|mkfs/i, reason: 'Tutor must not run destructive commands' },
];

// Leadership agent protections - no code, no system, no payments
const LEADERSHIP_AGENTS = ['product-owner', 'tech-lead', 'breakout-po'];

const LEADERSHIP_FORBIDDEN: Array<{ pattern: RegExp; reason: string }> = [
  { pattern: /gmail|send.*email|reply.*email|inbox/i, reason: 'Leadership agents must not access email' },
  { pattern: /slack.*send|post.*slack/i, reason: 'Leadership agents must not send Slack messages' },
  { pattern: /whatsapp|wa_messages/i, reason: 'Leadership agents must not access WhatsApp' },
  { pattern: /stripe|payment|invoice|billing/i, reason: 'Leadership agents must not access payments' },
  { pattern: /systemctl|launchctl|service.*restart/i, reason: 'Leadership agents must not manage system services' },
  { pattern: /rm\s+-rf|dd\s+if=|mkfs|fdisk/i, reason: 'Leadership agents must not run destructive system commands' },
  { pattern: /\.env.*write|\.env.*edit|echo.*>.*\.env/i, reason: 'Leadership agents must not modify .env' },
  { pattern: /git\s+push|git\s+commit/i, reason: 'Leadership agents must not push to git' },
];

// Research agent protections - read-only research + web, can write to own memory files only
const RESEARCH_AGENTS = ['rob'];

const RESEARCH_FORBIDDEN: Array<{ pattern: RegExp; reason: string }> = [
  { pattern: /gmail|send.*email|reply.*email|inbox/i, reason: 'Research agents must not access email' },
  { pattern: /slack.*send|post.*slack/i, reason: 'Research agents must not send Slack messages' },
  { pattern: /whatsapp|wa_messages/i, reason: 'Research agents must not access WhatsApp' },
  { pattern: /stripe|payment|invoice|billing/i, reason: 'Research agents must not access payments' },
  { pattern: /systemctl|launchctl|service.*restart/i, reason: 'Research agents must not manage system services' },
  { pattern: /rm\s+-rf|dd\s+if=|mkfs|fdisk/i, reason: 'Research agents must not run destructive system commands' },
  { pattern: /\.env.*write|\.env.*edit|echo.*>.*\.env/i, reason: 'Research agents must not modify .env' },
  { pattern: /git\s+push|git\s+commit/i, reason: 'Research agents must not push to git' },
];

// Scout agent protections - read-only GitHub + web, no email, payments, system, or code changes
const SCOUT_AGENTS = ['anthropic-scout'];

const SCOUT_FORBIDDEN: Array<{ pattern: RegExp; reason: string }> = [
  { pattern: /gmail|send.*email|reply.*email|inbox/i, reason: 'Scout agents must not access email' },
  { pattern: /slack.*send|post.*slack/i, reason: 'Scout agents must not send Slack messages' },
  { pattern: /whatsapp|wa_messages/i, reason: 'Scout agents must not access WhatsApp' },
  { pattern: /stripe|payment|invoice|billing/i, reason: 'Scout agents must not access payments' },
  { pattern: /systemctl|launchctl|service.*restart/i, reason: 'Scout agents must not manage system services' },
  { pattern: /rm\s+-rf|dd\s+if=|mkfs|fdisk/i, reason: 'Scout agents must not run destructive system commands' },
  { pattern: /\.env.*write|\.env.*edit|echo.*>.*\.env/i, reason: 'Scout agents must not modify .env' },
  { pattern: /git\s+push|git\s+commit/i, reason: 'Scout agents must not push to git' },
  { pattern: /git\s+checkout|git\s+merge|git\s+rebase/i, reason: 'Scout agents must not modify git state' },
];

// Dev team agent protections - can do git/code but not email, payments, system services
const DEV_TEAM_AGENTS = ['architect', 'dev-agent', 'code-reviewer', 'ci-agent'];

const DEV_TEAM_FORBIDDEN: Array<{ pattern: RegExp; reason: string }> = [
  { pattern: /gmail|send.*email|reply.*email|inbox/i, reason: 'Dev team agents must not access email' },
  { pattern: /slack.*send|post.*slack/i, reason: 'Dev team agents must not send Slack messages' },
  { pattern: /whatsapp|wa_messages/i, reason: 'Dev team agents must not access WhatsApp' },
  { pattern: /stripe|payment|invoice|billing/i, reason: 'Dev team agents must not access payments' },
  { pattern: /systemctl|launchctl|service.*restart/i, reason: 'Dev team agents must not manage system services' },
  { pattern: /rm\s+-rf\s+\/|dd\s+if=|mkfs|fdisk/i, reason: 'Dev team agents must not run destructive system commands' },
  { pattern: /\.env.*write|\.env.*edit|echo.*>.*\.env/i, reason: 'Dev team agents must not modify .env' },
];

export async function postMessage(ctx: HookContext): Promise<void> {
  if (!ctx.response) return;

  let forbidden: Array<{ pattern: RegExp; reason: string }> = [];

  if (DESIGN_AGENTS.includes(ctx.agentId)) {
    forbidden = FORBIDDEN_PATTERNS_DESIGN;
  } else if (ctx.agentId === 'tutor') {
    forbidden = TUTOR_FORBIDDEN;
  } else if (LEADERSHIP_AGENTS.includes(ctx.agentId)) {
    forbidden = LEADERSHIP_FORBIDDEN;
  } else if (RESEARCH_AGENTS.includes(ctx.agentId)) {
    forbidden = RESEARCH_FORBIDDEN;
  } else if (SCOUT_AGENTS.includes(ctx.agentId)) {
    forbidden = SCOUT_FORBIDDEN;
  } else if (DEV_TEAM_AGENTS.includes(ctx.agentId)) {
    forbidden = DEV_TEAM_FORBIDDEN;
  } else {
    return;
  }

  for (const { pattern, reason } of forbidden) {
    if (pattern.test(ctx.response)) {
      logger.warn(
        { agentId: ctx.agentId, chatId: ctx.chatId, reason },
        'Agent scope guard: out-of-scope action detected in response',
      );
    }
  }
}
