# Upstream DROP ledger (reject ledger)

Upstream changes we REJECTED, with reason (security / scope / tenancy /
breaks-our-patch). Format per `docs/upstream-sync-runbook.md`.

| Sync date | Upstream commit / change | Reason class | Detail |
|---|---|---|---|

## 2026-07-06 sync (b414b7b..a5accd5, 62 commits)

No upstream commits were dropped in this sync. All 62 commits were ADOPTed
(taken as-is) or ADAPTed (see `docs/upstream-modified.md`). The 5 file
conflicts were resolved by combining both sides, not by rejecting upstream
capability.

Note: 10 pre-existing production dependency vulnerabilities (1 critical, 5
high) were inherited unchanged from before this sync (ws@8.19.0 identical on
old main). These are NOT a DROP - they are tracked for separate breaking-change
remediation, not rejected upstream content.
