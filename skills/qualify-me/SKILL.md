# Qualify-Me Skill

A product-owner-led qualification process that replaces the old grill-me approach. Instead of grinding through technical trivia, this surfaces real trade-offs and makes sure work is worth doing before the team spends time on it.

## When to use

- Before starting any new feature or significant change
- When the user has an idea and wants to stress-test it
- When prioritizing between competing tasks
- When the user says "qualify this", "should we build this", "is this worth it"

## How it works

The product-owner agent runs a structured conversation with the user, typically 3-5 questions max. Questions are in plain English and have real consequences - the answers directly shape what gets built (or whether it gets built at all).

## Question categories

### 1. Problem validation (always start here)
- "Who has this problem and how often do they hit it?"
- "What do they do right now without this feature?"
- "What happens if we never build this?"

Skip this if it's a bug fix with a clear reproduction.

### 2. Scope check
- "What's the smallest version that still solves the problem?"
- "What parts of this are nice-to-have vs must-have?"
- "Is there an existing feature that almost does this?"

### 3. Risk assessment (only if scope is M or larger)
- "Does this touch authentication, payments, or data storage?"
- "Can we ship this behind a flag and roll back?"
- "What breaks if this has a bug?"

### 4. Priority context
- "Is this more important than [current top priority]?"
- "Is there a deadline or external dependency driving this?"
- "Will this unblock other work?"

## Running a session

### Step 1: Frame it
State what you understand the request to be in one sentence. Ask the user to correct you if wrong.

### Step 2: Ask 3-5 questions
Pick from the categories above based on the nature of the request. Ask them one at a time or as a focused batch - read the user's energy. If they're giving terse answers, batch the remaining questions. If they're engaged, go one at a time.

### Step 3: Recommend
Based on the answers, give one of four recommendations:

**SHIP IT** - Clear problem, manageable scope, no major risks.
Output: Create a mission task for architect with problem statement + acceptance criteria.

**SLIM IT** - Good problem but the proposed solution is too big.
Output: Describe the minimal version. Ask user to confirm, then create mission task.

**SHELF IT** - Valid idea but not the right time.
Output: Log to hive mind with reason and revisit conditions. No mission task.

**KILL IT** - Cost outweighs benefit.
Output: Explain why plainly. Suggest what to focus on instead.

### Step 4: Log the decision
```bash
sqlite3 store/claudeclaw.db "INSERT INTO hive_mind (agent_id, chat_id, action, summary, artifacts, created_at) VALUES ('product-owner', '[CHAT_ID]', 'qualification', '[DECISION]: [feature name] - [1 line reason]', NULL, strftime('%s','now'));"
```

## What makes this different from grill-me

| Old grill-me | New qualify-me |
|---|---|
| Technical trivia questions | Business outcome questions |
| Tests knowledge | Tests value proposition |
| Same questions regardless of scope | Questions scale with scope |
| No clear outcome | Clear SHIP/SLIM/SHELF/KILL decision |
| Feels like a quiz | Feels like a strategy session |
| Run by any agent | Run by product-owner specifically |
| Can be tedious for small changes | Small changes skip straight to SHIP IT |

## Fast path

For small, obvious changes (bug fixes, typos, config tweaks), skip the full process:

"This is a straightforward fix. Shipping it."

Then create the mission task directly. Don't waste everyone's time qualifying a typo fix.

## Rules

- Never more than 5 questions. If you can't qualify in 5, the scope is unclear and you should say so.
- Questions must be in plain English. No jargon. If you're asking about "coupling" or "idempotency", translate it: "Can we run this twice by accident without breaking anything?"
- Every session ends with a clear recommendation (SHIP/SLIM/SHELF/KILL) and logged decision.
- Don't rubber-stamp. If every qualification ends in SHIP IT, you're not doing your job.
- Respect the user's time. If they clearly have conviction and the scope is small, get out of the way.
