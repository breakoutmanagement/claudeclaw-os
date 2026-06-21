# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

## Before exploring, read these

- **`CLAUDE.md`** at the repo root -- this is the primary system prompt and contains agent personality, environment, skills, and operational rules.
- **`agents/*/CLAUDE.md`** -- per-agent system prompts with role-specific instructions, standing rules, and workflow definitions.
- **`docs/slices/`** -- slice specification documents (e.g. `001-memory-policy-enforcement.md`) defining implementation contracts.

If any of these files don't exist, **proceed silently**. Don't flag their absence; don't suggest creating them upfront.

## File structure

Single-context repo (this repo):

```
/
+-- CLAUDE.md                        # main system prompt
+-- docs/
|   +-- agents/                      # skill config (this directory)
|   +-- slices/                      # implementation slice specs
+-- agents/
|   +-- */CLAUDE.md                  # per-agent system prompts
|   +-- */agent.yaml                 # per-agent config (model, token, etc)
+-- src/                             # TypeScript source
+-- scripts/                         # Bash utilities
+-- hooks/                           # pre/post-message guard hooks
+-- skills/                          # MCP-compatible skills (project-level)
```

Global skills live at `~/.claude/skills/` and are available to all agents.

## Use the glossary's vocabulary

Key terms in this codebase:
- **agent** -- a ClaudeClaw instance with its own config, model, and optional Telegram bot
- **headless** -- an agent running without Telegram, processing only mission queue tasks
- **mission task** -- a one-shot async work item queued for a specific agent
- **scheduled task** -- a cron-triggered recurring prompt
- **lane spec** -- an architect-authored implementation contract for dev-agent
- **hive mind** -- the shared activity log table across all agents
- **slice** -- a PO-authored implementation specification with acceptance criteria
- **platter** -- a specialist agent's canonical output document

When your output names a domain concept, use these terms. Don't drift to synonyms.

## Flag ADR conflicts

If your output contradicts an existing slice contract or standing rule in an agent's CLAUDE.md, surface it explicitly rather than silently overriding:

> _Contradicts slice 04 SS2 (persistence volume layout) -- but worth reopening because..._
