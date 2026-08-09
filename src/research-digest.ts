import fs from 'fs';
import path from 'path';
import crypto from 'crypto';

import { CLAUDECLAW_CONFIG, DASHBOARD_URL, expandHome } from './config.js';
import { BUNKER_DIR, BunkerMeta } from './bunker.js';

// Research digest: the accumulate-instead-of-push output surface for the
// research agent ("rob"). Findings land in a per-agent JSONL store; the
// rendered view is ONE standing Bunker artifact at a stable slug that is
// refreshed in place (same card, same slug, pinned so sweepExpired never
// archives it). The daily rollup is a thin one-line Telegram pointer built
// from the findings that arrived since the last committed rollup.
//
// Deliberately file-based (like the Bunker itself) and deliberately NOT part
// of the memory pipeline: nothing here reads or writes memories/consolidations
// or calls memory-ingest. The digest is a report surface, not a memory.

export type FindingTier = 'high' | 'normal';

export interface FindingInput {
  title: string;
  url?: string;
  source?: string;
  summary?: string;
  tier?: FindingTier;
}

export interface DigestFinding {
  id: string;
  title: string;
  url: string | null;
  source: string | null;
  summary: string | null;
  tier: FindingTier;
  foundAt: string; // ISO timestamp
}

export interface AddResult {
  added: boolean;
  finding: DigestFinding;
  reason?: 'duplicate';
}

export interface PublishResult {
  slug: string;
  dir: string;
  updated: boolean; // true when an existing card was refreshed in place
}

export interface Rollup {
  count: number;
  top: DigestFinding | null;
  since: string | null; // ISO of the last committed rollup, null = never
  text: string; // the thin one-line Telegram pointer
}

interface DigestState {
  lastRollupAt?: string; // ISO
}

// ── Store locations ─────────────────────────────────────────────────────────
// Rooted at the canonical external config dir like the Bunker, so a repo
// redeploy (deploy/README does git reset --hard) never wipes accumulated
// findings. DIGEST_DIR env override for tests and unusual layouts.

export function digestDir(agentId: string): string {
  const root = process.env.DIGEST_DIR
    ? expandHome(process.env.DIGEST_DIR)
    : path.join(CLAUDECLAW_CONFIG, 'digest');
  return path.join(root, safeAgentId(agentId));
}

function safeAgentId(agentId: string): string {
  const s = agentId.replace(/[^a-zA-Z0-9._-]/g, '');
  if (!s) throw new Error(`Invalid agent id: ${JSON.stringify(agentId)}`);
  return s;
}

function findingsFile(agentId: string): string {
  return path.join(digestDir(agentId), 'findings.jsonl');
}

function stateFile(agentId: string): string {
  return path.join(digestDir(agentId), 'state.json');
}

export function digestSlug(agentId: string): string {
  return `${safeAgentId(agentId)}-research-digest`;
}

export function digestTitle(agentId: string): string {
  const s = safeAgentId(agentId);
  return `${s.charAt(0).toUpperCase()}${s.slice(1)} Research Digest`;
}

// ── Findings store ──────────────────────────────────────────────────────────

function dedupeKey(input: { title: string; url?: string | null }): string {
  const url = input.url?.trim().toLowerCase().replace(/\/+$/, '');
  if (url) return `url:${url}`;
  return `title:${input.title.trim().toLowerCase().replace(/\s+/g, ' ')}`;
}

function findingId(key: string): string {
  return crypto.createHash('sha256').update(key).digest('hex').slice(0, 12);
}

export function listFindings(agentId: string): DigestFinding[] {
  const file = findingsFile(agentId);
  if (!fs.existsSync(file)) return [];
  const out: DigestFinding[] = [];
  for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
    if (!line.trim()) continue;
    try {
      const parsed: unknown = JSON.parse(line);
      if (isFinding(parsed)) out.push(parsed);
    } catch {
      // Skip a corrupt line rather than losing the whole store.
    }
  }
  return out;
}

function isFinding(v: unknown): v is DigestFinding {
  if (typeof v !== 'object' || v === null) return false;
  const r = v as Record<string, unknown>;
  return (
    typeof r.id === 'string' &&
    typeof r.title === 'string' &&
    typeof r.foundAt === 'string' &&
    (r.tier === 'high' || r.tier === 'normal')
  );
}

/**
 * Add one finding to the agent's digest store. Dedupes by normalized URL
 * (falling back to normalized title when there is no URL) so a re-run of the
 * same research sweep does not stack duplicates.
 */
export function addFinding(agentId: string, input: FindingInput, now = new Date()): AddResult {
  const title = input.title.trim();
  if (!title) throw new Error('Finding title is required');
  const key = dedupeKey({ title, url: input.url });
  const id = findingId(key);

  const existing = listFindings(agentId).find((f) => f.id === id);
  if (existing) return { added: false, finding: existing, reason: 'duplicate' };

  const finding: DigestFinding = {
    id,
    title,
    url: input.url?.trim() || null,
    source: input.source?.trim() || null,
    summary: input.summary?.trim() || null,
    tier: input.tier ?? 'normal',
    foundAt: now.toISOString(),
  };
  fs.mkdirSync(digestDir(agentId), { recursive: true });
  fs.appendFileSync(findingsFile(agentId), JSON.stringify(finding) + '\n');
  return { added: true, finding };
}

// ── Digest artifact (the Bunker card) ───────────────────────────────────────

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

const FAVICON =
  'data:image/svg+xml,' +
  encodeURIComponent(
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><text y="13" font-size="13">&#128225;</text></svg>',
  );

/**
 * Render the standing digest page. Self-contained (no external requests),
 * theme-aware via prefers-color-scheme, no horizontal body scroll, and no
 * em/en dashes anywhere in the markup.
 */
export function renderDigestHtml(
  agentId: string,
  findings: DigestFinding[],
  now = new Date(),
): string {
  const title = digestTitle(agentId);
  const byNewest = [...findings].sort((a, b) => b.foundAt.localeCompare(a.foundAt));
  const days = new Map<string, DigestFinding[]>();
  for (const f of byNewest) {
    const day = f.foundAt.slice(0, 10);
    const bucket = days.get(day);
    if (bucket) bucket.push(f);
    else days.set(day, [f]);
  }
  const today = now.toISOString().slice(0, 10);
  const todayCount = days.get(today)?.length ?? 0;
  const highSignal = byNewest.filter((f) => f.tier === 'high');

  const item = (f: DigestFinding): string => {
    const t = escapeHtml(f.title);
    const heading = f.url
      ? `<a href="${escapeHtml(f.url)}" rel="noopener noreferrer" target="_blank">${t}</a>`
      : t;
    const badge = f.tier === 'high' ? '<span class="badge high">high signal</span>' : '';
    const source = f.source ? `<span class="src">${escapeHtml(f.source)}</span>` : '';
    const summary = f.summary ? `<p class="sum">${escapeHtml(f.summary)}</p>` : '';
    const time = escapeHtml(f.foundAt.slice(11, 16));
    return `<li><div class="row"><span class="time">${time}</span>${heading}${badge}${source}</div>${summary}</li>`;
  };

  const sections = [...days.entries()]
    .map(
      ([day, items]) =>
        `<section><h2>${escapeHtml(day)}${day === today ? ' (today)' : ''} <span class="count">${items.length}</span></h2><ul>${items.map(item).join('')}</ul></section>`,
    )
    .join('');

  const highBlock =
    highSignal.length > 0
      ? `<section class="highlights"><h2>High signal</h2><ul>${highSignal.slice(0, 10).map(item).join('')}</ul></section>`
      : '';

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escapeHtml(title)}</title>
<link rel="icon" href="${FAVICON}">
<style>
  :root { color-scheme: light dark;
    --bg: #f7f7f5; --fg: #1b1b1b; --muted: #6b6b6b; --card: #ffffff;
    --line: #e2e2de; --accent: #245c8d; --high-bg: #fff3d6; --high-fg: #7a5200; }
  @media (prefers-color-scheme: dark) { :root {
    --bg: #14161a; --fg: #e6e6e3; --muted: #9a9a95; --card: #1d2026;
    --line: #2c3038; --accent: #7fb3dd; --high-bg: #3a2f12; --high-fg: #e8c264; } }
  * { box-sizing: border-box; }
  body { margin: 0; padding: 1.25rem; background: var(--bg); color: var(--fg);
    font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    overflow-wrap: anywhere; }
  main { max-width: 46rem; margin: 0 auto; }
  h1 { font-size: 1.35rem; margin: 0 0 0.25rem; }
  .meta { color: var(--muted); font-size: 0.85rem; margin-bottom: 1.25rem; }
  section { background: var(--card); border: 1px solid var(--line);
    border-radius: 8px; padding: 0.75rem 1rem; margin-bottom: 1rem; }
  h2 { font-size: 0.95rem; margin: 0 0 0.5rem; }
  h2 .count { color: var(--muted); font-weight: normal; }
  ul { list-style: none; margin: 0; padding: 0; }
  li { padding: 0.4rem 0; border-top: 1px solid var(--line); }
  li:first-child { border-top: none; }
  .row { display: flex; flex-wrap: wrap; gap: 0.5rem; align-items: baseline; }
  .time { color: var(--muted); font-size: 0.8rem; font-variant-numeric: tabular-nums; }
  a { color: var(--accent); text-decoration: none; }
  a:hover { text-decoration: underline; }
  .badge.high { background: var(--high-bg); color: var(--high-fg);
    font-size: 0.7rem; padding: 0.1rem 0.4rem; border-radius: 4px; }
  .src { color: var(--muted); font-size: 0.8rem; }
  .sum { margin: 0.25rem 0 0; color: var(--muted); font-size: 0.85rem; }
  .empty { color: var(--muted); }
</style>
</head>
<body>
<main>
  <h1>${escapeHtml(title)}</h1>
  <p class="meta">${findings.length} item${findings.length === 1 ? '' : 's'} total, ${todayCount} today. Updated ${escapeHtml(now.toISOString().slice(0, 16).replace('T', ' '))} UTC.</p>
  ${highBlock}
  ${sections || '<section><p class="empty">No findings yet.</p></section>'}
</main>
</body>
</html>
`;
}

/**
 * Render the digest and write it into the Bunker at the stable per-agent slug,
 * refreshing the same card in place. The card is pinned by default so
 * sweepExpired never archives the durable link; an operator unpin is
 * preserved across refreshes (mirrors scripts/bunker-add.mjs --replace).
 */
export function publishDigest(agentId: string, now = new Date()): PublishResult {
  const slug = digestSlug(agentId);
  const dir = path.join(BUNKER_DIR, slug);
  const existed = fs.existsSync(dir);

  let prior: BunkerMeta = {};
  if (existed) {
    try {
      prior = JSON.parse(fs.readFileSync(path.join(dir, 'meta.json'), 'utf8')) as BunkerMeta;
    } catch {
      // Missing or corrupt meta: fall through to fresh defaults.
    }
  }

  const html = renderDigestHtml(agentId, listFindings(agentId), now);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'index.html'), html);
  const meta: BunkerMeta = {
    title: digestTitle(agentId),
    task: 'research-digest',
    tags: ['research', 'digest', safeAgentId(agentId)],
    created: prior.created ?? now.toISOString(),
    pinned: prior.pinned ?? true,
    ...(prior.promoted ? { promoted: prior.promoted } : {}),
  };
  fs.writeFileSync(path.join(dir, 'meta.json'), JSON.stringify(meta, null, 2));
  return { slug, dir, updated: existed };
}

// ── Daily rollup (the thin pointer) ─────────────────────────────────────────

function readState(agentId: string): DigestState {
  const file = stateFile(agentId);
  if (!fs.existsSync(file)) return {};
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8')) as DigestState;
  } catch {
    return {};
  }
}

function writeState(agentId: string, state: DigestState): void {
  fs.mkdirSync(digestDir(agentId), { recursive: true });
  fs.writeFileSync(stateFile(agentId), JSON.stringify(state, null, 2));
}

function digestPointer(agentId: string): string {
  const slug = digestSlug(agentId);
  const base = (process.env.DASHBOARD_URL || DASHBOARD_URL || '').replace(/\/+$/, '');
  return base
    ? `Digest: ${base} (Bunker tab, ${slug})`
    : `Digest: Mission Control, Bunker tab, ${slug}`;
}

/**
 * Build the one-line rollup covering everything since the last committed
 * rollup. Pure read: call commitRollup after the ping is actually sent so a
 * failed send does not swallow a day's findings.
 */
export function buildRollup(agentId: string, now = new Date()): Rollup {
  const since = readState(agentId).lastRollupAt ?? null;
  const nowIso = now.toISOString();
  const fresh = listFindings(agentId).filter(
    (f) => (since === null || f.foundAt > since) && f.foundAt <= nowIso,
  );
  const byNewest = [...fresh].sort((a, b) => b.foundAt.localeCompare(a.foundAt));
  const top = byNewest.find((f) => f.tier === 'high') ?? byNewest[0] ?? null;

  const pointer = digestPointer(agentId);
  const text =
    fresh.length === 0
      ? `Research digest: no new items since the last rollup. ${pointer}`
      : `Research digest: ${fresh.length} new item${fresh.length === 1 ? '' : 's'}. Top: ${top ? top.title : 'n/a'}. ${pointer}`;

  return { count: fresh.length, top, since, text };
}

/** Mark everything up to `at` as rolled up (the next rollup starts here). */
export function commitRollup(agentId: string, at = new Date()): void {
  const state = readState(agentId);
  state.lastRollupAt = at.toISOString();
  writeState(agentId, state);
}
