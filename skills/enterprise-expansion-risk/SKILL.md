# Enterprise Expansion Risk Skill

Evaluate an AI consulting engagement for expansion risk signals. Based on the CAIS post-mortem ("The mistake we made that cost us a $1M enterprise contract") and the Kashef sales framework ("Perceived reality is the only reality").

Core principle: **Value delivered ≠ Value perceived.** Expansion happens when leadership experiences transformation — not when the system works.

> *"Build quality matters less than you think. The engagement around it is what compounds."*
> — CAIS, The Lesson (Day 09/30)

## Stakes

The expansion from PoC to portfolio-wide AI infrastructure is the real prize — not the PoC contract itself. CAIS lost $1M+ in portfolio expansion (becoming the AI infrastructure team for an entire company) because of relationship posture failures, not product failures. The client didn't ask for less. The vendor failed to build the conditions where expansion was the obvious next move.

**"It was on us."** — CAIS, post-mortem

The vendor is responsible for the expansion conditions. The client will not ask.

Two quotes from Devin Kearns (end user, CAIS client) that define the stakes:
- *"We worked on the business. The business got better."* — product worked, ROI was real
- *"They would throw a fit if we ripped it out."* — users were embedded and loved it

Both true. $1M expansion still lost. The relationship around the work was thin.

## When to use

- After delivering a PoC or Phase 1 to an enterprise client
- When qualifying whether an active engagement is on track for expansion
- During QBR prep or check-in reviews
- When a client "seems happy" but no expansion conversation has started

## The 6 Expansion Risk Signals

Run this checklist against any active engagement. Each unchecked item is a risk.

### Signal 01 — Vague success metrics
- [ ] Has "winning" been defined in writing with the client?
- [ ] Does every stakeholder agree on what success looks like?
- [ ] Is there a shared scorecard, or is each person running their own?

**Red flag:** "The client seems happy" without a locked definition of what they're measuring.

### Signal 02 — Big-bang delivery
- [ ] Is value being delivered in visible increments (not all at the end)?
- [ ] Has the client seen something working at least once per 2-week period?
- [ ] Is momentum building or waiting?

**Red flag:** "We're heads-down building" with no client touchpoints for weeks.

### Signal 03 — Single stakeholder
- [ ] Have we met more than one person at the company?
- [ ] Has leadership (VP/C-suite level) seen the system in action?
- [ ] Is anyone on the buying committee invested beyond our primary contact?
- [ ] Have we spoken directly to the end users who actually use what we built?
- [ ] Do we know who sits between our champion and the end users?

**Red flag:** All communication flows through one champion — in both directions. Nobody above them knows us AND we've never spoken to the people actually using the system. This is a game of telephone: every handoff distorts the message, and we don't know what the end users are actually experiencing.

**From CAIS Day 29/30:** "We never spoke to the people who actually used what we built." The chain was CAIS → Champion → ??? → End users. The ??? was an unknown middle layer they never identified.

### Signal 04 — Vendor posture
- [ ] Is there a QBR scheduled (or equivalent "what's next" conversation)?
- [ ] Are we proactively bringing new ideas, or just executing what's asked?
- [ ] Have we had a conversation in the last 30 days that wasn't about the current deliverable?

**Red flag:** We delivered, they're using it, and we're waiting for them to tell us what's next.

### Signal 05 — Thin champion
- [ ] Can our champion articulate the business case for expansion internally?
- [ ] Have we given them more than a document — have we walked them through it?
- [ ] Do they have talking points tailored to the specific skeptics in their org?
- [ ] Have we role-played the internal pitch with them?
- [ ] Do they know what they'd ask for and why?

**Red flag:** Champion loves the product but their "handoff" was a PDF. A document can't answer the CFO's questions. A document doesn't know who the skeptics are. If the champion has to figure out the internal pitch alone, they'll fail alone.

**The fix:** "Documentation as a real deliverable" — scope it, plan it, price it. Not an afterthought. The champion enablement package is a named output, delivered like any other module.

**From CAIS Day 09/30:** "Handoff was a PDF — we provided handoff documentation." The implication: they thought documentation was enough. It wasn't. The champion needed to be armed as an internal sales rep, not handed a report.

### Signal 06 — Narrow discovery
- [ ] Have we mapped the client's full workflow, not just the scoped use case?
- [ ] Do we know the difference between what was asked and what was actually needed?
- [ ] When asked "what else could you do for us?" — do we have a plan, not just ideas?
- [ ] Have we identified 2-3 natural expansion paths?
- [ ] Would the output we built be used daily or periodically? (daily = embedded, periodic = forgettable)

**Red flag:** Our discovery ended when the contract was signed. Classic form: built the newsletter they asked for, found out after delivery they actually needed a dashboard. The ask and the need were different. Narrow discovery can't see that gap.

**From CAIS Day 09/30:** Client feedback post-delivery — "newsletter is not the right thing, what we really need is like a dashboard." They built a monthly newsletter (push, periodic, forgettable). The need was a dashboard (ambient, daily, embedded in leadership's workflow).

## Identity Check — Dev Shop vs Partner

Before running the signal checklist, answer this: are we operating as a dev shop or a partner?

| Dev shop | Partner |
|----------|---------|
| Check boxes, ship, move on | Consult, embed, compound |
| Execute what's asked | Bring ideas to the table |
| One contact, scoped deliverable | Embedded in the org, multiple stakeholders |
| Value delivered once | Value compounds over time |

**If the answer is "dev shop" — stop the checklist and fix the posture first.** All 6 signals will be red anyway.

From CAIS Day 09/30: this is the "Before / After" framing. The expansion was lost because CAIS operated as a dev shop after delivering as a partner would have.

## Scoring

Count unchecked items:
- **0-1**: Low risk. Expansion posture is healthy.
- **2-3**: Medium risk. Address the gaps before the next renewal conversation.
- **4-6**: High risk. Expansion is unlikely without intervention. Escalate to human.

## The Fix — Engagement Gates (Hard-coded, not optional)

From CAIS's rebuilt methodology after the $1M loss. Every engagement runs through these gates:

### P0 — Leadership in every Phase 0 (mandatory, no exceptions)
Multiple stakeholders in discovery. Champion isn't enough.
**The CFO and COO know who we are before any work starts.**
FIX 01: leadership is a mandatory agenda item on the Phase 0 kickoff call. If leadership isn't present, reschedule or get a confirmed intro before proceeding. "Phase 0" is the named gate — use this language with clients.
- Deliverable: named leadership contacts confirmed aware of the engagement, on record from Phase 0

### P1 — Locked metrics (before any code)
3-5 success metrics. Signed by both sides.
**Tied to numbers leadership already tracks. Before any code.**
- Deliverable: signed success definition document with named signatories on both sides

### P2 — Full-business Blueprint (before scoping, before any code)
*(FIX 02 from CAIS: "we beefed up our discovery process like a hundredfold" → "Workflow-only discovery" becomes "Full-business Blueprint")*
Discovery is not a kickoff call. The Full-business Blueprint maps the entire org: workflows beyond the scoped use case, the gap between what's asked and what's actually needed, expansion paths, and the internal landscape of stakeholders and skeptics.
- Deliverable: Full-business Blueprint document — named, scoped, treated as a real project deliverable
- Must cover: full org workflow, 2-3 expansion paths, output format validated against underlying need
- Gate check: could our champion use this Blueprint to make an internal case for expansion without our help?

### P3 — Module-by-module delivery (throughout build)
Progressive deployment. Value visible in weeks.
**The client feels momentum the whole way through.**
- Deliverable: working module shipped within first 2 weeks, then incrementally

### P4 — Built-in QBR cadence (post-delivery, recurring)
Even one-time projects. We don't disappear after handoff.
**The next project is already mapped.**
- Deliverable: QBR scheduled before delivery is complete, next engagement scoped in advance

---

**If any gate is missing going into a milestone review — stop. Don't proceed to the next phase until it's installed.**

## Output format

```
EXPANSION RISK ASSESSMENT — [Client Name]
Date: [YYYY-MM-DD]
Risk level: [Low / Medium / High]

Signals flagged:
- [Signal name]: [What's missing and why it matters]

Recommended actions:
1. [Specific action with owner and timing]
2. ...

Kashef principle triggered: [Which one and why]
```

## Sales Pitch — Three Questions to Win (and Answer)

From CAIS's client-facing takeaway: what a sophisticated buyer asks when vetting an AI partner. If you can answer these in a pitch, you've separated from every dev shop in the room.

**"Ask about the discovery rigor. Ask about the metrics. Ask who at your company they'll get in a room."**

| What they ask | What your answer signals |
|---------------|--------------------------|
| "Are you mapping our whole operation, or just the workflow we asked about?" | P2 deep discovery — you see beyond the scoped ask |
| "Will success be locked, signed, tied to numbers our leadership tracks?" | P1 locked metrics — you don't start without it |
| "Are you showing up as a partner from day one, or quoting a project we'll renew ourselves?" | P0 + P4 posture — partner identity, not vendor identity |

**If a prospect doesn't ask these questions:** they're a less sophisticated buyer. Either educate them on why these matter, or accept that you'll have to manage their expectations more actively post-delivery.

**If you can't answer these questions:** don't take the engagement. You'll end up in the CAIS situation.

## Rules

- Run this checklist at every milestone gate for AI consulting engagements.
- Don't run it once and forget it. Signals change as the engagement evolves.
- Never assume "client is happy" = "expansion is likely." These are unrelated.
- If Signal 03 (single stakeholder) is red, nothing else matters until it's fixed.
- Route the assessment to product-owner for strategic decisions on intervention.

## Source

CAIS (customaistudio.io) — "From the Field" Day 09/30: "The mistake we made that cost us a $1M enterprise contract"
Kashef framework: "Foundations for Selling AI" — `breakoutmanagement/earlyaidopters`
Rob insights: `/home/ccaudit/.claudeclaw/agents/rob/memory/knowledge/insights.md` (2026-05-09 entry)
