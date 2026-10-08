---
name: orchestrate
description: Run the dev team (Lestrade, Watson, Holmes) as background sub-agents. Holds the agent routing, the six-slot brief every handoff uses, the commit-approval rule, and GitHub action routing. Read it before picking any sub-agent.
when_to_use: Delegating development, triage, or review, or when the user asks to review a PR, comment on an issue, merge a PR, triage an item, or check where work stands. Triggers on "delegate this", "send Watson at", "have the team", "review this PR", "comment on", "merge", "orchestrate", or any multi-step dev task that should run in the background. Read-only research dispatches included, and whenever a dispatch gate refuses a handoff.
---

# Orchestrate — The Dev Team as Sub-Agents

You are the orchestrator. The work happens in sub-agents; the main conversation
holds only the roster, the verdicts, and the decisions. You dispatch, you track,
you relay — you do not implement, triage, or review in the main context.

## The team

| Agent | `subagent_type` | Role | Input contract |
|---|---|---|---|
| Inspector Lestrade | `workbench-dev-team:lestrade` | Triage — AC + WSJF; blocker sweeps | `Item ID: <n>` (triage one item) **or** `Repo sweep: <owner/repo>` (blocker sweep across a repo's open issues) |
| Dr. Watson | `workbench-dev-team:watson` | Development | `Item ID: <n>` (board item) **or** the six-slot brief (Direct mode, ad-hoc dev) |
| Sherlock Holmes | `workbench-dev-team:holmes` | Code review | `Item ID: <n>` (board PR review) **or** the six-slot brief (Local mode, uncommitted working tree) |

## Agent choice — three specialists, and how to tell them apart

**Three destinations, and the shape of the request names which one.**

- **Development — Watson.** The request ends in a changed file. Code, tests,
  config, docs, migrations, a one-line fix — all of it, Index mode with a board
  item and Direct mode without one. Never `general-purpose` for work that
  produces a diff.
- **Triage — Lestrade.** The request is about an item nobody has specified yet:
  write the acceptance criteria, score it, size it, find what blocks it.
- **Review — Holmes.** The request judges work already written, and the answer is
  a verdict rather than a diff. Index mode when a board item and its PR exist;
  Local mode when the work is still an uncommitted tree, which is how every
  Watson Direct-mode run comes back.

A specialist loads `/workbench-dev-team:develop`, and a generic agent does not.
`/develop` §1 is where the discovery rule lives — don't restate it in a prompt,
and don't pre-decide any of it. Why the routing turns on skill loading:
`references/brief-rationale.md`.

**Read-only dispatches stay generic, and should.** `Explore`, `Plan`, and
`general-purpose` are the right call whenever nothing gets written. They are
generic in *destination* only — the brief below governs them exactly as it
governs a Watson build.

## Dispatch in parallel — every independent unit at once

**Dispatch every independent unit at once, in one message.** Units in
different repos or in files that do not overlap are independent, and so are
read-only research and reviews of a finished tree. Never serialize out of habit.

**Local work has no count cap.** Local work is this session, Watson's Direct
mode, Holmes's Local mode, and research. Dispatch as many sub-agents as there
are independent units. The Index pipeline stays limited: one Watson per
scheduled tick, and every Index-mode cap stays.

**Same-repo work that could split needs worktrees, and the human creates
them.** Propose them through the workspace check (below), then dispatch one
Watson per worktree. Never create a worktree yourself. Until they exist,
same-repo units run one at a time. Why: `references/brief-rationale.md`.

## Check the workspace before you dispatch

**Branches and worktrees are wanted. The human picks them.** Most dev work lands
on a branch, and a PR is a normal finish line. What is not yours is creating a
branch unasked, or creating a worktree at all: the human creates worktrees.
Before any dispatch whose work ends in a commit,
read the target tree (`git -C <workdir> status -sb`, `git worktree list`) and ask.

Three cases, each ending in a question:

- **On `main`, `master`, or `trunk`** — propose a branch name and ask before it
  is created. The harness tells you to branch first on the default branch; that
  is a reason to raise the branch, never a licence to cut it unasked.
- **On a feature branch already carrying unrelated work** — name what is on it,
  propose a branch off the base, and ask. Stacking this task on somebody's
  half-finished one is the failure being prevented.
- **Inside a worktree** — confirm it is the one meant for this task, and ask
  when it is not.

None of the three refuses a dispatch. Ask, take the answer, then dispatch.
**Record the answer in `Workdir:`** — the branch or worktree beside the absolute
path, `Workdir: /Users/mike/Developer/foo (branch: fix/retry-backoff)` — so no
workspace choice is made inside a sub-agent the human never saw. A bare path
stays valid, and means there was no workspace decision to record.

**Two Watsons on one repo need separate worktrees, and the human creates
them.** Ask the same way. Once the human has created them, name each in its own
brief and dispatch one Watson per worktree. Never pass the Agent tool's
`isolation: "worktree"`: the provisioning guard denies an agent-made worktree.
One working tree holds one branch, so two runs sharing it overwrite each other's
edits.

**A read-only dispatch decides no workspace.** `Explore`, `Plan`, and
`general-purpose` write nothing, and take the tree as it stands.

Why the check exists, and why the answer widens `Workdir:` instead of adding a
slot: `references/brief-rationale.md`.

## Dispatch protocol

1. **Background by default.** Every dispatch sets `run_in_background: true`.
   The conversation continues; completion notifications arrive on their own.
   Foreground only when the user explicitly wants to wait on a quick result.
2. **No `model` parameter.** Never pass the Agent tool's `model` to a dev-team
   agent. The agent's frontmatter carries the configured model, and the
   alias-only parameter would override it (see "Model and effort" below).
3. **Every handoff is a brief.** Sub-agents have no memory of this
   conversation, so send the six slots defined below and nothing else — for
   Watson's Direct mode, Holmes's Local mode, and the read-only `Explore`,
   `Plan`, and `general-purpose` runs alike. Research is not exempt, and that is
   the point (why: `references/brief-rationale.md`). Three shapes are exempt:
   the two machine-built tokens (`Item ID: <n>` and `Repo sweep: <owner/repo>`,
   between them every Lestrade dispatch and every Holmes Index-mode dispatch),
   and a specialist's own fan-out, which stays inside the orchestrator boundary
   rather than crossing it. Read the fan-out exemption as a boundary, never as
   a list of agents (why: `references/brief-rationale.md`). A Watson or Holmes
   `Item ID: <n>` run needs no `Acceptance:` slot: the item's acceptance
   criteria, written by Lestrade at triage, are its Acceptance list.
4. **A Watson Index-mode run goes through the dispatcher, never the Agent
   tool**, because only the dispatcher gives the run its pipeline flag (see
   "What the dispatcher does" below). It takes the same item id:

   ```bash
   bash "$HOME/.claude-workbench/bin/dispatch-agent.sh" watson <item-id>
   ```

   A first line of `SKIP` (a run on that item is still alive) or `ESCALATE`
   (the breaker judges the item wedged) means nothing was spawned: relay it to
   the human rather than retrying. Track a spawned run from its log rather than
   from a completion notification, and keep the roster line updated from it.
   The run exits 0 even when calls were refused, so check the log for
   `Permission denied:` lines, one per refused call. The Agent tool stays right
   for everything that writes no commit: Watson's Direct mode, Lestrade,
   Holmes, and every read-only dispatch.

### Direct-mode work comes back uncommitted

**Watson's Direct mode ends in a working tree, not a commit.** The commit guard
refuses a sub-agent every commit and push, and a sub-agent does not merge. So
its report carries a diff summary and a proposed commit message instead, and the
tree is left as the change made it.

**Committing it is yours, and so is the push.** Prompting the human is yours
too: the sub-agent never asks. Tell the human the tree is ready for their
review. Commit only after a "Commit it" pick in `AskUserQuestion`, once the
human says their review is done. A typed "commit it" in chat does not count.
Offer the commit through `AskUserQuestion` after they say their review is done,
asked alone and never bundled with other questions or work. Do not offer the
commit before then. If an offer does reach the human early, "Not yet" leads.
The question carries the branch and the proposed message. Until the human has
said their review is done, the recommended first option is "Not yet" or
"Review with Holmes first" (below), and "Commit it" goes last. Its description
reads: "Picking this confirms you have reviewed the whole tree." Then attempt
the commit and the push yourself. Claude Code's permission prompt is the
mechanical backstop, not the approval. The full rule, and the plain form the
ask rules match, are canonical in the `/workbench-dev-team:git-commit` skill
("Committing and pushing"). Never send the agent back to commit: only a
foreground session reaches the human's prompt.

## Action routing — Index MCP or gh CLI?

When the user asks for a GitHub action (review, comment, merge, triage, fix),
two questions decide the path. Answer them in order.

### 1. Whose voice does the action carry?

- **Agent work products** — formal PR reviews, acceptance criteria, status
  moves, agent comments — exist only inside The Index pipeline, signed by that
  agent's GitHub App. They go through a dispatched agent and its MCP write
  tools. Never produce them with `gh`; a Claude-authored verdict posted under
  the user's identity forges the review gate.
- **The user's own actions** — comments they dictate, merges they order — are
  theirs, executed directly with `gh` under their identity, on any repo. You
  are the secretary here, not an agent.
- **Neither, when nothing reaches GitHub.** A Holmes Local-mode verdict is prose
  returned to this conversation, so it carries no GitHub voice and needs no
  routing decision. Posting one anywhere is the user's own action, and only
  after they have seen the exact content and said so.

### 2. Is the repo governed by The Index?

A repo is governed when The Index's GitHub App is installed on it. How to check,
and how to resolve the item ID that Lestrade and Holmes's Index mode need:
`references/governed-repos.md`. A miss on the fallback scan is inconclusive, so
ask rather than treat the repo as ungoverned. If the repo is governed but the
item can't be resolved, **stop and report** — never fall back to `gh` for agent
work products.

### Routing table

| Request | Governed repo | Ungoverned repo |
|---|---|---|
| "review this PR" | Resolve item → dispatch **Holmes** (`Item ID: <n>`) — formal signed review | Wants a GitHub review artifact → review inline, post via `gh pr review` as the user, after confirming. Conversational opinion → verdict in chat, nothing posted. **Unclear which → ask.** Holmes has no path here: Local mode reviews an uncommitted tree, never a PR |
| "review what I've changed" / "review this working tree" | **Holmes** Local mode (the six-slot brief, via the Agent tool); the verdict comes back as prose | same — Local mode makes no board call and no GitHub write, so the repo's governance is irrelevant |
| "comment on issue/PR" (user's words) | `gh issue comment` / `gh pr comment` — the user's voice | same |
| "create / open an issue" (user's words) | `gh issue create` — **the user's voice**, authored by you (the human); confirm repo + title first | same |
| "implement / fix / build X" | Item exists → **Watson** Index mode, through the dispatcher (Dispatch protocol, step 4), never the Agent tool. No item → ask: file it on the board, or Watson Direct mode off-board | **Watson** Direct mode (the six-slot brief, via the Agent tool; the diff comes back uncommitted) |
| "triage / write AC" | Resolve item → **Lestrade** (`Item ID: <n>`) | Draft AC inline — no agent |
| "merge this PR" | `gh pr merge` — **only on explicit request**, confirm repo + PR first. Never delegated to an agent (Holmes never merges; the MCP has no merge tool; the commit guard refuses a sub-agent's or the pipeline's `gh pr merge`). Board status follows via webhook | same |
| "where do things stand?" | Index read tools (`list_items`, `list_review_items`, …) + your roster | `gh pr list` / `gh issue list` + roster |

**Every "ask" and "confirm" in this table goes through `AskUserQuestion`,**
with the recommended choice first and any warning in its description.

### Passing a gh body

Before any `gh` call that carries prose (a comment, an issue, a PR body, or
release notes), read "Passing a gh body" in `/workbench-dev-team:git-commit`.
Pass the body in a quoted heredoc or a file: write
`--body-file - <<'EOF'` (or `--notes-file -`), or name a file. Never write a
multi-line body in double quotes: the shell runs its backticks.

## The brief — six slots, on every handoff

A dispatch prompt is a **brief**, not a script. It states an outcome, the
reasoning behind it, and the limits on reaching it. It does not describe how the
work is done.

Every handoff uses it, read-only research included. Three shapes are exempt:
the two machine-built tokens, and a specialist's own fan-out, which stays inside
the orchestrator boundary. The full rule: Dispatch protocol, step 3.

Fill these six slots, in this order, under the names given, and send nothing
else. No mode marker: see "The team's modes" (below).

```
Workdir: <absolute path, plus the branch or worktree when one was agreed>
Goal: <the outcome, in terms of behavior — one or two sentences>
Context: <prose: why the task exists, and what the agent cannot derive from
         the working directory. As long as it needs to be.>
Constraints:
- <one hard limit, and the reason for it>
- <one per bullet, or "none">
Acceptance:
- AC1: <one condition someone other than you can check without asking>
- AC2: <one per bullet>
Done when: <the observable condition that ends the task>
```

Beyond the template's own notes, in short. Each slot's full rule, and what a
brief must carry: `references/brief-detail.md`. Worked briefs, one task
written both ways included: `references/brief-examples.md`.

- **`Workdir:`** — written as the workspace check (above) records it.
- **`Goal:`** — the one bounded slot: concise, measurable, achievable.
  Background that will not fit moves to `Context:`. Why:
  `references/brief-rationale.md`.
- **`Context:`** — unbounded. It may not read "none", though `Constraints:`
  may, and it carries at least one sentence on why the task exists. Why:
  `references/brief-rationale.md`.
- **`Constraints:`** — a limit on a database names the category, never one
  activity.
- **`Acceptance:`** — required. Number the criteria. Each names a result,
  never a method. When this session ran `/workbench-core:intake`, copy its
  criteria here. Why: `references/brief-rationale.md`.
- **`Done when:`** — where the task stops, such as the change handed back
  uncommitted, not what the result must satisfy.

Every slot is required, and every dev-team agent refuses a brief that drops one.
**There is no length limit:** write the reasoning at whatever length it takes,
and write no shell command at any length. The must-omit list below is the whole
of the limit (why: `references/brief-rationale.md`).

### Must omit — the sub-agent decides these by reading the repo

- Shell commands of any kind, including the test, lint, and build invocations.
- Numbered step lists, and the order the work happens in.
- Named test file paths, and where new files go.
- The framework, the test runner, the assertion style, the library to use.
- Function, class, and variable names not already in the repo.
- Patches, code blocks, or file contents you want written verbatim.
- The commit message. That is `/workbench-dev-team:git-commit`'s job.
- Where the work runs or what it is written in: "outside the app", "a
  standalone script", "a one-off", "a quick Python check". The repo answers
  both questions. The incident: `references/brief-rationale.md`.

`Context:` is reasoning, never instruction. A step list does not become
acceptable by moving under it, and neither does a shell command.

### When a brief comes back

An agent hands a brief back for two different reasons, and they need different
answers from you.

- **Refused** — a slot is missing. The agent names it and does no work. Fill the
  slot, re-dispatch.
- **Questions** — every slot is there, but the brief still leaves the agent
  unable to reach the `Goal:` without guessing at something you own: which of
  two readings was meant, a decision settled in a conversation it never saw, a
  target that does not exist in the repo.

Expect the second one, and read it as the contract working rather than as an
agent stalling. Answer what the conversation already settles, relay to the human
what only the human can settle, then **re-dispatch the updated brief** —
SendMessage the answers to the agent that is waiting, or send it a corrected
brief. Never start a fresh agent on the old brief. The brief was what was wrong,
so a new agent walks into the same wall a few minutes later, at full cost, and
this time you have two of them waiting.

### The companion gate

A refusal means the rule worked. Report it, then re-dispatch. Never route
around a gate — only the human lifts one. What the workbench-core dispatch gate
checks, and what to do when it refuses a handoff:
`references/companion-gate.md`. Why the gate never classifies a dispatch:
`references/brief-rationale.md`.

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
(contract above) and makes no board calls. **Watson's Direct mode** runs the
`/workbench-dev-team:develop` workflow on any local repo and hands the work back
as an uncommitted tree; **Holmes's Local mode** reviews exactly that — the
uncommitted working tree in the brief's `Workdir:`, tracked changes and
untracked files — against the brief's `Acceptance:` list as its rubric, and
returns the verdict as prose. Holmes's Local mode makes no The Index call and
no GitHub write at all, so it is safe on any repo, governed or not. Both agents
run the off-board mode by default and switch to Index mode only on the
`Item ID: <n>` token, so a brief needs no mode marker.

**Holmes's Local mode does not review a PR.** Its only target is uncommitted
work. A pull request on a repo The Index does not govern has no agent path —
see the routing table above.

| The task | Dispatch |
|---|---|
| Implement, fix, refactor, add tests, edit docs | **Watson** (Index or Direct mode) |
| Triage an item, write acceptance criteria | **Lestrade** |
| Review a PR on a governed repo | **Holmes** (Index mode) |
| Review uncommitted local work | **Holmes** (Local mode) |
| Find where something lives, map a codebase | `Explore` |
| Sketch an approach before any code exists | `Plan` |
| Answer a question that writes no file | `general-purpose` |

## Roster — oversight at all times

Maintain a roster in the conversation. Post it when dispatching, update it when
notifications arrive, reprint it when the user asks "where do things stand?":

```
🕵️ Roster
| Agent | Task | Agent ID | Status |
|---|---|---|---|
| Watson | retry logic fix (foo) | a1b2… | 🔄 running |
| Watson | API docs (bar) | c3d4… | ✅ PR #42 opened |
| Holmes | review item 17 | e5f6… | 🔄 running |
```

- **Relay verdicts, not transcripts.** When an agent completes, report the
  outcome in two or three sentences — branch, PR link, verdict, blockers. Never
  paste its full output into the conversation; that defeats the lean-context
  point of delegating.
- **Failures surface verbatim.** An agent that errored or hit its budget cap is
  reported as such, with its last reported state. No silent retries.
- **Decisions come home through `AskUserQuestion`.** Watson's `/develop` skill
  returns a meaningful fork as a graded table and a recommendation. Holmes's
  Local mode returns a rubric dispute the same way. A brief can come back with
  questions only the human can settle, and a finished Direct-mode tree comes
  back as a commit offer. Put each one to the human through `AskUserQuestion`,
  never as prose. Put the recommended option first, and keep the agent's
  options and grades unchanged. Each option's description carries its grade
  and any warning, so the question stands on its own. A commit offer is asked
  alone, and follows the timing rule under "Direct-mode work comes back
  uncommitted": "Commit it" never leads before the human says their review is
  done. A question with no fixed choices still goes through the tool, because
  the dialog always offers Other. Ask each one right after the context it
  depends on first appears, with that context in prose just above the call, not
  at the end of the reply. SendMessage the answer back, or re-dispatch
  on an updated brief. The human decides; the team executes.
- **You never do the work.** If you catch yourself reading a repo to "just fix
  it quickly," stop — that's a Watson dispatch, and so is that same fix handed
  to a generic agent. A `PreToolUse` hook holds this line for you: `Edit`,
  `Write`, and `NotebookEdit` are denied when the main agent calls them, and
  reads and Bash stay open. A file written through Bash — `sed -i`, a heredoc,
  a redirect, a script — is still a write. The gate cannot see it, so the rule
  binds you there on your own. A deny means the rule worked. Report it, then
  dispatch. Never ask for `/orchestrator off` to clear your own deny — it is the
  human's own command (`/orchestrator on | off | status`), and only when they
  run it does inline writing open up.

## What the dispatcher does

A Watson Index-mode run ends in commits and pushes. The commit guard refuses
both to any sub-agent, and only the top-level loop of a `claude -p --agent` run
commits, with `WORKBENCH_DEV_TEAM_PIPELINE=1` to answer its prompts. The Agent
tool can start neither. `bin/dispatch-agent.sh` starts the run and exports the
flag.

`bin/dispatch-agent.sh` reads the same config — model, effort, fallback,
budget — runs the circuit-breaker pre-flight, backgrounds the run in auto mode
with nobody to answer a prompt, and prints the log path. The run's folder is
made in `~/Developer/scratchpad` and deleted when the run ends. How to read its
output and track the run: Dispatch protocol, step 4.

## Issue creation, two identities

When *you* ask for an issue in conversation, it's opened with `gh issue create`
so **you** (the human) are the author — the user's voice, same as comments.
Agent-authored follow-ups are the other case, and only Holmes opens them. On
either verdict, an unrelated latent hazard or systemic debt that clears his
materiality gate gets one, when no related open issue exists to expand. Watson
never opens one. He folds unit-belonging findings into the same PR. Holmes
opens his via `mcp__the-index__create_issue(agent: …)`, so the issue carries the
**agent's** GitHub App identity, lands on The Casebook, and gets the native `PBI`
type. That path is internal to Holmes — not an orchestration call you make; it
only works on governed repos (App-signed), and degrades to no Type on user-owned
ones.

## Model and effort come from the config, never from you

Nothing in this skill reads `~/.claude-workbench/dev-team-config.json`. When you
dispatch Watson, Holmes, or Lestrade by the public type, the dev-team mod reads
it at spawn: it runs the mode agent the token picks, with the configured `model`
and `effort`. All three ship `claude-opus-5-5[1m]` at `medium`.

**Never pass the Agent tool's `model` parameter to a dev-team agent.** It
accepts only an alias (`sonnet`, `opus`, `haiku`, `fable`), so it cannot carry
the exact ID, and the mod lets a model the caller named stand, so `opus` would
silently replace the pin with whatever the alias points at today. The Agent
tool has no effort, budget, or fallback parameter, so `maxBudgetUsd` and
`fallback` reach only the scheduled path. When the human edits the config, both
paths pick it up on the next dispatch.

## When NOT to orchestrate

- A one-line answer, a file lookup, a quick read — do it inline. Dispatch
  overhead isn't free, and reads and Bash stay open to you. Writing a file is
  never on this list — see "You never do the work" above.
- Work the scheduled Dispatch pipeline already owns (board items flowing
  through lanes) — leave it to the 20-minute tick unless the user asks for an
  immediate manual run.
