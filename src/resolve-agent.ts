import { resolveAgentId, knownAgentIds } from './agent-config.js';

/**
 * Resolve a CLI `--agent` reference (canonical id, display name, or alias) to
 * its canonical id for a write path. On an unknown agent, print a
 * self-diagnosing error naming the offending input and the known agents, then
 * exit non-zero so **nothing is written** — no dead letters, ever.
 *
 * This is the CLI-side counterpart to the resolve-then-store wiring: the value
 * that reaches the database is always a canonical id the pollers match.
 */
export function resolveAgentOrExit(input: string): string {
  const id = resolveAgentId(input);
  if (id === null) {
    console.error(`unknown agent '${input}' — known: ${knownAgentIds().join(', ')}`);
    process.exit(1);
  }
  return id;
}
