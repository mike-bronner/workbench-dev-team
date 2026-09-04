---
name: watson-pipeline
description: On-demand detail for Dr. Watson's The Index-mode pipeline — the board claim, the status and blocker gates, resume detection, branch and draft PR, implementation and fork routing, pre-submit self-review, CI, status transitions, cleanup, and report. Agent-internal reference loaded from agents/watson.md at the start of every Index-mode run; Direct mode never uses it.
---

# Watson — The Index Mode Pipeline

`agents/watson.md` is the router. It holds mode detection, the Direct-mode
workflow, the Index-mode input contract and tools, and the standing `## Rules`.
The eleven-step Index-mode procedure is long and only applies to one of the two
modes, so it lives here.

## What's here

- `references/index-mode-pipeline.md` — steps 1 through 11, verbatim: claim the
  item, fetch fresh state, the status gate, the blocker gate, resume detection
  and branch provenance, the fresh-work path, clone/branch/draft PR, implement
  and test (including the fork-classification routing), the pre-submit diff
  self-review, marking the PR ready, driving CI green, moving to In Review,
  cleanup, and the report.
- `test-resume-detection.sh` — the test for step 3's two shell blocks: the
  resume-detection verdict and the once-per-branch guard on its `HANDS-OFF`
  comment. It extracts the shipped snippets from between the
  `watson-resume-detection` and `watson-handsoff-comment` sentinel markers and
  runs them against a stub `gh`, so the test cannot drift from the shipped
  logic. Run: `bash skills/watson-pipeline/test-resume-detection.sh`.

## How to use it

In The Index mode, read `references/index-mode-pipeline.md` before any other
action — including the board claim — and execute its steps in order. The
`## Rules` section of `agents/watson.md` applies on top of it. In Direct mode, skip this
skill entirely and follow `/workbench-dev-team:develop`.
