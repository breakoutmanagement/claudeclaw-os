# Upstream sync log

One entry per sync run (newest first). Format per docs/upstream-sync-runbook.md.

## 2026-07-27 - v1.7.1 (PR #19)

- Upstream range: 8e532d9..887f820 (22 commits, releases 1.5.0 -> 1.7.1)
- Source: vendor token-server reclone (GitHub upstream earlyaidopters/claudeclaw-os went private; git-fetch sync path is dead - all 4 org accounts get 404)
- Also merged: box-local lineage from ts-cc-os-vanilla (f6fb28d: baseline customizations c29a6c8 + live config drift), previously never pushed
- Conflicts: 11 files box-vs-fork, 5 vendor-vs-ours; resolved per runbook defaults
- Decisions: ADOPT security batch #165 wholesale (log-redact, exfil guard, WarRoom localhost bind, fail-closed migrations); DEFER vendor messenger.ts boot refactor (lands in-tree unreferenced - our src/index.ts boot sequence kept, hook-registry wiring preserved); ADOPT gemini-2.5-flash over box's undocumented gemini-3.5-flash (verify); box branches archived under box/* on the fork
- Gate: typecheck clean, 848/853 tests pass local (node 24) AND on-host pre-swap gate green
- Deployed: ts-cc-os-vanilla 2026-07-27 via deploy/update.sh rename-swap; smoke 10/11 pass (11th is issue #20, a smoke-script loopback-probe bug - dashboard verified 200 on its bound tailnet IP)
- Follow-ups: issue #20 (smoke probe); messenger.ts adoption; gemini model id verification
