---
name: holmes-review
description: On-demand detail for Sherlock Holmes's multi-phase PR review — the blind lens fan-out, adversarial verification of blocker-class findings, the memory-vault context pass, the inline fallback, and every sub-agent prompt skeleton. Agent-internal reference loaded from agents/holmes.md §4 when a review reaches Phase B; not a standalone workflow.
---

# Holmes — Review Phase Detail

`agents/holmes.md` is the router. It holds the review's rule content: the strike
count (§3), Phase A evidence setup (§4a–4c), the AC contract (§4d), and the
finding-routing matrix (§4e). The procedure between Phase A and the verdict is
long and only matters once a review is under way, so it lives here.

## What's here

- `references/review-phases.md` — Phases B, C, and D plus the `§4-fallback`
  inline path, verbatim:
  - **Phase B** — four blind lens reviewers (AC conformance, correctness,
    security, test-honesty), the finding shape, the lens prompt skeleton.
  - **Phase C** — which findings get adversarially verified, the single-skeptic
    track, the security red-team / blue-team / auditor track, the verification
    cap and its priority order, the dedup step.
  - **Phase D** — the parent-only memory-vault contextualization of survivors.
  - **§4-fallback** — the complete inline review when the fan-out is
    unavailable.

## How to use it

Read `references/review-phases.md` when you reach Phase B, follow it end to end,
then return to `agents/holmes.md` §4d/§4e for the verdict logic. Section markers
inside the reference (§3, §4d, §4e, §5) point back into the agent prompt.
