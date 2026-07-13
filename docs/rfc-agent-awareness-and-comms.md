---
Author: Michael Kidder
Title: Agent Awareness & Deterministic Comms
Status: Draft — Tier 1 built (feat/agent-self-location); tracked via GH issue
Created: 2026-07-12
Component: setup / config generation / mission-cli / hive accessor / docs
---

# Agent Awareness & Deterministic Comms

## Summary

Two fundamental gaps, one theme: **agents should know less and rely on the system more.** Today a
fresh agent doesn't reliably know where its own store lives, and inter-agent routing depends on the
sending model guessing the right recipient. Both push judgment onto the model, and judgment drifts.
This RFC makes both properties of the runtime/CLIs instead of the prompt:

- **Tier 1 — Self-location:** every agent knows, from setup, its identity, config path, and resolved
  store path, and uses a **store-aware accessor** to touch its hive mind (never a raw sqlite path).
- **Tier 2 — Deterministic comms:** a handback resolves to the task's originator (`created_by`), so an
  agent only needs to know "reply to whoever queued me." New-work routing is validated by a CLI
  owner-lane map, not carried in any agent's head.

Net effect: behavior is deterministic and **model-independent**, which is exactly what we need as
non-Claude/untrusted models (e.g. GPT via proxy) get put in the seat.

## Motivation

Two live findings on 2026-07-12, both verified from source:

1. **Agents don't know their own store.** A relocated sandbox agent (store pinned in its **`.env`**,
   not the process env) still surfaced the **live** fleet hive mind — because it had no documented way
   to read its own store, so it improvised a raw `sqlite3` call and found the main DB by absolute path.
   On Claude/opus with no proxy: structural, not a GPT quirk.
   - Root cause A: the shipped main template (`CLAUDE.md.example`) has **zero** hive-mind or
     self-location awareness (`CLAUDECLAW_STORE`/`STORE_DIR`/`CLAUDECLAW_CONFIG`/`agent-common` refs = 0).
     Never shipped — the live fleet only has it via hand-curated `~/.claudeclaw-os`. So **every fresh
     install** ships agents blind to their own store.
   - Root cause B (the strong one): `config.ts` (L133) resolves the store as
     `process.env.CLAUDECLAW_STORE_DIR || envConfig.CLAUDECLAW_STORE_DIR || PROJECT_ROOT/store`. In this
     env the pin lives in **`.env` (the `envConfig` branch), not a process env var** — so a raw `bash`
     `sqlite3`/`find` call **cannot see the pin at all**; only a Node process that loads `config.ts`
     can. The sanctioned how-to compounds it by hardcoding `sqlite3 "$PROJECT_ROOT/store/claudeclaw.db"`.
     So the real indictment isn't "the doc hardcodes a build-relative path" — it's that **bash has no
     access to the resolution logic, period.** That is the single strongest argument for a `hive-cli`:
     only a Node accessor can honor the `.env`-based pin. Any shell command is blind to it by
     construction.

2. **Routing depends on the sender guessing.** In the Skool-scraper incident, the fix's re-run was
   dispatched to Amos (wrong lane); Amos noticed and re-routed to Naomi. It self-corrected, but only
   because an agent caught another agent's mistake. The originating error was a model picking the
   wrong recipient from memory.

## Design

### Tier 1 — Self-location

- **Store-aware `hive-cli` (canonical accessor).** A small CLI (read/write) that **imports
  `config.ts`'s `STORE_DIR`** — including the `envConfig` (`.env`) branch — NOT a re-derivation from
  `process.env`. This is load-bearing: if it only read `process.env` it would reproduce the exact bug
  in every agent bash shell that lacks the var (which is all of them here). It also exposes
  **`hive-cli path`** to print its resolved DB. Docs/templates point agents at `hive-cli`, never a raw
  `sqlite3 $PROJECT_ROOT/store` string. Kills the improvise-and-hunt behavior: only a Node accessor can
  honor the `.env` pin, so agents stop shell-searching for a `.db` and can't accidentally hit the live
  store.
- **Setup stamps self-awareness (informational only).** Setup writes agent id + display name,
  `CLAUDECLAW_CONFIG`, and the resolved store path into the generated CLAUDE.md — but **the stamped path
  is a hint, not the source of truth.** A stamped path is a static snapshot that goes stale the moment
  anyone relocates the store; if agents trusted it we'd have just swapped one hardcoded path for another
  in a nicer file. The **canonical** answer is always `hive-cli path` / the accessor. The CLAUDE.md line
  says as much ("for reference; run `hive-cli path` for the live value"). Ship in `CLAUDE.md.example`
  (main) and align `agents/_template` (sub-agents already carry hive_mind refs) to the accessor.
- **Fix `agent-common.md`** to reference `hive-cli` instead of the build-relative sqlite command; ship
  it (or its substance) so fresh installs get the how-to, not just the hand-curated live config.
- **Template hygiene (from the 2026-07-12 self-diagnosis).** The loaded template still carried
  unedited bracket placeholders (`Michael [does what you do]`) and **install-time scaffolding** —
  "Copy to `~/.claudeclaw-os/agents/main/CLAUDE.md`", "the always-on claudeclaw-os runtime" — which the
  agent read as *runtime fact* and used to infer the production path. Keep install/copy instructions
  **out of the runtime-loaded file** (they belong in setup docs/README), and make setup **enforce
  placeholder replacement**. Combined with a shared `$HOME` (`~/.claudeclaw-os` exists at
  `/c/Users/mikek`) and leaked env like `GEMINI_CLI_IDE_WORKSPACE_PATH` pointing at production, those
  strings are active misdirection, not inert.

### Tier 2 — Deterministic comms

- **Handback resolves to `created_by`.** Add `mission-cli handback <task-id> "<report>"`: recipient is
  the task's originator, looked up from the row — the agent supplies no agent id. Store `parent_task_id`
  for the chain. **`created_by` is not always an agent — the resolution table must be explicit or
  automated handbacks dead-end:**
  | `created_by` | Handback destination |
  |---|---|
  | an agent id (holden/naomi/amos/…) | that agent's mission board |
  | `human` / a Mike chat id | Mike on Telegram |
  | `dashboard` (the default origin) | Mike on Telegram (dashboard has no inbox to consume a mission) |
  | `scheduled` / cron-origin | the job's **owning** agent (via the lane/owner it was created under); fall back to Mike if unattributable |
  Pin this mapping in code; a `dashboard`- or `scheduled`-origin handback with no rule is the failure
  case to eliminate.
- **Owner-validated dispatch.** A committed owner-lane map (feed/Skool→naomi, code→holden, Jira→amos,
  billing→alex, knowledge/Obsidian→drummer). `mission-cli create` auto-routes by `--lane` when
  `--assign` is omitted, and rejects (or warns+`--force`) a mismatch. The agent doesn't carry the map.

### What each agent must "know" (the whole point)

- **Self:** who I am, where my config + store are, and `hive-cli` to reach my hive mind.
- **Callback:** results go back to whoever queued me (system resolves it).
- Nothing about the org chart. Routing lives in the CLI.

## Containment (scoped OUT here → next RFC, and it is a NEAR-term priority, not someday)

This RFC removes the **accidental** footgun. It does **not** close the hole, and the hole is proven,
not theoretical (verified 2026-07-12):
- Production's ~31MB live DB is **writable** by this sandbox agent.
- **Six** `claudeclaw.db` files are reachable under the same OS user.
- `agent.ts` runs `permissionMode: 'bypassPermissions'` + `settingSources: ['user']`, so a project
  `.claude/settings.json` deny-rule is **ignored**. A curious or untrusted model with Bash
  absolute-paths straight to the live store — read *and* write.

Self-location + `hive-cli` stop the well-behaved agent from *stumbling* onto it; nothing here stops a
model that *chooses* to. The only real fix is **OS-level isolation** (separate user / WSL / container),
optionally plus a permission-mode code change. That belongs in its own RFC — **prioritized, not
deferred**: the moment a non-Claude model sits in this seat, a writable production DB reachable by
absolute path is the whole ballgame. Do not run an untrusted provider in this seat until that RFC lands.

## Implementation surface

- new `src/hive-cli.ts` (+ `dist`) — **imports `config.ts` `STORE_DIR`** (incl. `.env`/`envConfig`
  branch), not a `process.env` re-derivation; adds `hive-cli path` (print resolved DB) + read/write.
- `CLAUDE.md.example` — add self-location + `hive-cli` usage (main agent); **strip install/copy
  scaffolding** ("Copy to ~/.claudeclaw-os…", "always-on runtime") out of the runtime-loaded file.
- `agents/_template/CLAUDE.md` — align to `hive-cli`; same scaffolding strip.
- `scripts/setup.ts` (~L893–952) — stamp resolved config/store paths as **informational** (point to
  `hive-cli path` as canonical); **enforce placeholder replacement** (no `[YOUR NAME]`/`Michael [does
  what you do]` left in a generated config); ship/point-to `agent-common.md`.
- `src/mission-cli.ts` — `handback` subcommand resolving `created_by` per the resolution table
  (agent/human/dashboard/scheduled); `--lane` + owner-map validation.
- `mission_tasks` schema — add `parent_task_id`, `lane`.
- owner-lane map — committed config (e.g. `config/agent-lanes.json`).
- `~/.claudeclaw-os/docs/agent-common.md` (and shipped copy) — replace raw sqlite with `hive-cli`.
- sandbox launch hygiene — scrub production-pointing env (`GEMINI_CLI_IDE_WORKSPACE_PATH`, etc.) so
  they can't seed the wrong path (belongs to the containment RFC but note the vector here).
- Tests per repo standard (append to existing *.test.ts).

## Out of scope

- OS-level untrusted-provider containment (separate RFC).
- Agent identity/display-name reconciliation (separate, existing RFC).

## Rollout

Tracked via a GitHub issue (the paper trail); code PRs reference it with `Closes #`. This RFC lands in
`docs/` on `main`. Build the fix on a clean clone → PR per tier. One-concern discipline: split Tier 1
(self-location) and Tier 2 (deterministic comms) into two PRs, Tier 1 first (it's the fundamental fix
and unblocks the sandbox work).

---

> **Holden's analysis.** The through-line is that our agents currently have to *figure out* things
> that should be givens — where their own data lives, and who to talk to. Every time we lean on the
> model to remember, we inherit its drift, and that drift is worse the less we trust the model. The
> 2026-07-12 sandbox test made this concrete: a store-relocated agent still read the live hive mind on
> plain Claude, because "read your hive mind" wasn't a capability it had, it was a puzzle it solved
> with a raw sqlite call. Verified in source that the main template never shipped self-location or
> hive awareness — so this isn't a regression to restore, it's a fundamental gap to close, and it hits
> every install, not just this sandbox. Tier 1 is the one I'd build first: give agents a correct,
> store-aware accessor and tell them where they live, and the whole class of "hunt the filesystem for a
> db" behavior disappears — which also quietly shrinks the data-egress surface before we ever layer a
> non-Claude model on top. Tier 2 then makes the fleet's comms deterministic so autonomy scales without
> agents needing to memorize the org chart. — Holden
