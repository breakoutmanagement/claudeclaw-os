# Admin Guide: Configuring ClaudeClaw Agents with xAI Grok Subscription

This guide explains how to connect ClaudeClaw agents to the **xAI Grok subscription** (via the local `grok` CLI) instead of the xAI billing / pay-per-token API.

**Goal**: Use the same authenticated Grok subscription you use in the web/app/chat (via `grok login --oauth`), not a separate API key that incurs billing.

## Prerequisites

- `grok` CLI installed and working on the host (the same machine running ClaudeClaw).
- You have run `grok login --oauth` (or equivalent) and are authenticated with your Grok subscription.
- ClaudeClaw is installed and at least the main bot is running.
- `ENABLE_ACP=true` in your `.env` (required for any non-Claude provider).

Verify subscription access first:

```bash
grok inspect
grok models
```

You should see output like "You are logged in with grok.com." and available models (e.g. `grok-composer-2.5-fast`, `grok-build`).

## Core Concept: Custom ACP Provider

ClaudeClaw talks to alternative model providers using the **Agent Client Protocol (ACP)** over stdio.

The `grok` CLI supports this mode with:

```bash
grok --always-approve agent stdio
```

ClaudeClaw is configured to launch this as a child process and communicate with it.

**Important distinction**:
- **Subscription path** (this guide): `grok` binary + OAuth login. No xAI API key in `.env`.
- **Billing API path**: OpenCode (or custom OpenAI-compatible) pointed at `https://api.x.ai/v1` with an API key. Avoid this if you want to use your existing subscription quota.

## Step-by-Step: Configure the Main Agent (@ccosvanillabot)

The main bot uses two configuration sources:

1. `store/main-config.json` (primary for main provider)
2. `~/.claudeclaw/agents/main/agent.yaml` (for consistency + CLAUDE.md location)

### 1. Enable ACP

In `.env`:

```env
ENABLE_ACP=true
```

### 2. Edit store/main-config.json

Create or replace with:

```json
{
  "provider": {
    "type": "acp",
    "command": "/home/YOURUSER/.local/bin/grok",
    "args": ["--always-approve", "agent", "stdio"],
    "dangerouslySkipPermissions": true
  }
}
```

**Use the absolute path** to the `grok` binary (see Gotchas below).

### 3. Edit the main agent config (recommended)

`~/.claudeclaw/agents/main/agent.yaml`:

```yaml
name: Main
description: General-purpose assistant

telegram_bot_token_env: TELEGRAM_BOT_TOKEN

provider:
  type: acp
  command: /home/YOURUSER/.local/bin/grok
  args: ["--always-approve", "agent", "stdio"]
  dangerouslySkipPermissions: true
```

### 4. Fix the Service PATH (Critical for systemd)

The ClaudeClaw main process usually runs as a systemd user service.

Edit the unit file:

```bash
~/.config/systemd/user/com.claudeclaw.agent-main.service
```

Ensure the `Environment=PATH` line includes `~/.local/bin`:

```ini
Environment=PATH=/home/YOURUSER/.local/bin:/home/YOURUSER/bin:/home/YOURUSER/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
```

Then reload:

```bash
systemctl --user daemon-reload
systemctl --user restart com.claudeclaw.agent-main
```

### 5. Restart and Reset Session

```bash
systemctl --user restart com.claudeclaw.agent-main
```

In Telegram (to @ccosvanillabot):

```
/newchat
```

This forces a fresh ACP session with the new provider.

### 6. Verify

Send a test message:

```
What backend are you using right now? Run a simple tool command (e.g. echo a string) and confirm.
```

You should see responses from the Grok subscription CLI.

Check logs:

```bash
tail -f store/agent-main.log | grep -E 'ACP|grok|sessionId|tool_call'
```

You should see session creation and tool activity, **not** "could not be started".

Run the status script:

```bash
npm run status
```

It should report something like:

```
Agent provider: ACP (/home/.../grok --always-approve agent stdio)
```

## Configuring Other / Specialist Agents

Each agent in `~/.claudeclaw/agents/<id>/agent.yaml` (or the repo `agents/<id>/`) can have its own provider.

Example for a research or dev agent:

```yaml
name: Research
description: ...

telegram_bot_token_env: RESEARCH_BOT_TOKEN

provider:
  type: acp
  command: /home/YOURUSER/.local/bin/grok
  args: ["--always-approve", "agent", "stdio"]
  dangerouslySkipPermissions: true
```

Then restart that agent:

```bash
# If using separate units
systemctl --user restart com.claudeclaw.agent-research

# Or via the dashboard Agents tab (Stop / Start)
```

You can mix providers (some agents on Grok subscription, others on Claude or OpenCode).

## Using the Dashboard to Change Providers

1. Send `/dashboard` to the main bot.
2. Go to the Agents tab.
3. Click the agent card → look for Provider settings.
4. Select "Custom ACP".
5. Command: full path to `grok`
6. Args: `--always-approve agent stdio`
7. Check "dangerously skip permissions".
8. Save and restart the agent.

The dashboard writes to the same JSON / YAML files.

## Gotchas and What We Did Wrong Initially

This section documents the exact mistakes made during the first attempts. Future admins should avoid these.

### 1. Wrong Provider Type (OpenCode vs Direct grok)
**Mistake**: Started by switching to `type: opencode` and trying to configure Grok inside OpenCode.

**Why it was wrong**: OpenCode is for bringing your own *API keys* (OpenAI-compatible, Anthropic, etc.). It is the **billing API path**.

**Correct**: Use `type: acp` with the `grok` binary directly. The subscription auth lives in the `grok` CLI (`grok login`), not in OpenCode or `.env`.

### 2. Relative Command Name Instead of Absolute Path
**Mistake**: Used `"command": "grok"` (or just `grok` in YAML).

**Why it failed**: The systemd user service has a very restricted `PATH` that does **not** include `~/.local/bin` by default. `spawn("grok", ...)` produced `ENOENT`.

**Symptom**: Repeated "ACP provider command `grok` could not be started. Make sure it is installed and available on PATH for the ClaudeClaw service."

**Fix**: Always use the full absolute path in the config:
```json
"command": "/home/YOURUSER/.local/bin/grok"
```

The symlink at `~/.local/bin/grok` is stable.

### 3. Did Not Update the systemd Unit PATH
**Mistake**: Only changed the ClaudeClaw config, never touched the service file.

**Result**: Even with absolute paths in some places, other tools or future relative commands would break.

**Fix**: Explicitly add `~/.local/bin` to the `Environment=PATH` line and `daemon-reload`.

### 4. Wrong Argument Order for the grok CLI
**Mistake**: `["agent", "stdio", "--always-approve"]`

**Symptom**: `error: unexpected argument '--always-approve' found`

**Correct order**:
```json
"args": ["--always-approve", "agent", "stdio"]
```

Global flags must appear before the subcommand.

Alternative / additional flag:
```json
"args": ["--permission-mode", "bypassPermissions", "agent", "stdio"]
```

### 5. Forgot to Reset the Session After Provider Change
**Mistake**: Changed config + restarted the service, but kept using the old Telegram conversation.

**Result**: Old session ID was still bound to the previous provider (or failed state).

**Fix**: Always send `/newchat` (or `/forget` + new message) after switching providers.

### 6. Assuming One Config Location
Main agent provider can come from:
- `store/main-config.json` (used by `getMainProviderConfig()`)
- `~/.claudeclaw/agents/main/agent.yaml` (used for CWD + some overrides)

Both should be consistent. Sub-agents only use their `agent.yaml`.

### 7. Protocol Quirks (Grok vs Standard ACP)
The `grok agent stdio` speaks a superset / variant of ACP (lots of `_x.ai/...` notifications).

**Observed**:
- Many `"Method not found": _x.ai/session_notification` messages in logs.
- Occasional "ACP connection closed".
- Permission interactions (`pending_interaction`) even with `--always-approve`.

These are mostly harmless for basic use, but the turn can stall on complex permission flows.

**Workarounds**:
- Use `--always-approve` + `dangerouslySkipPermissions: true`
- Start with simple prompts.
- Send `/newchat` if a turn gets stuck.

This is a known integration limitation until xAI provides a cleaner ACP mode.

### 8. Testing Order Matters
- Always test with the **dashboard API** (`/api/chat/send`) first — it bypasses Telegram polling delays.
- Then test via actual Telegram messages.
- Use `/newchat` between major config changes.

## Recommended Directory Structure for Notes

Keep a per-install note:

```
~/.claudeclaw/
├── agents/
│   └── main/
│       ├── agent.yaml
│       ├── PROVIDER.md          # <--- put a copy of this guide summary here
│       └── CLAUDE.md
└── ...
```

## Quick Checklist for New Agents

- [ ] `ENABLE_ACP=true` in `.env`
- [ ] `grok login --oauth` verified
- [ ] Absolute path to `grok` in config
- [ ] Args start with `--always-approve` (or equivalent)
- [ ] `dangerouslySkipPermissions: true`
- [ ] systemd unit PATH includes `~/.local/bin` (or use absolute everywhere)
- [ ] Restart service
- [ ] `/newchat` in Telegram
- [ ] Test with dashboard + real message
- [ ] Check logs for actual `grok` process + tool activity (not ENOENT)

## Related Files

- `store/main-config.json`
- `~/.claudeclaw/agents/*/agent.yaml`
- `~/.config/systemd/user/com.claudeclaw.*.service`
- `src/provider.ts` (how providers are normalized)
- `src/agent-engine/acp-adapter.ts` (how the command is actually spawned)

---

This guide was written after several iterations of "it almost works but the service can't find the binary" and protocol mismatches. Follow the absolute-path + service PATH + arg order rules and you will avoid the traps.