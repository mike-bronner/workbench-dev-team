---
name: orchestrate-modes
description: The dev team's modes, a topic skill of orchestrate. Holds Lestrade's sweep mode, Watson's Direct and Index modes, Holmes's Local mode on a tree or a committed range, the Index-mode dispatcher, and where model and effort come from. Load it with orchestrate when a mode is in question.
when_to_use: Dispatching Watson or Holmes by `Item ID: <n>`, Lestrade by `Repo sweep: <owner/repo>`, or Holmes on Watson's uncommitted tree or a committed range, or when the user asks which mode, model, or effort an agent runs, how a dispatcher run is tracked, or to "find blockers" or "mark dependencies" in a repo.
---

# Orchestrate — the team's modes

A topic skill of `/workbench-dev-team:orchestrate`, which holds the team, the
brief, and the dispatch protocol.

## Holmes can review Direct-mode work first

An uncommitted tree is exactly what Local mode takes, so a Watson Direct-mode
result can go to Holmes on a six-slot brief before the human sees the diff —
the same review the board path gets, with no board item and nothing posted to
GitHub. Dispatch it the same way you dispatch
Watson, with `Workdir:` pointing at the tree Watson left, and `Goal:` and
`Acceptance:` copied from Watson's brief. `Acceptance:` is Holmes's rubric, and
`Goal:` names the unit it belongs to. Offer it rather than assuming it: the
review costs a fan-out, and a one-line change rarely earns one.

## The team's modes

Lestrade is coupled to The Index board — triage needs a `project_items.id`.
Lestrade's sweep mode takes a repo slug instead of an item id; dispatch it when
the user asks to "find blockers" or "mark dependencies" in a repo.

Watson and Holmes each carry an off-board mode that takes a six-slot brief
(the contract in `/workbench-dev-team:orchestrate`) and makes no board calls.
**Watson's Direct mode** runs the
`/workbench-dev-team:develop` workflow on any local repo and hands the work back
as an uncommitted tree; **Holmes's Local mode** reviews exactly that — the
uncommitted working tree in the brief's `Workdir:`, tracked changes and
untracked files — against the brief's `Acceptance:` list as its rubric, and
returns the verdict as prose. Holmes's Local mode makes no The Index call and
no GitHub write at all, so it is safe on any repo, governed or not. Both agents
run the off-board mode by default and switch to Index mode only on the
`Item ID: <n>` token, so a brief needs no mode marker.

**Holmes's Local mode also reviews a committed range.** A PR on a repo The
Index does not govern, or a PR with no board item, goes to Holmes Local mode on
the PR branch's range. First check out the PR at its current head, as
`gh pr checkout <n>` does, and bring `origin/<base>` up to date, asking the
user as the gates require. A local copy of the branch can be behind the
author's last push. Holmes checks the head against the PR itself, and he never
switches branches or moves a ref. Then name the range and the PR number in
`Workdir:`, as
`Workdir: <path> (branch: <head>, range: origin/<base>...HEAD, pr: <n>)`.
Holmes reviews exactly that range against `Acceptance:`, and a range with no
change fails closed. Never unwind the commits with `git reset --soft` to make an
uncommitted tree: name the range.

| The task | Dispatch |
|---|---|
| Implement, fix, refactor, add tests, edit docs | **Watson** (Index or Direct mode) |
| Triage an item, write acceptance criteria | **Lestrade** |
| Review a PR with a board item | **Holmes** (Index mode) |
| Review a PR with no board item, or on an ungoverned repo | **Holmes** (Local mode, on the committed range) |
| Review uncommitted local work | **Holmes** (Local mode) |
| Find where something lives, map a codebase | `Explore` |
| Sketch an approach before any code exists | `Plan` |
| Answer a question that writes no file | `general-purpose` |

## Watson's Index-mode dispatch

**A Watson Index-mode run goes through the dispatcher.** Dispatch
`Item ID: <n>` to Watson as usual. The dev-team mod runs
`~/.claude-workbench/bin/dispatch-agent.sh` in place of the Agent call,
because only the dispatcher gives the run its pipeline flag, and returns the
dispatcher's first line. A first line of `SKIP` (a run on that item is still alive) or `ESCALATE`
(the breaker judges the item wedged) means nothing was spawned: relay it to
the human rather than retrying. Track a spawned run from its log rather than
from a completion notification.
The run exits 0 even when calls were refused, so check the log for
`Permission denied:` lines, one per refused call.

## What the dispatcher does

A Watson Index-mode run ends in commits and pushes. workbench-core's commit
guard refuses both to any sub-agent, and only the top-level loop of a `claude -p --agent` run
commits, with `WORKBENCH_DEV_TEAM_PIPELINE=1` to answer its prompts. The Agent
tool can start neither, so the dev-team mod runs `bin/dispatch-agent.sh` in
place of a main-session Watson `Item ID: <n>` call. The script starts the run
and exports the flag.

`bin/dispatch-agent.sh` reads the same config — model, effort, fallback,
budget — runs the circuit-breaker pre-flight, backgrounds the run in auto mode
with nobody to answer a prompt, and prints the log path. The run's folder is
made in `~/Developer/scratchpad` and deleted when the run ends. How to read its
output and track the run: "Watson's Index-mode dispatch" above.

## Model and effort come from the config, never from you

Nothing in the orchestrate skills reads the dev-team settings, the plugin's rows
in `/config`. When you dispatch Watson, Holmes, or Lestrade by the public type,
the dev-team mod reads them at spawn: it runs the mode agent the token picks,
with the configured `model` and `effort`. All three ship `claude-opus-5-5[1m]`
at `medium`.

**Never pass the Agent tool's `model` parameter to a dev-team agent.** It
accepts only an alias (`sonnet`, `opus`, `haiku`, `fable`), so it cannot carry
the exact ID, and the mod lets a model the caller named stand, so `opus` would
silently replace the pin with whatever the alias points at today. The Agent
tool has no effort, budget, or fallback parameter, so the budget and fallback
rows reach only the scheduled path. When the human edits a row in `/config`,
both paths pick it up on the next dispatch.
