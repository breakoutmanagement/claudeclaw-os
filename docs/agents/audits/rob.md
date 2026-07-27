# rob — Audit Log

Append-only agent output log. Newest entries first.

---

## 2026-06-19

### Session — QUEUE_FAILED diagnosis + Codie Sanchez re-extract

- Diagnosed the `QUEUE_FAILED` ingest bug (root cause from 2026-06-16 still open)
- Re-extracted Codie Sanchez insights for Breakout pipeline

**Related context (2026-06-16 root cause):** `ensureQueuedResearchJob` uses `INSERT...ON CONFLICT DO NOTHING`. Videos with prior transcribe jobs in terminal states can never be re-queued via public API → 500. Dashboard retry works because it `UPDATE`s status back to `queued`. Fix: `DO UPDATE` / reset terminal rows in public API.

---

## 2026-06-18

### Transcript re-extract — Codie Sanchez `ksRcFGLPoSk`

Re-parsed raw transcript for Breakout-specific actions.

**Top MUST-DO:**

1. Avoma-style sales-call intelligence loop (call recordings + Kashef course)
2. Teach/adopt Perplexity → ChatGPT → Claude model-chaining stack
3. Rebuild positioning with hyper-specific avatar + Villain/Victim/Vow
4. Cold-vs-Warm copy split
5. Money-loves-speed AI lead responder

**Artifact:** `store/digests/ksRcFGLPoSk-breakout-actions.md`
