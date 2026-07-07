# Upstream sync log

One entry per sync of `earlyaidopters/claudeclaw-os` (upstream) into
`breakoutmanagement/claudeclaw-os` (our fork). Format per the wrapper
runbook `docs/upstream-sync-runbook.md`.

| Date | Upstream range | Commits | Merge commit | Conflicts resolved | Node | Gate | Notes |
|---|---|---|---|---|---|---|---|
| 2026-05-18 | ..(prior) | - | 265a6a5 | - | - | - | prior sync (pre-ledger) |
| 2026-07-06 | b414b7b..a5accd5 | 62 | a37bb34 | 5 (db, dashboard, index, config, package-lock) | .nvmrc 22->24; engines >=22 <25 | typecheck 0 err, build EXIT 0 (local Node 24); tests+sqlite on host | 48 days of drift closed (past 14-day budget). 10 pre-existing prod vulns unchanged, tracked separately. Host confirmed Node 24.15.0 / better-sqlite3 11.10.0 prebuilt loads. |

## Drift budget

Runbook target: never more than 14 days behind upstream without a recorded
reason. The 2026-07-06 sync closed a 48-day gap (last sync 2026-05-18). Reason
for the gap: no local fork checkout existed; the sync clone had to be
re-established this session.
