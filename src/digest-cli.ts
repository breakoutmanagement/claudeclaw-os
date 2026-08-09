#!/usr/bin/env node
/**
 * ClaudeClaw Research Digest CLI
 *
 * Used by the research agent (rob) via the Bash tool. Findings ACCUMULATE
 * into one standing Bunker artifact instead of being pushed to Telegram
 * one message per item; the only Telegram traffic is the daily rollup line.
 *
 * Usage:
 *   node dist/digest-cli.js add --title "..." [--url u] [--source s] [--summary text] [--tier high|normal]
 *   node dist/digest-cli.js render
 *   node dist/digest-cli.js rollup [--commit]
 *   node dist/digest-cli.js schedule ["0 18 * * *"]
 *   node dist/digest-cli.js list
 *
 * Agent scoping: --agent <id> anywhere in argv, else CLAUDECLAW_AGENT_ID,
 * else "rob" (this surface is scoped to the research agent by default).
 */

import { randomBytes } from 'crypto';

import { CronExpressionParser } from 'cron-parser';

import {
  addFinding,
  buildRollup,
  commitRollup,
  digestSlug,
  listFindings,
  publishDigest,
  FindingTier,
} from './research-digest.js';

const agentFlagIdx = process.argv.indexOf('--agent');
const agentId =
  agentFlagIdx !== -1
    ? process.argv[agentFlagIdx + 1] ?? 'rob'
    : process.env.CLAUDECLAW_AGENT_ID ?? 'rob';
const cleanedArgv =
  agentFlagIdx !== -1
    ? process.argv.filter((_, i) => i !== agentFlagIdx && i !== agentFlagIdx + 1)
    : [...process.argv];
const [, , command, ...rest] = cleanedArgv;

interface AddFlags {
  title: string | null;
  url: string | null;
  source: string | null;
  summary: string | null;
  tier: FindingTier;
}

function parseAddFlags(argv: string[]): AddFlags {
  const out: AddFlags = { title: null, url: null, source: null, summary: null, tier: 'normal' };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--title') out.title = argv[++i] ?? null;
    else if (a === '--url') out.url = argv[++i] ?? null;
    else if (a === '--source') out.source = argv[++i] ?? null;
    else if (a === '--summary') out.summary = argv[++i] ?? null;
    else if (a === '--tier') {
      const t = argv[++i];
      if (t !== 'high' && t !== 'normal') {
        console.error(`Invalid --tier "${t ?? ''}" (use high or normal)`);
        process.exit(1);
      }
      out.tier = t;
    }
  }
  return out;
}

// Marker embedded in the scheduled-task prompt so re-running `schedule`
// never registers a second daily ping (the no-duplication guard).
function rollupMarker(id: string): string {
  return `[${id}-digest-rollup]`;
}

async function main(): Promise<void> {
  switch (command) {
    case 'add': {
      const flags = parseAddFlags(rest);
      if (!flags.title) {
        console.error('Usage: digest-cli add --title "..." [--url u] [--source s] [--summary text] [--tier high|normal]');
        process.exit(1);
      }
      const result = addFinding(agentId, {
        title: flags.title,
        url: flags.url ?? undefined,
        source: flags.source ?? undefined,
        summary: flags.summary ?? undefined,
        tier: flags.tier,
      });
      if (!result.added) {
        console.log(`Duplicate finding (id ${result.finding.id}), digest unchanged.`);
        break;
      }
      const pub = publishDigest(agentId);
      console.log(`Finding added (id ${result.finding.id}, tier ${result.finding.tier}).`);
      console.log(`Digest ${pub.updated ? 'refreshed in place' : 'created'}: slug ${pub.slug}`);
      console.log('Do NOT send this finding to Telegram; it ships in the daily rollup.');
      break;
    }

    case 'render': {
      const pub = publishDigest(agentId);
      console.log(`Digest ${pub.updated ? 'refreshed in place' : 'created'}: slug ${pub.slug}`);
      console.log(`Items: ${listFindings(agentId).length}`);
      break;
    }

    case 'rollup': {
      const commit = rest.includes('--commit');
      const rollup = buildRollup(agentId);
      publishDigest(agentId); // keep the artifact current with the ping
      console.log(rollup.text);
      if (commit) commitRollup(agentId);
      break;
    }

    case 'schedule': {
      const cron = rest.find((a) => !a.startsWith('--')) ?? '0 18 * * *';
      try {
        CronExpressionParser.parse(cron);
      } catch {
        console.error(`Invalid cron expression: "${cron}" (example: "0 18 * * *" for daily 6pm)`);
        process.exit(1);
      }
      // Loaded lazily so add/render/rollup never touch the SQLite store.
      const db = await import('./db.js');
      db.initDatabase();
      const marker = rollupMarker(agentId);
      const existing = db
        .getAllScheduledTasks(agentId)
        .find((t) => t.prompt.includes(marker));
      if (existing) {
        console.error(`Daily rollup already scheduled for agent "${agentId}" (task ${existing.id}).`);
        console.error('Delete it first with schedule-cli if you want a different time.');
        process.exit(1);
      }
      const prompt =
        `${marker} Run this exact command with the Bash tool: ` +
        `node dist/digest-cli.js rollup --commit --agent ${agentId} ` +
        `and reply with the single line it prints, nothing else. ` +
        `Do not list individual findings; the digest artifact holds the detail.`;
      const next = Math.floor(CronExpressionParser.parse(cron).next().getTime() / 1000);
      const id = randomBytes(4).toString('hex');
      db.createScheduledTask(id, prompt, cron, next, agentId);
      console.log(`Daily rollup scheduled: task ${id}, agent ${agentId}, cron "${cron}"`);
      console.log(`Digest slug: ${digestSlug(agentId)}`);
      break;
    }

    case 'list': {
      const findings = listFindings(agentId);
      if (findings.length === 0) {
        console.log('No findings in the digest store.');
        break;
      }
      console.log(`${findings.length} finding${findings.length === 1 ? '' : 's'}:\n`);
      for (const f of findings) {
        console.log(`${f.id}  [${f.tier}]  ${f.foundAt}  ${f.title}`);
        if (f.url) console.log(`  ${f.url}`);
      }
      break;
    }

    default:
      console.error('Commands: add | render | rollup | schedule | list');
      process.exit(1);
  }
}

void main();
