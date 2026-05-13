# Transcript Digest Skill

Turn raw video transcripts from the Breakout Research platform into structured "patterns to try / skip / revisit" artifacts that the tech-lead agent can evaluate against the codebase.

## When to use

- After new video transcripts are processed by the research platform
- When the user asks to review a specific creator's content (e.g. "digest Matt Pocock's latest videos")
- When the tech-lead needs fresh patterns to evaluate

## Workflow

### 1. Fetch the transcript

```bash
# Get a video with full transcript
curl -s -H "Authorization: Bearer $BREAKOUT_API_KEY" \
  "https://api.research.breakoutwithai.com/api/v1/videos/VIDEO_ID?include_transcript=true" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('transcriptSummary','No summary')); print('---TRANSCRIPT---'); print(d.get('rawTranscript','No transcript'))" \
  > /tmp/transcript-VIDEO_ID.txt
```

### 2. Extract patterns

Read the transcript and identify:

**Coding patterns**: Specific techniques for structuring code
- Name the pattern
- Quote the relevant section (timestamp if available)
- Describe what it does and when to use it

**Development practices**: Workflow, tooling, process changes
- What's the practice?
- What problem does it solve?
- What's the overhead?

**Anti-patterns**: Things explicitly called out as bad
- What's the anti-pattern?
- Why is it bad?
- What's the alternative?

**Tools/libraries mentioned**: Specific tech recommendations
- What is it?
- What does it replace?
- Is it a dependency risk?

### 3. Produce the digest

Output format:

```markdown
# Transcript Digest: [Video Title]
Source: [Channel] / [Video ID]
Date processed: [YYYY-MM-DD]

## Patterns to Try
1. **[Pattern name]**
   What: [1-2 sentences]
   When: [Use case]
   Example: [Code snippet or description from video]
   Codebase relevance: [Where this could apply in ClaudeClaw]

2. ...

## Patterns to Skip
1. **[Pattern name]**
   What: [1-2 sentences]
   Why skip: [Doesn't fit our stack / too much overhead / solves problem we don't have]

## Patterns to Revisit Later
1. **[Pattern name]**
   What: [1-2 sentences]
   Why later: [Need X first / wait for Y / evaluate after Z ships]

## Anti-patterns Flagged
1. **[Anti-pattern]**
   Risk: [Do we do this currently?]
   Fix: [What the video recommends]

## Tools/Libraries Mentioned
| Tool | Purpose | Adopt? | Notes |
|------|---------|--------|-------|

## Key Quotes
- "[Quote]" - on [topic]
- ...
```

### 4. Save and hand off

```bash
# Save the digest
DIGEST_PATH="/tmp/digest-VIDEO_ID.md"
# Write digest to file

# Create a mission task for tech-lead to evaluate
PROJECT_ROOT=$(git rev-parse --show-toplevel)
node "$PROJECT_ROOT/dist/mission-cli.js" create --agent tech-lead --priority 5 \
  --title "Evaluate: [Video Title] digest" \
  "Review the transcript digest at $DIGEST_PATH and evaluate each pattern against the ClaudeClaw codebase. Use the evaluation framework in your CLAUDE.md."
```

## Batch processing

When processing multiple videos from a channel:

```bash
# Fetch recent videos from a channel (no search endpoint, so paginate)
curl -s -H "Authorization: Bearer $BREAKOUT_API_KEY" \
  "https://api.research.breakoutwithai.com/api/v1/videos?limit=50&offset=0" \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
videos = data if isinstance(data, list) else data.get('videos', [])
for v in videos:
    if 'TARGET_CHANNEL' in v.get('channelName', ''):
        status = v.get('transcriptStatus', 'unknown')
        print(f\"{v['videoId']} | {status} | {v.get('title', 'untitled')}\")
"
```

Process each completed video through steps 1-4 above.

## Rules

- Never access YouTube directly. All video content comes through the Breakout Research API.
- Always include "Codebase relevance" for every pattern. Abstract patterns with no concrete application are useless.
- Don't evaluate patterns yourself. Extract and describe them, then hand off to tech-lead for evaluation.
- Keep digests focused. If a 60-minute video covers 2 main patterns and 8 tangential tips, focus on the 2 main patterns.
- Flag your confidence: if the transcript is garbled or context is unclear, say so rather than guessing.
