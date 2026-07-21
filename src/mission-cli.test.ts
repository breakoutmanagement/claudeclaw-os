import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { execSync } from 'child_process';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { fileURLToPath } from 'url';
import yaml from 'js-yaml';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const CLI_PATH = path.resolve(__dirname, '..', 'dist', 'mission-cli.js');
const PROJECT_DIR = path.resolve(__dirname, '..');

// The CLI runs as a child process and loads real config, which requires a
// DB_ENCRYPTION_KEY (>= 32 chars). Inject a throwaway key so these tests are
// hermetic and independent of any .env. Each test points CLAUDECLAW_CONFIG and
// CLAUDECLAW_STORE_DIR at fresh temp dirs so nothing ever touches the live
// fleet's config or database.
const TEST_DB_KEY = 'a'.repeat(64);

let tmpRoot: string;
let cfgDir: string;
let storeDir: string;

function seedAgent(id: string, cfg: Record<string, unknown>) {
  const dir = path.join(cfgDir, 'agents', id);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'agent.yaml'), yaml.dump(cfg), 'utf-8');
}

function childEnv(): Record<string, string | undefined> {
  return {
    ...process.env,
    DB_ENCRYPTION_KEY: TEST_DB_KEY,
    CLAUDECLAW_CONFIG: cfgDir,
    CLAUDECLAW_STORE_DIR: storeDir,
    CLAUDECLAW_AGENT_ID: undefined,
  };
}

interface RunResult { status: number; stdout: string; stderr: string; }

function run(args: string): RunResult {
  try {
    const stdout = execSync(`node "${CLI_PATH}" ${args}`, {
      cwd: PROJECT_DIR,
      env: childEnv(),
      encoding: 'utf-8',
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    return { status: 0, stdout, stderr: '' };
  } catch (err) {
    const e = err as { status?: number; stdout?: string; stderr?: string };
    return { status: e.status ?? 1, stdout: e.stdout ?? '', stderr: e.stderr ?? '' };
  }
}

describe('mission-cli create — resolve-then-store guard', () => {
  beforeEach(() => {
    tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'claudeclaw-mission-cli-'));
    cfgDir = path.join(tmpRoot, 'config');
    storeDir = path.join(tmpRoot, 'store');
    fs.mkdirSync(cfgDir, { recursive: true });
    fs.mkdirSync(storeDir, { recursive: true });
    // Roster where canonical id != display name (mirrors the live fleet).
    seedAgent('main', { name: 'Holden', description: 'hub' });
    seedAgent('amos', {
      name: 'Amos',
      description: 'ops',
      telegram_bot_token_env: 'TEST_BOT_TOKEN',
    });
  });

  afterEach(() => {
    fs.rmSync(tmpRoot, { recursive: true, force: true });
  });

  it('resolves a display name to the canonical id (regression for fdfec14a)', () => {
    const created = run('create --agent holden --title "Handback" "do the thing"');
    expect(created.status).toBe(0);
    expect(created.stdout).toMatch(/Agent:\s+main/);

    // Read back through the CLI: the stored assigned_agent is the canonical id,
    // so a poller's WHERE assigned_agent = 'main' will claim it (no dead letter).
    const listed = run('list --status queued');
    expect(listed.stdout).toContain('@main');
    expect(listed.stdout).not.toContain('@holden');
  });

  it('rejects an unknown agent: non-zero exit, known-list, writes nothing', () => {
    const created = run('create --agent bogus --title "X" "prompt"');
    expect(created.status).not.toBe(0);
    expect(created.stderr).toContain("unknown agent 'bogus'");
    expect(created.stderr).toContain('known:');
    expect(created.stderr).toContain('main');

    // Nothing was written.
    const listed = run('list');
    expect(listed.stdout).toContain('No mission tasks');
  });

  it('leaves the task unassigned when --agent is omitted', () => {
    const created = run('create --title "later" "assign me on the dashboard"');
    expect(created.status).toBe(0);
    expect(created.stdout).toContain('unassigned');
  });
});
