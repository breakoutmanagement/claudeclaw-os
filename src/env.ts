import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

/**
 * Find the .env file by checking cwd first, then the project root
 * (derived from __dirname which is dist/ in the compiled output).
 * This ensures agent subprocesses that run with a different cwd
 * (e.g. agents/product-owner/) can still find the root .env.
 */
function findEnvFile(): string | null {
  // 1. Check cwd (original behaviour)
  const cwdEnv = path.join(process.cwd(), '.env');
  if (fs.existsSync(cwdEnv)) return cwdEnv;

  // 2. Check project root via __dirname (dist/env.js -> project root)
  const rootEnv = path.resolve(__dirname, '..', '.env');
  if (fs.existsSync(rootEnv)) return rootEnv;

  // 3. Walk up from cwd looking for .env (handles nested agent dirs)
  let dir = process.cwd();
  for (let i = 0; i < 5; i++) {
    const parent = path.dirname(dir);
    if (parent === dir) break;
    dir = parent;
    const candidate = path.join(dir, '.env');
    if (fs.existsSync(candidate)) return candidate;
  }

  return null;
}

/**
 * Parse the .env file and return values for the requested keys.
 * Does NOT load anything into process.env — callers decide what to
 * do with the values. This keeps secrets out of the process environment
 * so they don't leak to child processes.
 */
export function readEnvFile(keys: string[]): Record<string, string> {
  const envFile = findEnvFile();
  if (!envFile) return {};

  let content: string;
  try {
    content = fs.readFileSync(envFile, 'utf-8');
  } catch {
    return {};
  }

  const result: Record<string, string> = {};
  const wanted = new Set(keys);

  for (const line of content.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const eqIdx = trimmed.indexOf('=');
    if (eqIdx === -1) continue;
    const key = trimmed.slice(0, eqIdx).trim();
    if (!wanted.has(key)) continue;
    let value = trimmed.slice(eqIdx + 1).trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    if (value) result[key] = value;
  }

  return result;
}
