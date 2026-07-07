# Upstream ADAPT ledger

Upstream changes taken WITH modification. Each row: what upstream shipped,
what we changed, and why. Format per `docs/upstream-sync-runbook.md`.

| Sync date | File | Upstream change | Our modification | Why |
|---|---|---|---|---|
| 2026-07-06 | src/db.ts | `getMemoriesWithEmbeddings` gained shared-memory predicate `(agent_id = ? OR shared = 1)` | Kept upstream predicate AND kept our `topics` column in the SELECT list | Row-mapper needs `topics` (JSON.parse); the two sides changed different axes. Brings this fn in line with 4 sibling fns already using the predicate. |
| 2026-07-06 | src/dashboard.ts | New bunker/ACP handlers + `bindHost` normalization | Kept our XSS hardening (PR #52); took upstream's `.trim() \|\| '127.0.0.1'` bindHost | Loopback-default safety must hold regardless of config.ts resolution. No unescaped output sink introduced. |
| 2026-07-06 | src/index.ts | New boot step `resolveInstructionMd(CLAUDECLAW_CONFIG)` | Merged both: our hook-registry + bot wiring AND upstream's new boot step | Both symbols referenced downstream; take-both is forced by usage. |
| 2026-07-06 | src/config.ts | `DASHBOARD_BIND` gained `.trim()` | Kept `.trim()` form; removed the duplicate export the auto-merge left | Duplicate `export const DASHBOARD_BIND` would be a TS duplicate-identifier error. |
