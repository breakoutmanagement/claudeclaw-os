# Slice 002 — Filter ACP lifecycle noise from Telegram progress

**Status**: implemented (fork) — ready for courtesy upstream PR
**Filed by**: Breakout Audit / [agent:main]
**Date**: 2026-06-20
**Repo**: fork of earlyaidopters/claudeclaw-os
**Strategy**: Path B — patch local fork, open courtesy PR upstream
**Estimate**: XS (one function + tests + boundary change in `bot.ts`)

## Problem

When an agent uses an ACP provider (OpenCode, Gemini CLI, Codex, or a custom
binary like `grok agent stdio`), every turn emits `task_started` progress events
for internal lifecycle steps:

- `acp model set to grok-composer-2.5-fast`
- `acp session started`

`bot.ts` forwards **all** `task_started` events to Telegram as `🔄 {description}`
messages. Users on Telegram see two spurious notifications before the actual
reply on every message. The dashboard SSE stream (`emitChatEvent`) is the right
place for these events; Telegram is not.

This is especially noticeable with Grok subscription via ACP because every turn
creates a fresh session.

## Root cause

`src/agent-engine/acp-adapter.ts` correctly surfaces lifecycle as progress for
observability. `src/bot.ts` treats every `task_started` as user-facing Telegram
progress with no filtering.

Claude SDK adapters emit different `task_started` descriptions (sub-agent work,
plans) that *are* meaningful in Telegram. The fix must be surgical: filter only
provider lifecycle strings, not all `task_started` events.

## Solution

Add `isProviderLifecycleNoise(description)` in `src/bot.ts`:

```ts
export function isProviderLifecycleNoise(description: string | undefined): boolean {
  const desc = description ?? '';
  return / model set to /.test(desc) || /session started$/.test(desc);
}
```

In the Telegram `onProgress` handler, keep `emitChatEvent` for all
`task_started` events (dashboard still sees them) but skip `ctx.reply` when
`isProviderLifecycleNoise` returns true.

## Files changed

| File | Change |
|------|--------|
| `src/bot.ts` | Add `isProviderLifecycleNoise`, gate Telegram reply |
| `src/bot.test.ts` | Unit tests for lifecycle vs meaningful descriptions |

## Tests

```bash
npm test -- src/bot.test.ts
```

Covers:
- `acp model set to …` / `opencode model set to …` → filtered
- `acp session started` / `gemini session started` → filtered
- `Researching buyer dossier`, `Running sub-agent: comms` → not filtered
- `undefined` / empty → not filtered

## Upstream PR checklist

- [ ] Rebase onto latest `earlyaidopters/claudeclaw-os` main
- [ ] Confirm `acp-adapter.ts` lifecycle strings unchanged (grep `model set to`, `session started`)
- [ ] Run `npm test -- src/bot.test.ts`
- [ ] PR title: `fix(bot): stop forwarding ACP lifecycle noise to Telegram`
- [ ] PR body: link this slice, note dashboard SSE unaffected

## Related

- `docs/admin/grok-xai-subscription-setup.md` — Grok via ACP; users hit this noise immediately after switching providers
- Slice 001 (memory policy) — same Path B courtesy-PR workflow

## Follow-up (separate PR)

Systemd/launchd service generators (`agent-create.ts`, `scripts/setup.ts`,
`scripts/agent-service.sh`) do not include `~/.local/bin` in `PATH`. ACP
providers installed via pip/cargo/npm user installs fail with `ENOENT` unless
the admin uses an absolute command path. Recommend a shared `buildDaemonPath()`
helper — documented in the Grok admin guide as a manual workaround today.
