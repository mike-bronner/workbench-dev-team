---
name: holmes-review
description: On-demand detail for Sherlock Holmes's reviews — the blind lens fan-out, adversarial verification of blocker-class findings, the memory-vault context pass, the inline fallback, every sub-agent prompt skeleton, and the whole of Local mode (reviewing an uncommitted working tree from a prose brief, with no The Index calls and no GitHub writes). Agent-internal references loaded from agents/holmes.md — the phases when a review reaches Phase B, Local mode at the start of any local run; neither is a standalone workflow.
---

# Holmes — Review Phase Detail

`agents/holmes.md` is the router. It holds the review's rule content: mode
detection, the strike count (§3), Phase A evidence setup (§4a–4c), the AC
contract (§4d), and the finding-routing matrix (§4e). Two procedures are long and
each matters on one path only, so they live here.

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
- `references/local-review.md` — the whole of **Local mode**: reviewing the
  uncommitted working tree in a prose brief's `Workdir:`, with no The Index call
  and no GitHub write. What replaces each board-coupled step (item fetch, PR
  find, strike count, AC read, checkout, CI), the brief's `Goal:` and
  `Done when:` as the rubric, the four prompt substitutions that let Phases B–D
  run untouched, the **§L4-fallback** replacement for the one path no
  substitution reaches, the no-write line every sub-agent prompt carries (and
  the `PreToolUse` guard that enforces it), the three verdicts as prose, and the
  vault note that never feeds the top-lessons digest.

## How to use it

**Local mode** (a prose brief): read `references/local-review.md` first, before
anything else, and follow it end to end. It sends you into
`references/review-phases.md` for Phases B–D with its substitutions applied, and
back to `agents/holmes.md` §4d/§4e for the verdict logic.

**The Index mode** (an `Item ID: <n>` token): read `references/review-phases.md`
when you reach Phase B, follow it end to end, then return to `agents/holmes.md`
§4d/§4e. Section markers inside that reference (§3, §4d, §4e, §5) point back into
the agent prompt.
