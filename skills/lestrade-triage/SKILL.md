---
name: lestrade-triage
description: On-demand detail for Inspector Lestrade's triage — the four blind acceptance-criteria lenses with their prompt skeleton (step 4.6), and the whole of Sweep mode (blocked-by links plus follow-up consolidation). Agent-internal reference loaded from agents/lestrade.md; each file applies to one path only, so neither is loaded on every dispatch.
---

# Lestrade — Triage Detail

`agents/lestrade.md` is the router. It holds the input contract, the tools, the
Item-mode workflow, the sizing and widening rules (§4.5), the WSJF scoring, and
the standing `## Rules`. Two blocks are long and situational, so they live here.

## What's here

- `references/ac-verification-lenses.md` — step 4.6, verbatim: the four blind
  lenses (malicious-compliance, testability, completeness, edge-case), the lens
  prompt skeleton, the inline fallback when the fan-out is unavailable, the
  single bounded tightening pass, and the paper-trail comment.
- `references/sweep-mode.md` — Sweep mode, verbatim: collecting the open issues,
  the evidence bar for a blocked-by link, writing the links, folding
  `expand-from` comments into acceptance criteria, merging near-duplicate
  follow-ups into the earliest anchor, the report format, and the sweep rules.

## How to use it

Read `references/ac-verification-lenses.md` at step 4.6 — on every path that
writes or rewrites acceptance criteria — then continue to scoring. Read
`references/sweep-mode.md` when the input is `Repo sweep: <owner/repo>`, and
follow it instead of the Item-mode workflow.
