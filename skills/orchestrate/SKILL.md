---
name: orchestrate
description: Run the dev team (Inspector Lestrade, Dr. Watson, Sherlock Holmes) as background sub-agents from the current session, with per-agent model and effort carried by each agent's frontmatter, and route GitHub actions to the right executor (Index MCP vs gh CLI). Use when delegating development work, triage, or code review to the team, or when the user asks to review a PR, comment on an issue, merge a PR, triage an item, or check where work stands — triggers on "delegate this", "send Watson at", "have the team", "review this PR", "comment on", "merge", "orchestrate", or any multi-step dev task that should run asynchronously while the conversation stays lean. Also carries the routing rule that sends development to Watson, triage to Lestrade, and review to Holmes, and the five-slot brief template (Workdir / Goal / Context / Constraints / Done when) that every handoff is written to — read-only research dispatches included. Read it before picking any sub-agent, and whenever a dispatch gate refuses a handoff.
---

# Orchestrate — The Dev Team as Sub-Agents

You are the orchestrator. The work happens in sub-agents; the main conversation
holds only the roster, the verdicts, and the decisions. You dispatch, you track,
you relay — you do not implement, triage, or review in the main context.

## The team

| Agent | `subagent_type` | Role | Input contract |
|---|---|---|---|
| Inspector Lestrade | `workbench-dev-team:lestrade` | Triage — AC + WSJF; blocker sweeps | `Item ID: <n>` (triage one item) **or** `Repo sweep: <owner/repo>` (mark blocked-by dependencies across a repo's open issues) |
| Dr. Watson | `workbench-dev-team:watson` | Development | `Item ID: <n>` (board item) **or** the five-slot brief (Direct mode, ad-hoc dev) |
| Sherlock Holmes | `workbench-dev-team:holmes` | Code review | `Item ID: <n>` (board PR review) **or** the five-slot brief (Local mode, uncommitted working tree) |

Lestrade is coupled to The Index board — triage needs a `project_items.id`.
Watson and Holmes each carry an off-board mode that takes a five-slot brief
(contract below) and makes no board calls. **Watson's Direct mode** runs the
`/workbench-dev-team:develop` workflow on any local repo and hands the work back
as an uncommitted tree; **Holmes's Local mode** reviews exactly that — the
uncommitted working tree in the brief's `Workdir:` — against the brief's `Goal:`
and `Done when:` as its rubric, and returns the verdict as prose. Holmes's Local
mode makes no The Index call and no GitHub write at all, so it is safe on any
repo, governed or not. Both agents run the off-board mode by default and switch
to Index mode only on the `Item ID: <n>` token, so a brief needs no mode marker.
Lestrade's sweep mode takes a repo slug instead of an item id; dispatch it when
the user asks to "find blockers" or "mark dependencies" in a repo.

**Holmes's Local mode does not review a PR.** Its only target is uncommitted
work. A pull request on a repo The Index does not govern has no agent path —
see the routing table below.

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

The reason is skill loading, not seniority. A specialist loads
`/workbench-dev-team:develop` and then works *from the repo it was pointed at*:
it reads the repo's conventions, discovers the test framework, follows the
existing file layout, and sequences the work itself. `/develop` §1 is where the
discovery rule lives — don't restate it in a prompt, and don't pre-decide any of
it. A generic agent never loads that skill, so it guesses at conventions the
repo already states. That is also why the brief below omits implementation
detail: the detail belongs to the sub-agent, and only a specialist carries the
standard for choosing it.

**Read-only dispatches stay generic, and should.** `Explore`, `Plan`, and
`general-purpose` are the right call whenever nothing gets written. They are
generic in *destination* only — the brief below governs them exactly as it
governs a Watson build.

| The task | Dispatch |
|---|---|
| Implement, fix, refactor, add tests, edit docs | **Watson** (Index or Direct mode) |
| Triage an item, write acceptance criteria | **Lestrade** |
| Review a PR on a governed repo | **Holmes** (Index mode) |
| Review uncommitted local work | **Holmes** (Local mode) |
| Find where something lives, map a codebase | `Explore` |
| Sketch an approach before any code exists | `Plan` |
| Answer a question that writes no file | `general-purpose` |

## Model and effort come from the agent, never from you

Nothing in this skill reads `~/.claude-workbench/dev-team-config.json`: the
interactive path has no use for it. `/workbench-dev-team:setup` stamps each
agent's configured `model` and `effort` into its frontmatter (Step 6a), and the
harness reads the frontmatter when it spawns the sub-agent. All three ship
`claude-opus-5-5[1m]` at `medium`.

**Never pass the Agent tool's `model` parameter to a dev-team agent.** It
accepts only an alias (`sonnet`, `opus`, `haiku`, `fable`), so it cannot carry
the exact ID, and it overrides the frontmatter, so `opus` would silently replace
the pin with whatever the alias points at today. The Agent tool has no effort,
budget, or fallback parameter, so `maxBudgetUsd` and `fallback` reach only the
scheduled path. When the human edits the config, the scheduled path picks it up
on its next tick. This path picks it up at the next setup run, so say so.

## Check the workspace before you dispatch

**Branches and worktrees are wanted. The human picks them.** Most dev work lands
on a branch, and a PR is a normal finish line. What is not yours is creating the
branch or the worktree unasked. Before any dispatch whose work ends in a commit,
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

**Two Watsons on one repo need separate worktrees.** Ask the same way, name each
in its own brief, and pass `isolation: "worktree"` on the Agent call once the
human has agreed. One working tree holds one branch, so two runs sharing it
overwrite each other's edits.

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
   alias-only parameter would override it (see "Model and effort" above).
3. **Every handoff is a brief.** Sub-agents have no memory of this
   conversation, so send the five slots defined below and nothing else — for
   Watson's Direct mode, Holmes's Local mode, and the read-only `Explore`,
   `Plan`, and `general-purpose` runs alike. Research is not exempt, and that is
   the point. Three shapes are exempt: the two machine-built tokens
   (`Item ID: <n>` and `Repo sweep: <owner/repo>`, between them every Lestrade
   dispatch and every Holmes Index-mode dispatch), and a specialist's own
   fan-out, which stays inside the orchestrator boundary rather than crossing
   it.
4. **A Watson Index-mode run goes through the dispatcher, never the Agent
   tool.** That run ends in commits and pushes, and the commit guard refuses
   both to any sub-agent whose process does not carry
   `WORKBENCH_DEV_TEAM_PIPELINE=1`. The Agent tool cannot set an environment
   variable on the agent it spawns. `bin/dispatch-agent.sh` exports it, and
   takes the same item id:

   ```bash
   bash "$HOME/.claude-workbench/bin/dispatch-agent.sh" watson <item-id>
   ```

   It reads the same config — model, effort, fallback, budget — runs the
   circuit-breaker pre-flight, backgrounds the run, and prints the log path. A
   first line of `SKIP` (a run on that item is still alive) or `ESCALATE` (the
   breaker judges the item wedged) means nothing was spawned: relay it to the
   human rather than retrying. Track a spawned run from its log rather than from
   a completion notification, and keep the roster line updated from it. The Agent
   tool stays right for everything that writes no commit: Watson's Direct mode,
   Lestrade, Holmes, and every read-only dispatch.

Example — ad-hoc dev work. The prompt is the five-slot brief, contract below:

```
Agent(
  subagent_type: "workbench-dev-team:watson",
  // no model: Watson's frontmatter carries claude-opus-5-5[1m], and the alias-only
  // parameter would override that exact ID. Never pass one to a dev-team agent.
  run_in_background: true,
  description: "Expire stale cache entries",
  prompt: "Workdir: /Users/mike/Developer/bar (branch: fix/cache-expiry,
           off main — agreed in chat before dispatch)
           Goal: Cached API responses expire instead of being served
           indefinitely after the upstream record changes.
           Context: A stale price was served for two days after the
           upstream correction, and support caught it before we did. The
           cache predates the upstream's change feed, so nothing invalidates
           an entry today except a restart.
           Constraints:
           - No new dependencies. This service ships to air-gapped hosts,
             and every dependency is a manual review there.
           - Do not change the shape of the cache interface. Three other
             services call it and none of them are in this repo.
           Done when: Expiry is covered by tests, the suite is green, and the
           change comes back uncommitted with a proposed commit message."
)
```

## The brief — five slots, on every handoff

A dispatch prompt is a **brief**, not a script. It states an outcome, the
reasoning behind it, and the limits on reaching it. It does not describe how the
work is done.

**Every handoff uses it, read-only research included.** An `Explore` run that
writes nothing gets the same five slots as a Watson build. That is load-bearing
rather than tidy: it is exactly what lets the gate below stop guessing whether a
dispatch is code work. A template that applied only to work ending in a diff
would need someone — a hook, or you at speed — to classify each prompt first,
and that classification is the part that never worked.

**One dispatch is not a handoff under this rule: a specialist's own fan-out.**
The template governs the **orchestrator boundary** — a dispatch that leaves an
orchestrator for a specialist. Workers a specialist spawns inside a task it
already owns are that specialist's implementation, and they keep whatever prompt
shape that agent's own reference files define. Read it as a boundary, never as a
list of agents: a specialist that grows a fan-out later inherits the exemption
with no edit here. The measurement and the two other reasons behind the line:
`references/brief-rationale.md`.

Fill these five slots, in this order, under the names given, and send nothing
else. No mode marker: Watson and Holmes both run their off-board mode by default
and enter Index mode only on an `Item ID: <n>` token, so a brief that carries no
such token is already unambiguous.

```
Workdir: <absolute path, plus the branch or worktree when one was agreed>
Goal: <the outcome, in terms of behavior — one or two sentences>
Context: <prose: why the task exists, and what the agent cannot derive from
         the working directory. As long as it needs to be.>
Constraints:
- <one hard limit, and the reason for it>
- <one per bullet, or "none">
Done when: <the observable condition that ends the task>
```

**`Workdir:` is the absolute path, and the workspace when there is one to
state** — the branch or worktree the human agreed to, written beside the path.
A bare path carries no workspace decision and stays valid, which is most
dispatches. The section above is where that decision gets made.

**`Goal:` is the one bounded slot: one or two sentences, concise, measurable,
achievable.** Everything downstream checks a result against it — the agent's own
report, Holmes's AC lens, your roster line — and a paragraph is not something a
result can be checked against. Background that will not fit is not cut, it moves
to `Context:`, which exists so `Goal:` never has to carry it.

**`Context:` is unbounded.** It is prose, it may run as long as the reasoning
runs, and no length figure applies to it or to the brief as a whole.

**`Constraints:` is bullets, one limit per bullet, each carrying its own
reason.** A constraint without its reason gets obeyed literally and defeated in
spirit: the agent meets the letter, hits a surprise in the repo, and works
around the part that mattered because nothing told it what the limit protects.

**A limit on a database names the category, never one activity.** State the
connection the agent may execute against and forbid every other one, not the one
command you had in mind. "Don't run migrations against dev" left a seeder, a
truncate, and a raw query free to hit the same connection. Six near-misses met
the letter of limits like that one before the next lost 17,063 rows:

```
- Execute nothing against any database connection except <the designated
  test database>. Every other connection holds data we cannot rebuild.
```

**`Done when:` is an observable finish line** — a state you could check without
asking the agent what it meant.

**`Constraints:` may read "none". `Context:` may not**, and `Context:` carries
at least one sentence on why the task exists. The asymmetry is deliberate, and
`references/brief-rationale.md` says why.

Every slot is required, and every dev-team agent refuses a brief that drops one,
naming what is missing (`agents/*.md`, the brief contract) — this is a receiving
contract, not only a sending one.

**There is no length limit.** Write the reasoning at whatever length it takes,
and write no shell command at any length. The must-omit list below is the whole
of the limit; an earlier stated figure and why it went are in
`references/brief-rationale.md`.

### Must carry — the sub-agent cannot derive these

Omitting these causes the opposite failure: an agent inventing requirements,
which `/develop` tells it to refuse rather than guess.

- **The working directory**, absolute. The sub-agent inherits none from this
  conversation. It is often a repository, and does not have to be — a read-only
  research dispatch may point at a directory that is not one.
- **Hard constraints**: decisions the human already made, an interface that must
  not change, files that are out of bounds, a dependency ban, answers to forks
  already settled in chat.
- **The acceptance criterion**: what must be true of the result for it to count.
- **The definition of done**: the state that ends the task, and one the agent's
  lane can reach. A sub-agent cannot commit, push, or open a PR, so a Direct-mode
  or research brief ends at tests green and the work reported back; "a PR is
  open" belongs only to an Index-mode run.
- **The reasoning, in `Context:`** — the measurement, the incident, the argument
  that settled a fork, the reason this outcome is wanted over the obvious one.
  A constraint with its reason survives contact with a surprise in the repo; a
  bare constraint gets worked around. There is no task with nothing here: at
  minimum, why this task exists at all.

### Must omit — the sub-agent decides these by reading the repo

- Shell commands of any kind, including the test, lint, and build invocations.
- Numbered step lists, and the order the work happens in.
- Named test file paths, and where new files go.
- The framework, the test runner, the assertion style, the library to use.
- Function, class, and variable names not already in the repo.
- Patches, code blocks, or file contents you want written verbatim.
- The commit message. That is `/workbench-dev-team:git-commit`'s job.
- Where the work runs or what it is written in: "outside the app", "a
  standalone script", "a one-off", "a quick Python check". That framing once
  sent Watson to edit PHP with a Python script and to diff a Laravel app's data
  in Python instead of the app's own console and test suite. The repo answers
  both questions.

`Context:` is reasoning, never instruction. A step list does not become
acceptable by moving under it, and neither does a shell command.

### One task, both ways

❌ **Scripted** — most of it tells Watson what the repo already answers:

```
Workdir: /Users/mike/Developer/foo
1. Open src/retry.ts and find the backoff loop.
2. Set the base delay to 250ms and cap attempts at 5.
3. Add tests to tests/unit/retry.test.ts with Vitest describe/it.
4. Run `npx vitest run tests/unit/retry.test.ts` until green.
5. Then `npm run lint -- --fix` and `npm run build`.
6. Commit as "fix: retry backoff" and open a PR.
```

✅ **Briefed** — same task, five slots, and longer on the page for saying far
less about how:

```
Workdir: /Users/mike/Developer/foo (branch: fix/retry-backoff, off main —
you were on main and agreed to the branch before this dispatch)
Goal: The HTTP client retries a failed request on capped exponential
backoff instead of retrying immediately.
Context: Immediate retries turned a partial upstream outage into a full
one last Thursday: every client in the fleet re-hit a recovering service
in lockstep and put it back down. The cap of 5 is what the upstream's
rate limit tolerates before it starts refusing us outright.
Constraints:
- Keep the public client API unchanged. It ships in a released package
  and callers outside this repo are on the current signature.
- Never exceed 5 attempts. Past that the upstream stops answering us at
  all, which is worse than the failure being retried.
- No new dependencies. The retry helpers on offer all pull a scheduler
  we would then have to keep.
Done when: Retry timing and the attempt cap are covered by tests, the
full suite is green, and the change comes back uncommitted with a
proposed commit message.
```

The scripted version pins the file, the runner, the command order, and the
commit message. Watson reads all four out of the repo. The briefed version keeps
what is genuinely upstream of the repo — the cap of 5, the frozen API, the
dependency ban, and the branch you agreed to — and hands the rest back. The
branch is upstream of the repo like the rest of them: Watson cannot read which
one you picked. Each of the three constraints carries its reason, so none of
them reads as arbitrary, and an arbitrary-looking limit is the kind a sub-agent
negotiates with when the code makes it awkward.

### The companion gate

A `PreToolUse` hook in workbench-core checks **one thing**: that the prompt you
are dispatching uses this template. Five slot headers present, the call goes
through. One missing, the call is refused and the message names the slots you
dropped. It fails open rather than bricking a session, and it points back at
this skill.

- **It does not guess whether a dispatch is code work, and it does not decide
  routing.** Classifiers were built for that job, measured against real dispatch
  traffic, and were not good enough to keep. Requiring the template on *every*
  handoff is what let the guessing go.
- **Presence is all it checks, by design.** Whether the prose inside a slot is
  any good — whether `Goal:` states an outcome or a numbered implementation
  script — belongs to the receiving agent, the one holding the repo and the
  brief together. The hook regexes headers; the agent reads them. The recall
  figures behind both bullets: `references/brief-rationale.md`.
- **Neither slot order nor length is enforced there.** Order is worth keeping
  for readability, and refusing a well-formed brief over it would cost a real
  dispatch for nothing.
- **The two machine-built tokens are exempt** — `Item ID: <n>` and
  `Repo sweep: <owner/repo>`, matched whole rather than as a prefix.
  `bin/dispatch-agent.sh` assembles them from an id or a slug, so there is no
  brief to write, and refusing one would kill every scheduled tick at its first
  dispatch.
- **A refusal is refilable, not a dead end.** Take the prompt you were about to
  send, drop it into the five slots, cut everything on the must-omit list, and
  re-dispatch. That is the whole fix.
- **The gate is not the only check.** It reads slot presence; the agent reads
  what is in them. A brief that reaches an agent short a required slot comes
  back refused with the slot named, and one that is complete but unusable comes
  back as questions — both halves are in `agents/*.md`, and they bind every
  dev-team agent, including any added later.
- **A refusal means the rule worked.** Report it, then re-dispatch. Never route
  around a gate — only the human lifts one.

### Direct-mode work comes back uncommitted

**Watson's Direct mode ends in a working tree, not a commit.** The commit guard
refuses a sub-agent every commit and push, and a sub-agent does not merge. So
its report carries a diff summary and a proposed commit message instead, and the
tree is left as the change made it.

**Committing it is yours, and so is the push.** Tell the human the tree is
ready for their review, and carry the proposed message. Commit only after they
say "commit it" in chat, once their review is done. Then attempt the commit and
the push yourself. Claude Code's permission prompt is the mechanical backstop,
not the approval. The plain form the ask rules match is canonical in the
`/workbench-dev-team:git-commit` skill ("Committing and pushing"). Never send
the agent back to commit: only a foreground session reaches the human's prompt.

**Holmes can review it first.** An uncommitted tree is exactly what Local mode
takes, so a Watson Direct-mode result can go to Holmes on a five-slot brief
before the human sees the diff — the same review the board path gets, with no
board item and nothing posted to GitHub. Dispatch it the same way you dispatch
Watson, with `Workdir:` pointing at the tree Watson left and `Goal:` / `Done
when:` restating what Watson was asked for, since those two slots are Holmes's
rubric. Offer it rather than assuming it: the review costs a fan-out, and a
one-line change rarely earns one.

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
- **Decision forks come home.** Watson's `/develop` skill escalates meaningful
  forks as three options + recommendation. Relay them to the user untouched and
  SendMessage the answer back. The human decides; the team executes.
- **You never do the work.** If you catch yourself reading a repo to "just fix
  it quickly," stop — that's a Watson dispatch, and so is that same fix handed
  to a generic agent. A `PreToolUse` hook holds this line for you: `Edit`,
  `Write`, and `NotebookEdit` are denied when the main agent calls them, and
  reads and Bash stay open. A file written through Bash — `sed -i`, a heredoc,
  a redirect, a script — is still a write. The gate cannot see it, so the rule
  binds you there on your own. A deny means the rule worked. Report it, then
  dispatch. Never run `/workbench-core:orchestrator off` to clear your own deny
  — only the human asks for that toggle, and only then does inline writing open
  up.

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

A repo is governed when The Index's GitHub App is installed on it. Check, in
order:

1. `mcp__the-index__check_repo_access(repo)` — the authoritative answer,
   straight from the App's installation list. (Requires The Index ≥ the
   check-repo-access release; if the tool isn't in your tool list yet, fall
   through.)
2. Fallback: `mcp__the-index__list_items(limit: 100)` and scan for the repo
   among item `repo` fields. A hit proves governed; a miss is **inconclusive**
   — say so, and ask the user rather than silently treating the repo as
   ungoverned.

Cache the answer per repo for the rest of the session.

To dispatch Lestrade, or Holmes in Index mode, you also need the **item ID** for
the issue/PR (Holmes's Local mode needs none — it reads no board):
`mcp__the-index__find_item(repo, issue_number)` where available, else the
`list_items` scan. If the repo is governed but the item can't be resolved
(webhook lag, item not on the board), **stop and report** — never fall back to
`gh` for agent work products.

### Routing table

| Request | Governed repo | Ungoverned repo |
|---|---|---|
| "review this PR" | Resolve item → dispatch **Holmes** (`Item ID: <n>`) — formal signed review | Wants a GitHub review artifact → review inline, post via `gh pr review` as the user, after confirming. Conversational opinion → verdict in chat, nothing posted. **Unclear which → ask.** Holmes has no path here: Local mode reviews an uncommitted tree, never a PR |
| "review what I've changed" / "review this working tree" | **Holmes** Local mode (the five-slot brief, via the Agent tool) — reviews the uncommitted tracked changes and untracked files, verdict comes back as prose | same — Local mode makes no board call and no GitHub write, so the repo's governance is irrelevant |
| "comment on issue/PR" (user's words) | `gh issue comment` / `gh pr comment` — the user's voice | same |
| "create / open an issue" (user's words) | `gh issue create` — **the user's voice**, authored by you (the human); confirm repo + title first | same |
| "implement / fix / build X" | Item exists → **Watson** Index mode, dispatched with `bash "$HOME/.claude-workbench/bin/dispatch-agent.sh" watson <item-id>` (the Agent tool cannot give that run its pipeline flag). No item → ask: file it on the board, or Watson Direct mode off-board | **Watson** Direct mode (the five-slot brief, via the Agent tool; the diff comes back uncommitted) |
| "triage / write AC" | Resolve item → **Lestrade** (`Item ID: <n>`) | Draft AC inline — no agent |
| "merge this PR" | `gh pr merge` — **only on explicit request**, confirm repo + PR first. Never delegated to an agent (Holmes never merges; the MCP has no merge tool; the commit guard refuses a sub-agent's or the pipeline's `gh pr merge`). Board status follows via webhook | same |
| "where do things stand?" | Index read tools (`list_items`, `list_review_items`, …) + your roster | `gh pr list` / `gh issue list` + roster |

**Pass a gh body in a quoted heredoc or a file.** Before any `gh` call that
carries prose (a comment, an issue, a PR body, or release notes), read "Passing
a gh body" in `/workbench-dev-team:git-commit`. In short, write
`--body-file - <<'EOF'` (or `--notes-file -`), or name a file. Never write a
multi-line body in double quotes: the shell runs its backticks.

**Issue creation, two identities.** When *you* ask for an issue in conversation,
it's opened with `gh issue create` so **you** (the human) are the author — the
user's voice, same as comments. Agent-authored follow-ups are the other case:
Holmes (on approve) and Watson (on a change request) open theirs via
`mcp__the-index__create_issue(agent: …)`, so the issue carries the **agent's**
GitHub App identity, lands on The Casebook, and gets the native `PBI` type. That
path is internal to those agents — not an orchestration call you make; it only
works on governed repos (App-signed), and degrades to no Type on user-owned ones.

## When NOT to orchestrate

- A one-line answer, a file lookup, a quick read — do it inline. Dispatch
  overhead isn't free, and reads and Bash stay open to you. Writing a file is
  never on this list — see "You never do the work" above.
- Work the scheduled Dispatch pipeline already owns (board items flowing
  through lanes) — leave it to the 20-minute tick unless the user asks for an
  immediate manual run.
