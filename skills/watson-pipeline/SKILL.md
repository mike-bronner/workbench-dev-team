---
name: watson-pipeline
description: On-demand detail for Dr. Watson's The Index-mode pipeline — the host-local lock, the blocker gate, resume detection, branch and draft PR, implementation and fork routing, pre-submit self-review, CI, status transitions, cleanup, and report. Agent-internal reference loaded from agents/watson.md at the start of every Index-mode run; Direct mode never uses it.
---

# Watson — The Index Mode Pipeline

`agents/watson.md` is the router. It holds mode detection, the Direct-mode
workflow, the Index-mode input contract and tools, and the standing `## Rules`.
The eleven-step Index-mode procedure is long and only applies to one of the two
modes, so it lives here.

## What's here

- `references/index-mode-pipeline.md` — steps 1 through 11, verbatim: acquire the
  lock, fetch fresh state, the blocker gate, resume detection, the fresh-work
  path, clone/branch/draft PR, implement and test (including the
  fork-classification routing), the pre-submit diff self-review, marking the PR
  ready, driving CI green, moving to In Review, cleanup, and the report.

## How to use it

In The Index mode, read `references/index-mode-pipeline.md` before any other
action — including the lock — and execute its steps in order. The `## Rules`
section of `agents/watson.md` applies on top of it. In Direct mode, skip this
skill entirely and follow `/workbench-dev-team:develop`.
