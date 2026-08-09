import fs from 'fs';
import os from 'os';
import path from 'path';

import { afterEach, beforeEach, describe, expect, it } from 'vitest';

import { BUNKER_DIR, resolveArtifact, sweepExpired } from './bunker.js';
import {
  addFinding,
  buildRollup,
  commitRollup,
  digestSlug,
  digestTitle,
  listFindings,
  publishDigest,
  renderDigestHtml,
} from './research-digest.js';

// Real store, real bunker: DIGEST_DIR points at a fresh temp dir per test and
// BUNKER_DIR already lives inside the sandboxed CLAUDECLAW_CONFIG temp dir
// (src/test-env-setup.ts). Each test uses its own agent id so bunker slugs
// never collide across tests.

let tempDigestDir: string;
let agentSeq = 0;

function nextAgent(): string {
  agentSeq += 1;
  return `robtest${agentSeq}`;
}

beforeEach(() => {
  tempDigestDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ccos-digest-test-'));
  process.env.DIGEST_DIR = tempDigestDir;
});

afterEach(() => {
  delete process.env.DIGEST_DIR;
  fs.rmSync(tempDigestDir, { recursive: true, force: true });
});

describe('findings store', () => {
  it('adds a finding and reads it back', () => {
    const agent = nextAgent();
    const res = addFinding(agent, {
      title: 'Anthropic ships computer-use GA',
      url: 'https://example.com/a',
      source: 'research-api',
      summary: 'GA release of computer use.',
      tier: 'high',
    });
    expect(res.added).toBe(true);
    const all = listFindings(agent);
    expect(all).toHaveLength(1);
    expect(all[0].title).toBe('Anthropic ships computer-use GA');
    expect(all[0].tier).toBe('high');
    expect(all[0].url).toBe('https://example.com/a');
  });

  it('dedupes by URL, ignoring case and trailing slash', () => {
    const agent = nextAgent();
    expect(addFinding(agent, { title: 'First', url: 'https://Example.com/x/' }).added).toBe(true);
    const dup = addFinding(agent, { title: 'Retitled duplicate', url: 'https://example.com/x' });
    expect(dup.added).toBe(false);
    expect(dup.reason).toBe('duplicate');
    expect(listFindings(agent)).toHaveLength(1);
  });

  it('dedupes by normalized title when there is no URL', () => {
    const agent = nextAgent();
    expect(addFinding(agent, { title: 'Same   Thing' }).added).toBe(true);
    expect(addFinding(agent, { title: 'same thing' }).added).toBe(false);
    expect(listFindings(agent)).toHaveLength(1);
  });

  it('defaults tier to normal and rejects an empty title', () => {
    const agent = nextAgent();
    const res = addFinding(agent, { title: 'Untiered item' });
    expect(res.finding.tier).toBe('normal');
    expect(() => addFinding(agent, { title: '   ' })).toThrow(/title/i);
  });

  it('survives a corrupt line in the JSONL store', () => {
    const agent = nextAgent();
    addFinding(agent, { title: 'Good item' });
    fs.appendFileSync(path.join(tempDigestDir, agent, 'findings.jsonl'), 'not-json\n');
    addFinding(agent, { title: 'Second good item' });
    expect(listFindings(agent)).toHaveLength(2);
  });
});

describe('digest artifact (bunker card)', () => {
  it('publishes the digest into the bunker at the stable slug, pinned', () => {
    const agent = nextAgent();
    addFinding(agent, { title: 'Item one', url: 'https://example.com/1' });
    const pub = publishDigest(agent);

    expect(pub.slug).toBe(digestSlug(agent));
    expect(pub.updated).toBe(false);
    expect(fs.existsSync(path.join(BUNKER_DIR, pub.slug, 'index.html'))).toBe(true);

    const meta = JSON.parse(
      fs.readFileSync(path.join(BUNKER_DIR, pub.slug, 'meta.json'), 'utf8'),
    ) as { title: string; pinned: boolean };
    expect(meta.pinned).toBe(true);
    expect(meta.title).toBe(digestTitle(agent));
  });

  it('is served by the real bunker resolver (dashboard serving path)', () => {
    const agent = nextAgent();
    addFinding(agent, { title: 'Served item' });
    const pub = publishDigest(agent);
    const resolved = resolveArtifact(`${pub.slug}/index.html`);
    expect(resolved).not.toBeNull();
    expect(resolved?.contentType).toContain('text/html');
    expect(resolved?.data.toString('utf8')).toContain('Served item');
  });

  it('a second publish updates the same slug in place, preserving created', () => {
    const agent = nextAgent();
    addFinding(agent, { title: 'Original' });
    const first = publishDigest(agent, new Date('2026-07-01T08:00:00Z'));
    const metaPath = path.join(first.dir, 'meta.json');
    const createdBefore = (JSON.parse(fs.readFileSync(metaPath, 'utf8')) as { created: string })
      .created;

    addFinding(agent, { title: 'Follow-up' });
    const second = publishDigest(agent, new Date('2026-07-02T08:00:00Z'));

    expect(second.updated).toBe(true);
    expect(second.dir).toBe(first.dir);
    const metaAfter = JSON.parse(fs.readFileSync(metaPath, 'utf8')) as { created: string };
    expect(metaAfter.created).toBe(createdBefore);
    const slugs = fs
      .readdirSync(BUNKER_DIR)
      .filter((d) => d.startsWith(agent));
    expect(slugs).toEqual([first.slug]);
    expect(fs.readFileSync(path.join(first.dir, 'index.html'), 'utf8')).toContain('Follow-up');
  });

  it('preserves an operator unpin across refreshes', () => {
    const agent = nextAgent();
    addFinding(agent, { title: 'Item' });
    const pub = publishDigest(agent);
    const metaPath = path.join(pub.dir, 'meta.json');
    const meta = JSON.parse(fs.readFileSync(metaPath, 'utf8')) as { pinned: boolean };
    meta.pinned = false;
    fs.writeFileSync(metaPath, JSON.stringify(meta));

    publishDigest(agent);
    const after = JSON.parse(fs.readFileSync(metaPath, 'utf8')) as { pinned: boolean };
    expect(after.pinned).toBe(false);
  });

  it('pinned digest survives sweepExpired even when older than the expiry window', () => {
    const agent = nextAgent();
    addFinding(agent, { title: 'Old but pinned' });
    const pub = publishDigest(agent);
    const metaPath = path.join(pub.dir, 'meta.json');
    const meta = JSON.parse(fs.readFileSync(metaPath, 'utf8')) as { created: string };
    meta.created = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000).toISOString();
    fs.writeFileSync(metaPath, JSON.stringify({ ...meta, pinned: true }));

    const moved = sweepExpired();
    expect(moved).not.toContain(pub.slug);
    expect(fs.existsSync(pub.dir)).toBe(true);
  });
});

describe('rendered HTML', () => {
  it('escapes finding content (no raw script injection)', () => {
    const agent = nextAgent();
    addFinding(agent, { title: '<script>alert(1)</script>', summary: '<img src=x>' });
    const html = renderDigestHtml(agent, listFindings(agent));
    expect(html).not.toContain('<script>alert(1)</script>');
    expect(html).toContain('&lt;script&gt;');
    expect(html).not.toContain('<img src=x>');
  });

  it('honors the formatting bans: no em/en dashes, stable title, favicon, no external resources', () => {
    const agent = nextAgent();
    addFinding(agent, { title: 'A finding', url: 'https://example.com/f', tier: 'high' });
    const html = renderDigestHtml(agent, listFindings(agent));
    expect(html).not.toMatch(/[–—]/);
    expect(html).toContain(`<title>${digestTitle(agent)}</title>`);
    expect(html).toContain('<link rel="icon" href="data:image/svg+xml');
    // Self-contained: no scripts, no external stylesheets/fonts/images.
    expect(html).not.toContain('<script');
    expect(html).not.toMatch(/<link[^>]+href="https?:/);
    expect(html).not.toMatch(/src="https?:/);
  });

  it('groups findings by day and surfaces high-signal items', () => {
    const agent = nextAgent();
    addFinding(agent, { title: 'Yesterday item' }, new Date('2026-07-08T09:00:00Z'));
    addFinding(agent, { title: 'Today high item', tier: 'high' }, new Date('2026-07-09T10:00:00Z'));
    const html = renderDigestHtml(agent, listFindings(agent), new Date('2026-07-09T18:00:00Z'));
    expect(html).toContain('2026-07-08');
    expect(html).toContain('2026-07-09 (today)');
    expect(html).toContain('High signal');
    expect(html).toContain('2 items total, 1 today');
  });
});

describe('daily rollup', () => {
  it('counts everything on the first rollup and prefers a high-tier top item', () => {
    const agent = nextAgent();
    addFinding(agent, { title: 'Normal one' }, new Date('2026-07-09T08:00:00Z'));
    addFinding(agent, { title: 'Big high-signal move', tier: 'high' }, new Date('2026-07-09T09:00:00Z'));
    addFinding(agent, { title: 'Normal two' }, new Date('2026-07-09T10:00:00Z'));

    const rollup = buildRollup(agent, new Date('2026-07-09T18:00:00Z'));
    expect(rollup.count).toBe(3);
    expect(rollup.since).toBeNull();
    expect(rollup.top?.title).toBe('Big high-signal move');
    expect(rollup.text).toContain('3 new items');
    expect(rollup.text).toContain('Top: Big high-signal move');
    expect(rollup.text).toContain(digestSlug(agent));
  });

  it('falls back to the most recent item when nothing is high tier', () => {
    const agent = nextAgent();
    addFinding(agent, { title: 'Older' }, new Date('2026-07-09T08:00:00Z'));
    addFinding(agent, { title: 'Newest' }, new Date('2026-07-09T11:00:00Z'));
    const rollup = buildRollup(agent, new Date('2026-07-09T18:00:00Z'));
    expect(rollup.top?.title).toBe('Newest');
  });

  it('does not double-count after a committed rollup (no duplicate pings)', () => {
    const agent = nextAgent();
    addFinding(agent, { title: 'Day one item' }, new Date('2026-07-09T08:00:00Z'));
    expect(buildRollup(agent, new Date('2026-07-09T18:00:00Z')).count).toBe(1);
    commitRollup(agent, new Date('2026-07-09T18:00:00Z'));

    const again = buildRollup(agent, new Date('2026-07-09T18:05:00Z'));
    expect(again.count).toBe(0);
    expect(again.text).toContain('no new items');

    addFinding(agent, { title: 'Day two item' }, new Date('2026-07-10T08:00:00Z'));
    const nextDay = buildRollup(agent, new Date('2026-07-10T18:00:00Z'));
    expect(nextDay.count).toBe(1);
    expect(nextDay.top?.title).toBe('Day two item');
  });

  it('an uncommitted rollup keeps its findings for the next attempt (failed send safety)', () => {
    const agent = nextAgent();
    addFinding(agent, { title: 'Must not be lost' }, new Date('2026-07-09T08:00:00Z'));
    expect(buildRollup(agent, new Date('2026-07-09T18:00:00Z')).count).toBe(1);
    // No commit: a retry still sees the finding.
    expect(buildRollup(agent, new Date('2026-07-09T19:00:00Z')).count).toBe(1);
  });

  it('points at the dashboard URL when configured', () => {
    const agent = nextAgent();
    const prior = process.env.DASHBOARD_URL;
    process.env.DASHBOARD_URL = 'https://ccos.example.dev/';
    try {
      addFinding(agent, { title: 'Linked item' });
      const rollup = buildRollup(agent);
      // Trailing slash stripped, pointer names the Bunker tab and the slug.
      expect(rollup.text).toContain('https://ccos.example.dev (Bunker tab');
      expect(rollup.text).toContain(digestSlug(agent));
    } finally {
      if (prior === undefined) delete process.env.DASHBOARD_URL;
      else process.env.DASHBOARD_URL = prior;
    }
  });
});
