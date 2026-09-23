# workbench-dev-team

A Claude Code plugin that runs a three-agent development pipeline against a GitHub project board. Items flow from triage → development → review without you touching them. Part of the [`claude-workbench`](https://github.com/mike-bronner/claude-workbench) marketplace.

## What it does

You work out of a GitHub project board. New issues land with no acceptance criteria. Well-refined ones sit in `Ready`. Work-in-progress has open draft PRs. PRs waiting on review pile up.

This plugin runs a team of agents on a local 20-minute clock that move items through the pipeline for you — and records what the reviews teach as it goes, so the team stops repeating itself:

- **Inspector Lestrade** (`claude-opus-5-5[1m]` at medium effort, Sonnet lenses) — triage. Reads items in the `Inbox` lane, writes acceptance criteria as a managed follow-up comment on the issue (the description is left untouched). Before scoring, the draft AC is checked by four blind lens sub-agents (malicious-compliance, testability, completeness, edge-case) that each try to find a gap Holmes and Watson would otherwise hit downstream — a much more expensive place to catch it, since Lestrade only ever sees an issue once while Watson and Holmes cycle back on it every bounce. Real gaps get folded in with one bounded tightening pass, never a re-verification loop; a lightweight comment marks when the AC changed this way. Scores WSJF, moves them to `Backlog` for your review. The WSJF write also lands two GitHub-native issue attributes The Index derives server-side: the issue **Type** (`PBI`) and an issue-level **Priority** (`Urgent/High/Medium/Low`) mapped from the WSJF — org-repo-only and best-effort. Also runs **blocker + consolidation sweeps**: after a repo gets fresh triage work, he re-reads all of its open issues and (1) marks blocked-by dependencies (native GitHub issue dependencies, additive only) so blocked items stay out of Dr. Watson's queue, and (2) consolidates follow-ups — folds `expand-from` comments into the issue they target and merges unmistakable near-duplicate follow-ups into the earliest anchor (native duplicate-close, high bar, ambiguous clusters flagged not closed) so the backlog stops sprawling.
- **Dr. Watson** (`claude-opus-5-5[1m]` at medium effort, $10/run cap) — development. Has two modes: **Direct mode**, the default (invocable as a sub-agent from Claude Code or Cowork for ad-hoc dev work — no The Index calls, just runs the `/develop` skill in a sub-agent context, and hands its work back as an uncommitted working tree for the dispatching session to commit) and **The Index mode**, entered only on an explicit `Item ID: <n>` token (Dispatch-driven, picks the top `Ready`/`In Progress` item, clones the repo, writes code and tests against AC, opens a PR, moves to `In Review`). Ambiguous prose resolves to Direct mode, never to the board. Both modes follow the `/develop` skill for the actual coding.
- **Sherlock Holmes** (`claude-opus-5-5[1m]` parent at medium effort, Sonnet lenses, $7/run cap) — code review. Has two modes, the same way Watson does: **Local mode**, the default (invocable as a sub-agent on a five-slot prose brief — reviews the *uncommitted working tree* in the given workdir, tracked changes and untracked files, against the brief's `Goal:` and `Done when:` as the rubric it never amends, and returns the verdict as prose) and **The Index mode**, entered only on an explicit `Item ID: <n>` token (Dispatch-driven, reviews the board item's PR and posts an App-signed verdict). Ambiguous prose resolves to Local mode, never to the board. Local mode makes **no The Index call and no GitHub write at all** — no review, no comment, no issue — so it is safe on any repo, and it closes the loop on Watson's Direct mode, whose output is exactly an uncommitted tree with no review path otherwise. It replaces the board-coupled steps rather than skipping them: the brief is the rubric, the workdir is the evidence room (never cloned, never written to — a harness-level guard enforces that, see **Local-review guard** below), and the repo's own suite is run locally in place of reading CI, because the toolchain objection that keeps Index mode off local test runs does not hold when the agent is already in the repo's directory on your machine. It records a vault note per local verdict but deliberately never touches the `top-lessons.md` digest, since local reviews are a separate population whose counts would skew a frequency ranking. Everything in between — the lens fan-out, adversarial verification, the memory pass, the finding-routing matrix — runs unchanged. The rest of this entry describes The Index mode: reviews open PRs, approves or requests changes. Escalates to you after 3 change rounds — but your input resets that count: comment, review, or weigh in on the PR and the window restarts from your last word, so an escalated PR you've decided on gets a fresh review instead of bouncing straight back. Reviews fan out across blind, read-only lens sub-agents (AC conformance, correctness, security, test honesty), with every blocker adversarially verified before it lands — a 3-agent red-team/blue-team/auditor pipeline handles security-lens findings every round and every other finding on the PR's first review, a single skeptic handles the rest on a re-review (the fullest check lands where it can prevent a second round, not just where the finding is scariest). After verification, Holmes (and only Holmes — no sub-agent touches the vault) checks each surviving finding against the memory vault for relevant context — a documented decision that reframes it, a past incident that reinforces it — always re-verified against the current tree before it's trusted, never used to waive a real defect or mark an AC item met. Only the parent writes, so there's still exactly one App-signed verdict. Falls back to a single inline pass when the fan-out is unavailable. Findings route by the **coherent unit of work** — *what the issue is really about* — then coupling and locality: a finding that **belongs to the unit blocks and is fixed in this PR**, even in untouched code the diff never caused, because a half-delivered unit is itself the defect. On top of that, anything actionable in the code a PR touched blocks (request changes, however minor), a hard correctness/security/test defect blocks wherever it lives, and — coupling beating locality — untouched code the diff made stale, inconsistent, or wrong blocks too. The self-test: *block and fix here if EITHER the diff caused it OR it belongs to the coherent unit* — a follow-up only when both are false. The precise routing rule lives in Holmes's canonical review contract (`agents/holmes.md`, §4e/§5). The **non-blocking follow-up tier is then gated by materiality, default-deny**: it holds only findings *unrelated* to the unit, and most of those — one-off cosmetics (naming, small duplication, style) — are **noted in the verdict, not tracked**. Only an unrelated **latent hazard** (security/data-integrity/correctness not live enough to block) or **systemic/substantial debt** (a schedulable chunk with its own testable "done") earns **one tracked issue**, tagged `Tracked under:`, capped at one new anchor per PR — the materiality bar that stops the follow-up flood. When Holmes does track, he **expands the earliest related open issue** in place (a comment Lestrade folds into its acceptance criteria) rather than opening a near-duplicate, and opens a new anchor via `create_issue` (App-signed as Holmes, board-added and `PBI`-typed) only when nothing related exists. A class of sites violating one *invariant* (a containment guard, a null-check, a helper every caller owes) is swept whole: if the class belongs to the unit it's folded into the PR; if it's an unrelated anti-pattern agents will replicate it becomes **one umbrella issue with a checkbox per site** — either way closing the class at once rather than minting a fresh single-site issue every review, the treadmill that otherwise turns one finding into an endless `#A → #B → #C` chain. A finding gets the **same disposition regardless of verdict**, so a clean PR never generates more tracked work than a messy one: on a change request, unit-belonging findings are blockers Watson folds into the **same PR**, unrelated cosmetics are optional (fix if cheap, else skip), and the unrelated hazard/debt tier is tracked exactly as on approval.

A fourth component — **Dispatch** — is the local scheduled task that polls the board every 20 minutes and fires the right agent for each pending item. Dispatch is the only thing that's scheduled; the three agents run as dispatched subprocesses.

### The feedback loop

Lestrade, Watson, and Holmes used to have no memory of their own reviews: nothing recorded *what* Holmes rejected, *why*, or *how* it got fixed, so the same lessons got re-taught every review (test-honesty is ~38% of all rejections, fail-open ~11%, doc-drift ~11%). There's no separate harvesting agent for this — **Holmes is the only one who holds both halves of a rejection** (what he flagged, and whether the next push actually fixed it), so he records it himself, live, at re-review: one atomic vault note per bounce or AC-dispute event, categorized against a fixed taxonomy, plus an incrementally-refreshed `dev-team/top-lessons.md` digest (recurring categories, frequency-ranked, each with the concrete prevention rule). **Watson reads that digest and searches the vault for anything task-specific before coding; Lestrade reads it before writing acceptance criteria**, so the pipeline gets smarter instead of repeating itself on both sides — what gets built and what gets asked for.

## Install

```
/plugin marketplace add mike-bronner/claude-workbench
/plugin install workbench-dev-team@claude-workbench
```

That installs the agents, the Dispatch prompt, and the bundled skills (see below). Nothing is scheduled yet.

## Bundled skills

The plugin ships three skills for general use, plus the agents' own reference skills:

- **`develop`** and **`git-commit`** — universal development standards. They register themselves globally via `session-warmup.md`, which workbench-core picks up at session start and injects into `~/.claude/CLAUDE.md`. They apply to every Claude Code / Cowork session, not just dev-team agents. Both are also packageable as `.skill` files for Claude Chat (Mac app) where plugins aren't supported but skills are. Require workbench-core 0.2.0+ for the session-warmup discovery mechanism — install it first if you don't already have it (Claude Code does not enforce plugin install order).
- **`orchestrate`** — runs the team as background sub-agents from any interactive session (see below). A `session-warmup.md` hint makes every session aware the team is available for delegation.

Four more skills exist for the agents rather than for you. **`comms-style`** is how Lestrade, Watson, and Holmes write every piece of prose that isn't code — ticket comments, PR bodies, review verdicts — modeled on ASD-STE100 (Simplified Technical English). **`holmes-review`**, **`watson-pipeline`**, and **`lestrade-triage`** hold each agent's long, situational procedure: each agent prompt in `agents/` is a thin router that keeps the always-relevant rules inline and points at `skills/<name>/references/` for the detail it only needs at one moment — Holmes's review phases and sub-agent prompt skeletons plus his Local-mode path, Watson's eleven-step Index-mode pipeline, Lestrade's acceptance-criteria lenses and Sweep mode. The router pattern mirrors `git-commit`, and it keeps the per-dispatch prompt small without putting any rule out of reach.

Plugin configuration lives in a slash command (`/workbench-dev-team:setup`), not a skill — see the [Setup](#setup) section below.

### `develop`

Universal dev workflow + standards: orient before writing, plan before coding, atomic commits, every change gets a test, no committed secrets, lint before pushing. Triggers whenever code is being implemented, fixed, refactored, or tested — manual or agent-driven.

Includes a **decision protocol** that requires presenting three options to the human (with reasoning and a recommendation) for any meaningful fork — implementation approach, library choice, scope decisions, naming. The human decides, the agent executes. Trivial choices (mechanical translation, following existing repo conventions, one-line obvious fixes) are exempt.

Also defines the **commit approval gate** (see [Commit approval gate](#commit-approval-gate) below): a sub-agent commits, merges, and pushes nothing, and no foreground `git commit` lands without your explicit approval of the diff and message.

Used by Watson internally in both operating modes. Also invocable directly in any plugin-aware Claude session.

### `git-commit`

Generates commit messages using Conventional Commits + Gitmoji format. Triggers whenever a commit message is being composed — manual, scripted, or agent-driven (including Watson's PRs).

Format example:

```
feat: ✨ Add email validation endpoint.

Fixes: #789
```

Full type and emoji references at `skills/git-commit/references/`.

### `orchestrate`

Turns the current session into the team's orchestrator: dispatches Lestrade, Watson, and Holmes as **background sub-agents** (Agent tool, `run_in_background`), passing each agent's model from the shared config; maintains a roster table of who's working on what; relays verdicts and decision forks back to you; follows up on running agents via SendMessage. The main conversation stays lean — sub-agents do the heavy work in their own contexts and return summaries.

Watson supports brief-driven **Direct mode** for ad-hoc dev work with no board item, and Holmes a brief-driven **Local mode** that reviews the resulting uncommitted tree. Only Lestrade is Index-coupled and needs a board item ID.

The skill also fixes **who gets dispatched, and what they're told**. Routing covers all three specialists: development goes to Watson, triage to Lestrade, review to Holmes, and the shape of the request says which. Anything ending in a changed file is Watson's, never `general-purpose` — a specialist loads `develop` and discovers the repo's conventions and test framework for itself, a generic agent doesn't. Read-only dispatches (`Explore`, `Plan`, `general-purpose`) stay legitimate and are called out as such.

**Every handoff is written to a fixed five-slot brief** — `Workdir:` / `Goal:` / `Context:` / `Constraints:` / `Done when:` — read-only research dispatches included, which is what makes classifying a prompt as code work unnecessary in the first place. `Workdir:` is the absolute path, plus the branch or worktree when the human settled one (`Workdir: /Users/mike/Developer/foo (branch: fix/retry-backoff)`); a bare path stays valid and means there was no workspace decision to record. `Goal:` is bounded at one or two sentences, because it's the only slot tight enough to check a result against; `Context:` is prose and deliberately unbounded, since that's where the reasoning goes so `Goal:` doesn't have to carry it; `Constraints:` is bullets that each state their own reason, because a constraint without its reason gets obeyed literally and defeated in spirit. No length limit is stated anywhere — length was only ever a proxy for prescriptiveness, and the must-omit list (shell commands, numbered steps, named test paths, framework choices) attacks that directly. `Constraints:` may read "none"; `Context:` may not, and carries at least one sentence on why the task exists. The brief binds the **receiver** too, and in two ways: every agent in `agents/` refuses a brief missing a slot and names what's missing, and an agent handed a complete-but-unusable brief stops and sends its questions back to the orchestrator instead of guessing — the bar there is blocking uncertainty only, so anything short of it proceeds with the assumption stated. The two fixed dispatch tokens (`Item ID: <n>`, `Repo sweep: <owner/repo>`) are exempt from both, since they aren't briefs. A third exemption is the **orchestrator boundary** itself: the template governs a dispatch that leaves an orchestrator for a specialist, and a specialist's own fan-out to internal workers is outside it. The measurement behind the rule already excluded that traffic — of 622 dispatches, the 422 sent from sessions that were themselves agent runs were counted as correct behaviour — the parent holds every fact those workers need, so `Context:` has nothing to recover, and their prompts are written against measured cost rather than to a template. It's stated as a boundary and not as a list of agents, so a specialist that grows a fan-out later inherits it with no edit. A companion `PreToolUse` gate in workbench-core checks one thing — that the slots are present — and refuses a handoff that drops one; judging whether the prose inside them is any good is the receiving agent's job, not a shell script's.

**The orchestrator asks before a branch or a worktree is created.** Not a prohibition — branches and worktrees are the wanted outcome of most dev work, and a PR is a normal finish line. What changed is who decides. Ahead of any dispatch whose work ends in a commit, the skill reads the target tree and asks in three cases: on `main`/`master`/`trunk` it proposes a branch name; on a feature branch already carrying unrelated work it names what's there and proposes a branch off the base; inside a worktree it confirms that worktree is the one meant for this task. All three end in a question to you, never in a refusal, and your answer is recorded in the brief's `Workdir:` slot so the sub-agent works where you said. Two Watsons on one repo still get separate worktrees (`isolation: "worktree"`) — asked for the same way. The reasoning, including why the answer widened `Workdir:` instead of adding a sixth slot, sits in `skills/orchestrate/references/brief-rationale.md`, which loads only when a rule is challenged rather than on every orchestration.

The skill also **routes GitHub actions to the right executor**. Two rules: (1) *agent work products* (formal reviews, AC, status moves) only ever go through The Index, signed as the dispatched agent — never `gh`; (2) *your own actions* (comments you dictate, merges you order) go through `gh` under your identity, on any repo. Whether a repo is Index-governed is answered by `check_repo_access` — a server-side tool that checks The Index GitHub App's installation list (spec in `THE_INDEX_HANDOFF_ROUTING.md`; until it ships, the skill degrades to a `list_items` scan and says so). Merges are never delegated to agents and only happen on your explicit request.

## Commit approval gate

**A sub-agent does not commit, does not merge, and does not push. In the foreground session, every `git commit` requires your explicit approval.** Non-negotiable, and enforced by the harness rather than by prose — prose alone drifts, and this gate has the measurements to prove it.

A plugin `PreToolUse` hook ([hooks/hooks.json](hooks/hooks.json) → [hooks/scripts/commit-approval-gate.sh](hooks/scripts/commit-approval-gate.sh)) sorts every Bash call into one of three lanes, in this order:

| Lane | Recognized by | What it may do |
|---|---|---|
| **Scheduled Index pipeline** | `WORKBENCH_DEV_TEAM_PIPELINE=1` on the process | Commit, merge, and push unattended |
| **Sub-agent** | a non-empty `agent_id` in the hook payload | None of the three, and no approval path is offered |
| **Foreground session** | an empty `agent_id` | `git commit` once you have approved it; merge and push are your own business |

**Why it denies rather than asks, since v0.44.0.** The hook used to return `permissionDecision: "ask"` and it never stopped a single commit. A hook's `ask` is *classifier-approvable*: under `permissions.defaultMode "auto"` the auto-mode classifier answers it, and no human is ever prompted. The harness's own safety checks pair `ask` with a `classifierApprovable: false` marker, and that field is not in the hook output schema. Of the verdicts a hook can return, only `deny` binds. Confirmed live, twice: a `git commit` completed unprompted in the same session where workbench-core's delegation gate — which returns `deny` — blocked a `Write`.

**What a refusal looks like, since v0.47.0.** Both gates in this plugin write the refusal twice over, to the two channels a `PreToolUse` hook has. They were measured on Claude Code 2.1.274 (`insights/2026-09-17-hook-message-channels-measured.md` in the memory vault): `permissionDecisionReason` becomes the `tool_result` and is the text a **person** reads, while `additionalContext` survives a deny and arrives in its own block that **only the model** reads.

```
permissionDecisionReason   🛑 Blocked: `git commit`. It needs your approval first.
additionalContext          Commit approval gate (workbench-dev-team). Show the human the staged diff
                           and the proposed commit message. Then run this exact command … <request id> …
```

The human line is one line, under 120 characters, and it names the **action that was gated** plus at most one clause they can act on. It carries no request id, no approval command, and no policy — those are things only an agent does, and at 922 characters they were the wall a person had to read past to learn they had tried to commit. It also names the verb the call actually ran, so a refused `git push` says `git push`.

**The split cannot weaken the gate, and the direction is what makes that true.** Losing the model's half would cost the agent the request id and the approval command, so no approval could be granted and the commit would stay refused. Nothing that decides a verdict lives in either message. No Markdown emphasis is used anywhere either: whether a client renders these fields is unsettled and the model receives the raw source regardless, so emphasis comes from position (the action leads the line) and from backticks, which read as a quoted command either way. `workbench-core`'s seven gates follow the same format — see "How a gate speaks" in its README.

**Why a sub-agent gets no path at all, since v0.45.0.** The approval below rests on a `permissions.ask` rule raising a prompt a human answers. That holds in a foreground session and fails in a sub-agent: the sub-agent's request is background and non-interactive, so the ask resolves with nobody attached, and the approval command is a Bash command the agent itself holds. It was measured doing exactly that — 48 self-approvals in the gate's first day, a median 3.4 seconds between the denial and the approval, 17 unapproved commits on `main` out of a single Watson run. Three seconds is not a human reading a diff. So a sub-agent is refused outright: **the denial prints no request id and no command, and writes no pending record**, and the lane is decided *before* any record is read, so a record planted by hand buys nothing either.

**A refused sub-agent hands the work back.** It leaves the tree uncommitted and reports the diff and the proposed commit message to the session that dispatched it; that session commits, where a prompt does reach you. Watson's Direct mode is built around this.

**What it refuses is a rule, not a list:** every git verb that writes a commit, integrates another history, or publishes one, plus `gh pr merge`. The membership that rule currently produces is the `GATED_GIT` set in the hook, which is the only place it is enumerated — `git pull` is in there because it merges. Matching `git commit` alone is exactly what left merge and push open before: a list, one verb wide.

**How a foreground approval happens.** The denial is not a dead end, it is an instruction:

1. The gate denies the commit. You read ``🛑 Blocked: `git commit`. It needs your approval first.``; the agent reads the request id and the instructions in `additionalContext`.
2. The agent shows you the diff and the proposed message (the prose layer, now with teeth).
3. The agent runs `bash "$HOME/.claude-workbench/bin/approve-commit.sh" <id> "<subject>"`. Two `permissions.ask` rules cover that command, so the harness raises a **real** prompt: permission rules are evaluated before the classifier in every mode.
4. You answer the prompt. That answer is the approval. `approve-commit.sh` confirms it back in one line — `✅ Approved: <the commit subject>` — and never reprints the command, which you have already seen twice by then. The agent re-runs the same `git commit`, and the gate steps aside once.

`bin/approve-commit.sh` is installed at that stable path by `/workbench-dev-team:setup`, which also adds the rules. **It refuses to approve anything while the rules are missing, or when run from any copy but the installed one** — a half-finished setup blocks commits instead of waving them through. `Bash(git commit:*)` is deliberately *not* an ask rule: an ask rule always prompts, and the headless pipeline has nobody to answer it (workbench-core's rails exclude it for the same reason).

**A message kept in a file is approved on the same terms.** `git commit -F <path>` is the shape to prefer, because the gate makes the command run twice and a message written inline is printed twice in full in your transcript. The subject you read still has to be the real one, so `approve-commit.sh` reads the first line of the file git will read — `-F <path>`, `--file=<path>`, `--file <path>`, and a cluster like `-aF`, with variables in the path resolved from the command's own assignments and from the environment, never by running a shell on caller-controlled text. Every check that decides whether an approval may be granted finishes before a byte of that file is read, and the file supplies one thing: the subject. So a file can refuse an approval or name a commit, and never widen one. A path that will not resolve, a file that will not open, a file with no message in it, and `-F -` (standard input, gone by the time an approval runs) each refuse and name their own case. One consequence is worth stating plainly: the approval covers the command, so a file rewritten between the prompt and the commit changes the message without changing what was approved.

**One approval covers one commit, and nothing else.** Each request id is a hash of the session id, the agent id, and the exact command text. Two sessions never share an approval, editing the command voids it, and no sub-agent can spend one — it is refused before the record is even read. The record is deleted the moment a commit uses it, and it expires after 15 minutes unused.

**Pipeline carve-out.** A denial cannot be answered in a headless run, so an ungated pipeline would deadlock at its first commit. The hook therefore stays silent for one signal and one only: `WORKBENCH_DEV_TEAM_PIPELINE=1`, exported by [`bin/dispatch-agent.sh`](bin/dispatch-agent.sh) onto the `claude -p` process it spawns. In the pipeline, board dispatch is the approval and Holmes review + your PR merge is the human gate. Any other value — `0`, empty, `true`, absent — gates the commit. The carve-out is checked first of all, so the pipeline needs no approval record, no writable state directory, and no session id — and a scheduled run keeps committing even though it is, itself, an agent run.

**So an Index item dispatched from a conversation must go through the dispatcher.** The Agent tool cannot set an environment variable on the agent it spawns, so an Index-mode Watson dispatched that way is a sub-agent with no flag, and it is refused at its first commit and at every CI-fix push. Dispatch it with `bash "$HOME/.claude-workbench/bin/dispatch-agent.sh" watson <item-id>` instead; the Agent tool stays right for Direct mode, which commits nothing. The `orchestrate` skill carries this routing.

The pipeline signal is per-process, and that is the whole point. It reaches the dispatched agent and its children, and nothing else. An interactive session running beside a scheduled tick never sees it, so it never inherits the carve-out.

This replaced a live-PID `/tmp/watson.lock` check, which answered "is a pipeline running on this host?" rather than "is this process the pipeline?" — and so exempted every concurrent interactive session for the life of a tick. That leak once let four unapproved commits land across two interactive Watsons. Dropping the lock made the gate stricter, not looser. Do not reintroduce a host-wide substitute, and note that the payload's `agent_type` is not a candidate for the sub-agent lane either: it is present for a scheduled and an interactively dispatched agent alike, so it cannot tell them apart. `agent_id` can, the harness supplies it rather than the command, and the approval records already in the state directory confirm both of its values.

**What this gate is not.** It is not anti-evasion machinery. It reads the command an agent asked to run, so a verb hidden inside `bash -c` or written by a script is not its subject, and in the foreground lane the approval record is a file that anything holding Bash can write. An invocation of `approve-commit.sh` spelled differently from the two rules (`sh <path>`, or the path without the `bash` prefix) is not matched by them and so is not prompted, which is why the denial prints the exact command to run. A hook payload that will not parse still yields no opinion, as it always has. What it does guarantee: a sub-agent's commit, merge, or push is refused with nothing to run in reply, a foreground commit cannot happen *silently*, and every failure of the gate's own machinery — missing rules, unwritable state, no session id — refuses the commit rather than permitting it.

Tests: `hooks/scripts/test-commit-approval-gate.sh` (97 cases — detection, non-commit silence, the two-channel split asserted field by field (the human line's exact text, its one-line length, and the absence of the id, the command, the policy and any Markdown emphasis from it; the context dictating the approval prompt's `description` and still carrying the id), the full approval lifecycle, the session/command binding, the sub-agent lane in full (every refused verb, no id and no approval command in *either* channel, no record written under its own key, and a hand-planted approval buying it nothing), two cases pinning `agent_id` rather than `agent_type` as the lane signal, the foreground lane keeping merge and push, the fail-closed paths each asserted by their own human line, the carve-out's exact-match semantics including a flagged agent run, a guard proving no path can return `ask` again, and a two-part regression guard proving a live `watson.lock` no longer bypasses). `bin/test-approve-commit.sh` (102 cases — every refusal asserted twice, by exit status and by the commit still being denied afterwards, the end-to-end deny → approve → commit-once path, the receipt naming the commit without reprinting the command on both the labelled and unlabelled paths plus its request-id fallback, a sub-agent that is issued no id and cannot spend the foreground's, and the message-file path in full: each spelling git accepts, a path built from a variable the command assigns or the environment carries, each unresolvable, unreadable, relative, empty and standard-input case refusing by its own named message, a label checked against the file's first line rather than the command text so a path fragment cannot pass as a subject, and the approval staying bound to the command when the file is rewritten under it). `commands/test-commit-approval-setup.sh` (19 cases — the setup block is extracted from the Markdown and run for real against a sandbox `HOME`).

## Local-review guard

**A Holmes Local-mode review reads your working tree and runs your test suite. It cannot write to either.** Enforced by the harness, and for the same reason the commit gate is: the prohibition was already prose at five separate sites across two files, and sat verbatim in every sub-agent prompt Local mode dispatches, and on the mode's first real exercise a lens sub-agent ran `chmod` against the tree under review and changed a script from 755 to 644. It disclosed the breach itself. Prose in an agent prompt is advisory and drifts under pressure.

This is a **second, independent** hook ([hooks/scripts/local-review-guard.sh](hooks/scripts/local-review-guard.sh)), living beside the commit gate rather than inside it — that gate's lanes and approval records are load-bearing for every commit here and are untouched. It covers three events:

| Event | What it does |
|---|---|
| `PreToolUse` on `Agent` | A Holmes dispatch whose prompt is a prose brief — Local mode, not an `Item ID:` token — **arms** a record for that session, naming the brief's `Workdir:` |
| `PreToolUse` on `Bash` | A Bash call from a **sub-agent** of an armed session is **denied** when it mutates a working tree |
| `PostToolUse` on `Agent` | The Holmes dispatch returned, so the hold is **released**. Holds are counted, so two reviews in flight need two releases and a lens returning mid-review releases nothing |

**What it refuses is a rule, not a roster — and the rule is inverted.** `GIT_READ_ONLY` in the hook enumerates git's *reading* verbs, and every other git verb is refused. That is the opposite of the list it replaces, which named stash, checkout, reset and clean and therefore never saw `git restore` — the modern spelling, and the single most destructive command available in this context, since it discards precisely the uncommitted change the mode exists to read. A verb git ships next year is refused on the day it ships, and a verb missing from the read-only set costs a denied read rather than an allowed write. Beside git: `chmod`, `chown`, `rm`, `mv`, `truncate` and their siblings (a file-mode change *is* a write, and is what the breach used), `sed -i`, and any `--write` / `--fix` / `--in-place` flag. Redirection is judged by target path instead of refused outright, so `git diff HEAD > /tmp/x.diff` still works.

**Reads and the suite stay legal**, which is the binding constraint: a guard that stops either one makes the mode useless and gets switched off. `git status`, `git diff HEAD`, `git ls-files`, `git show`, `grep`, and `bash run-tests.sh` all pass. The temporary files a suite writes are invisible to the hook, because it reads the command the agent asked to run and not what that command's script goes on to do — the same boundary the commit gate draws, working in the mode's favour here.

**The signal is per-session, never host-wide.** The record is keyed on the harness-supplied `session_id`, and enforcement additionally requires a non-empty `agent_id`. Your own editing in the window that dispatched the review keeps working, and a concurrent session is untouched entirely. A bare "a local review is in progress" marker would be the `watson.lock` leak with the sign reversed: that file wrongly *exempted* every concurrent session, and a review marker would wrongly *gag* them. The verdict is `deny` for the same reason the commit gate's is — of the three a hook can return, only `deny` binds.

**What it does not cover**, stated plainly in the hook's own header: a verb inside `bash -c` or inside a script; a local review a foreground session runs inline, which carries no `agent_id`; and a review that was never armed, which fails open silently. That last one is exactly why the prose prohibition stayed where it was — this is a backstop, never a replacement. While a record is live every sub-agent of that session is held to reading, bounded by the release and by a 2-hour TTL.

The scheduled Index pipeline is carved out by `WORKBENCH_DEV_TEAM_PIPELINE=1`, checked first of all, so a board review is never affected.

It refuses in the same two-channel shape as the commit gate, described above. You read ``🛑 Blocked: `chmod`. A local review is reading this working tree.``, with its own action word per rule — `git restore`, `sed -i`, `prettier` with a rewrite flag, redirecting output into the tree under review — and the reason, the tree's path, and the allowed alternatives go to the model in `additionalContext`.

Tests: `hooks/scripts/test-local-review-guard.sh` (92 cases — what arms and what does not, every command the reference tells a reviewer to run staying legal, every mutation class refused including the breach command verbatim, redirection judged by target, the per-session scope with a concurrent-session regression guard, a guard proving no path can return `ask`, the arm/release lifecycle with hold counting and TTL expiry, the fail-safe inputs, the two-channel split asserted field by field with one action word per rule, and the `--classify` mode). `agents/lint-holmes-local-mode.sh` feeds the reference's fenced blocks to that same classifier, so the shipped documentation and the shipped enforcement cannot drift apart.

## Configuration — models, effort, fallback, budget

Per-agent model, effort, fallback chain, and budget caps live in a single file, written by `/workbench-dev-team:setup` with these defaults and never overwritten on re-run (your edits survive plugin updates):

```json
// ~/.claude-workbench/dev-team-config.json
{
  "agents": {
    "lestrade": { "model": "claude-opus-5-5[1m]", "effort": "medium", "fanout": true, "lensModel": "sonnet", "fallback": "haiku" },
    "holmes": { "model": "claude-opus-5-5[1m]", "effort": "medium", "fanout": true, "lensModel": "sonnet", "maxBudgetUsd": 10.00, "fallback": "sonnet" },
    "watson": { "model": "claude-opus-5-5[1m]", "effort": "medium", "maxBudgetUsd": 10.00, "fallback": "sonnet,haiku" }
  }
}
```

Both dispatch paths read it:

- **Scheduled (Dispatch)** passes `--model`, `--effort`, `--fallback-model`, and `--max-budget-usd` on each `claude -p` invocation, each only when set. CLI flags override agent frontmatter (verified empirically), so a config edit takes effect on the next tick with no plugin files to touch — on this path. The interactive one below is the exception.
- **Interactive (`orchestrate`)** passes no `model` to the Agent tool. That parameter accepts only an alias (`sonnet`, `opus`, `haiku`, `fable`), never a full model ID, and it overrides the agent's frontmatter. The Agent tool has no effort, budget, or fallback parameter at all. So `model` and `effort` both reach this path through the agent definition: setup stamps each agent's configured values into its frontmatter (and removes a line the config gives no value for), and the harness reads them there when it spawns the sub-agent. The frontmatter `model` field takes a full ID, which is what keeps the agents on `claude-opus-5-5[1m]` here. `maxBudgetUsd`/`fallback` have no equivalent route and stay scheduled-path only (a model error there surfaces immediately for you to handle).

Holmes also carries two optional review knobs: `fanout` (bool, default `true`) toggles its multi-lens review fan-out, and `lensModel` (default: Holmes's own `model`) sets the model its lens and skeptic sub-agents run on. Both default cleanly when absent. The optional `fallback` knob (any agent) is a comma-separated model list handed to `--fallback-model`, so a dispatch degrades to the next model when the primary is overloaded or unavailable — e.g. a retired model — instead of failing; `maxBudgetUsd` caps per-run spend (Watson defaults to `10.00`; Holmes's is optional). All default cleanly when absent.

**All three agents ship `claude-opus-5-5[1m]` at `medium` effort**, in the config and in their frontmatter, so they run on exactly that on both paths. The model is the exact ID rather than the `opus` alias, because the alias moves to a new release without anyone approving it. The `[1m]` variant is there because the agents budget about 250k tokens of working context, which the standard window may not hold: the pin holds the model still, it does not shrink the context. `medium` covers all three, Holmes included, because Anthropic's Opus 5.5 migration guidance reports Opus 5.5 at `medium` beating Opus 5 at `high` on coding, and catching more bugs with fewer false alarms in code review. Speed and permission mode stay unpinned: agent frontmatter has no speed key, and a pinned `permissionMode` could override the `--dangerously-skip-permissions` the headless scheduled path depends on.

**Two environment variables still override the pins, on purpose.** They are the deliberate opt-outs for a project that needs another model or effort. `CLAUDE_CODE_SUBAGENT_MODEL` together with `CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1` beats the frontmatter `model`. Without `FORCE`, the pin wins. `CLAUDE_CODE_EFFORT_LEVEL` is recorded as beating `--effort`, so it still moves a scheduled run's effort. How it ranks against a frontmatter `effort` on the interactive path is not verified.

**An existing config is not moved onto the pins silently.** Setup never overwrites the config file, so an install from before the pins still carries the old defaults (Watson `opus` with no effort, Holmes `opus` at `high`, Lestrade `sonnet` at `high`). Dispatch passes those as flags, which beat the frontmatter, and Step 6a stamps them over it, so the old values win on both paths. Re-running setup finds every agent whose `model` or `effort` differs from the pin and asks you, one question per agent, whether to replace them. The question shows the current values and exactly what replaces them. A yes writes only that agent's `model` and `effort`. A no leaves the entry untouched, and setup asks again on its next run. `commands/test-config-pin.sh` runs the check and the replacement against fixture configs. `agents/test-effort-stamp.sh` holds the config and the frontmatter to each other in both directions, and fails unless every agent ships exactly the pin.

**Edit the config, then re-run `/workbench-dev-team:setup`:** the scheduled path re-reads the file on the next tick, but interactive dispatch reads the stamp, and a plugin update resets it to the shipped defaults. Missing file, missing key, or malformed JSON all fall back to the defaults above; dispatch never blocks on config problems.

## Setup

After `/plugin install`, run this in any Claude Code session:

```
/workbench-dev-team:setup
```

It walks you through cadence selection (20 or 30 min), Keychain seeding for any missing credentials, The Index MCP registration, log directory and agent-config creation, and Dispatch scheduled-task registration. Idempotent — re-run any time to refresh the OAuth token, re-register the MCP, or change cadence. Your `dev-team-config.json` edits are never overwritten.

Prerequisites on your machine: `gh` (authenticated), `jq`, `security` (built into macOS).

You'll be prompted in chat for any of these Keychain entries that aren't already present:

| Entry | Purpose |
|---|---|
| `the-index-mcp / client-id` | The Index OAuth client ID |
| `the-index-mcp / client-secret` | The Index OAuth client secret |
| `github-cli / token` | GitHub token for dispatched agents (auto-extracted from your existing `gh auth login` Keychain entry when present) |
| `claude-code / oauth-token` | Claude Code OAuth token for scheduled `claude -p` invocations. Get one with `claude setup-token` |

### What `/workbench-dev-team:setup` does, in order

1. **Verifies prerequisites** (`gh`, `jq`, `security`) and Keychain credentials; prompts for anything missing.
2. **Fetches an OAuth bearer token** from The Index (client_credentials grant, 1-year lifetime).
3. **Registers The Index MCP** with Claude Code at user scope, passing the bearer via `--header`. This makes `mcp__the-index__*` tools available to every future Claude Code session, including the dispatched agents.
4. **Creates the log directory** at `~/.claude-workbench/dev-team-logs/` and **writes the default agent config** to `~/.claude-workbench/dev-team-config.json` if (and only if) it doesn't already exist.
5. **Installs the commit-approval command** at `~/.claude-workbench/bin/approve-commit.sh` (after running its own test suite) and adds the two `permissions.ask` rules that make running it raise a real prompt. Without this step the [commit approval gate](#commit-approval-gate) denies every foreground commit and nothing can clear it — it fails closed, on purpose. (It changes nothing for a sub-agent, which has no approval path either way.)
6. **Resolves and verifies the orchestrator prompt** — takes the install path from `~/.claude/plugins/installed_plugins.json` (never the running `${CLAUDE_PLUGIN_ROOT}`, which can be a frozen per-session snapshot), strips the frontmatter, and refuses to continue unless the resulting body still has its expected structure — all three dispatch lanes, per-item in-flight locks, the circuit-breaker block, and a plausible size. The checks are derived from the body rather than matched against a list of agent names. Fails closed: an unverifiable body is never deployed.
7. **Registers the scheduled Dispatch task** by calling `mcp__scheduled-tasks__create_scheduled_task` (or `update_scheduled_task` if it already exists) directly from the running session. Task ID: `workbench-dev-team-dispatch`. Cron: `*/20 * * * *` (or `*/30` if you chose 30 min).

Re-run the skill any time you need to refresh the OAuth token, re-register the MCP, or change the Dispatch cadence. **Also re-run it after a plugin update that changes Dispatch's flow** (a change to `scheduled-tasks/orchestrator.md` itself, not the agent contracts): steps 5–6 read that file, strip its frontmatter, verify the body, and pass it as the scheduled task's prompt, so the deployed task holds a *baked-in copy*. A plugin update refreshes the file on disk but not the running task — the re-run redeploys the fresh orchestrator body. (Agent definitions and skills are read live per dispatch, so those need no re-run — only the scheduled Dispatch prompt is baked in.)

## How it works

```
GitHub webhook ──► The Index (MCP server, OAuth 2.1)
                              ▲
                              │ MCP tool calls
                              │
     scheduled Dispatch task (every 20 min, local)
                              │
                              ▼ nohup claude -p --agent ... &
                  ┌───────────┬───────────┬───────────┐
                  ▼           ▼           ▼           
              Lestrade      Holmes      Watson
            (Opus 5.5)  (Opus 5.5,$7) (Opus 5.5,$10)
                  ▲           │           │
                  │           ▼ writes    ▼ reads/searches
                  └──── memory vault (dev-team/top-lessons.md +
                        review-learnings notes) ────┘
```

Every 20 minutes, the Dispatch scheduled task wakes up and:

1. Calls `mcp__the-index__list_unrefined_items()` → fires Lestrade for each item returned, plus one blocker sweep (`Repo sweep: <owner/repo>`) per distinct repo among those items.
2. Calls `mcp__the-index__list_review_items()` → fires Holmes for each item returned.
3. Calls `mcp__the-index__list_development_items(limit=1)` → fires Watson on the top item (if any).
4. Exits.

Each dispatch is fire-and-forget via `nohup claude -p --agent workbench-dev-team:<name> ... &; disown`. Watson alone can run for hours; Dispatch never blocks.

Because an agent only writes its status change at the *end* of its run, an item stays lane-eligible for as long as the run takes — so a run that outlives the tick interval would otherwise be dispatched a second time, and the two would race each other's board writes. Every dispatch therefore drops a per-item lock (`<agent>-<id>.lock`, holding the run's PID) next to the logs, and the circuit-breaker pre-flight skips any item whose lock PID is still alive. As a second line of defence, Holmes re-reads his item immediately before writing a verdict and writes nothing if it is no longer `In Review`.

### The Index does the filtering

All "what's pending in each lane" logic lives server-side in The Index's MCP tools. Dispatch never interprets item status, field changes, or priority — it just asks The Index "what's pending in each lane?" and fires the matching agent per returned item. Adding a new dispatch rule means editing The Index, not this plugin.

### Concurrency

- **Inspector Lestrade and Sherlock Holmes** are idempotent within a tick. Status lanes (`null` and `In Review`) act as the serialization.
- **Dr. Watson** picks from `In Progress` OR `Ready` (In Progress first — that's the resume path for crashed runs). A per-item **board claim** (`claim_item` / `release_item`) is what stops two Watsons stepping on the same item: it is visible, it works across hosts, and `list_development_items` hides a claimed item. Watson releases it on every exit path, success or not — an abandoned claim hides the item from the lane for good. There is deliberately **no** host-wide lock, so two Watsons on two different items run side by side.
- **Watson also refuses work that isn't his**, on two independent gates, both fail-closed and both leaving the item's status exactly as it found it. A **status gate** drops any item dispatched outside the `Ready`/`In Progress` lane (or with an unreadable status) — he never moves an item into his own lane to justify working it. A **provenance check** in resume detection means he only ever adopts a branch he created himself, identified by a `Watson-Branch: #<issue>` trailer on its start-of-work commit (PR authorship can't serve: he opens PRs with `gh` under your credentials, so his PRs and yours both read as you). Both gates exist because GitHub Projects' built-in *Pull request linked to issue* workflow flips a linked issue to `In Progress` seconds after **anyone** opens a branch-named PR — including yours, which is how a human's work-in-progress once got commits pushed onto it and, on a branch prefix the old matcher didn't know (`ci/`), got a duplicate PR opened beside it. The hands-off notice is posted once per branch (an `<!-- watson-hands-off: <branch> -->` marker on the issue tells him he has already said it) — that same Projects workflow parks the issue in `In Progress` for the whole life of your PR, so he is dispatched onto it every tick until you close it, and the notice would otherwise repeat every twenty minutes.

### Token cost

| Scenario | Tokens |
|---|---|
| Idle Dispatch tick (no work in any lane) | ~1–3K on default model — three MCP calls + exit |
| Lestrade triage | 5–8K `claude-opus-5-5[1m]` tokens at medium effort + four blind Sonnet lens sub-agents verifying the draft AC |
| Lestrade blocker sweep | `claude-opus-5-5[1m]` tokens scaling with open-issue count (reads every open title + body in the repo); fires only on ticks that triaged new items |
| Holmes review | `claude-opus-5-5[1m]` parent at medium effort + four blind Sonnet lens sub-agents + adversarial skeptic per review (security findings, and every finding on the PR's first review: 3-agent red/blue/auditor panel instead — up to 30 verification dispatches on a busy first review vs. 10 on a re-review); capped at $7 per run |
| Watson development | Full `claude-opus-5-5[1m]` session at medium effort, capped at $10 per run |

Dispatch runs on your Claude Code default model (scheduled tasks don't expose a model selector). Since each tick is under 3K tokens, the default model's cost is negligible even if it's Sonnet.

## Dispatch paths

Two ways to invoke the same agents, same definitions:

1. **Unattended (default).** The scheduled Dispatch task polls The Index every 20 minutes and dispatches via `claude -p --agent`. This is what `/workbench-dev-team:setup` registers.
2. **Interactive.** Any Claude Code session can dispatch an agent directly via the Agent tool, e.g., `Agent(subagent_type: "workbench-dev-team:lestrade", ...)`. For multi-agent delegation with config-driven models, background execution, and roster tracking, use the `orchestrate` skill — it wraps this path with the full protocol. Useful for manual triage, one-off runs, ad-hoc dev work (Watson Direct mode), or debugging without waiting for the next scheduled tick. **One exception: an Index item you want built now.** The Agent tool cannot set an environment variable on the agent it spawns, so an Index-mode Watson dispatched through it carries no pipeline flag and is refused at its first commit. Run `bash "$HOME/.claude-workbench/bin/dispatch-agent.sh" watson <item-id>` for that — the same wrapper the scheduled task uses, immediately.

## Monitoring

- **Agent logs.** `~/.claude-workbench/dev-team-logs/<agent>-<item>-<timestamp>.log` — full agent output per dispatch.
- **Review-learnings notes.** `dev-team/review-learnings/<repo>-pr<n>-<date>.md` (one note per bounce/escalation, written by Holmes at re-review) and `dev-team/top-lessons.md` (the frequency-ranked digest Watson and Lestrade read) in your memory vault. Nothing there yet means no PR has bounced or been AC-disputed since this shipped.
- **Scheduled task panel.** Claude Code's scheduled-tasks panel shows the Dispatch task's run history and next-run time.
- **Project board.** Items flow Inbox → Backlog → Ready → In Progress → In Review → Approved / Escalated. Status drift (items stuck in a column) is your canary.

## Tests and CI

`bash run-tests.sh` runs the whole suite from the repo root and exits non-zero if
anything fails. Pass `tests` or `lints` to run one group.

The two groups are named apart on purpose:

- **`test-*.sh`** — six scripts that execute shipped shell logic and assert on
  its behaviour. Two run a shipped `.sh` as a subprocess. Four extract the real
  bash from between sentinel markers in a Markdown prompt and run it against
  fixtures, so the test cannot drift from the logic it guards.
- **`lint-*.sh`** — four scripts that grep English prose and YAML frontmatter in
  the shipped Markdown. They guarantee nothing about behaviour, so they do not
  call themselves tests.

Every script sandboxes itself: `mktemp -d` with an `EXIT` trap, and an overridden
`HOME` wherever the logic under test resolves config or log paths from it. A
verdict that depends on the developer's real environment is not a verdict.

[`.github/workflows/validate.yml`](.github/workflows/validate.yml) runs both
groups on every pull request and on every push to `main`, alongside a
`plugin.json` schema and semver check, `shellcheck` pinned to `v0.11.0`, `bash -n`
syntax checks, a frontmatter sweep, and a `${CLAUDE_PLUGIN_ROOT}` reference
check. The shellcheck pin matches the sibling `workbench-core` plugin: the runner
image's copy floats, and a version disagreement between CI and a developer's
machine once left `main` red for four releases while every local run read clean.

## Troubleshooting

| Problem | Fix |
|---|---|
| `claude mcp list` shows the-index as Failed to connect | Your OAuth token has probably expired or been revoked. Re-run `/workbench-dev-team:setup` to fetch a fresh token and re-register. |
| Dispatch logs `the-index unreachable` | `curl https://the-index.mikebronner.dev/mcp` to check the endpoint. If 500, The Index has a middleware bug (should be 401). |
| Watson stuck (process hung, item never re-offered) | The run died holding its board claim. `mcp__the-index__release_item(<item-id>)`, or move the item out of the lane and back. Next tick will resume. |
| Agent not found | `claude agents` should list `workbench-dev-team:lestrade`, `:watson`, `:holmes`. If not, reinstall the plugin. |
| Item stuck in `In Review` with no PR | Holmes couldn't find a PR for the issue. Check `gh pr list -R <repo> --search <issue>`. |
| Scheduled task isn't firing | Check Claude Code's scheduled-tasks panel. The Mac must be awake (this is a local scheduler). |

## Risks and limitations

- **Local execution.** Dispatch runs on your Mac. If the host is off, no work moves. Fine for home/dev setups; move Dispatch to an always-on box if you need 24/7 coverage.
- **Budget caps.** `--max-budget-usd 10.00` limits Watson's per-run spend; Holmes carries an optional cap too (default `10.00`), since its lens fan-out is the only uncapped, multi-agent lane — measured over 50 fan-out reviews, a review's mean cost is ~$7.33 with a long tail past $17 when Phase C verification fires, so a cap at $7 sat below the median and killed roughly a quarter of runs mid-review. Complex work may hit the ceiling and leave the item in `In Progress`; the next tick resumes. (The $10 figure was originally sized for Fable's 2× Opus pricing; on Opus it now buys roughly twice the tokens per run.)
- **The Index must be reachable.** If the MCP server is down, all three list tools fail and Dispatch logs `the-index unreachable` and exits cleanly. The next tick retries.
- **OAuth token lifetime.** The Index issues 1-year tokens via client_credentials. Re-run `/workbench-dev-team:setup` annually (or whenever you rotate the OAuth client secret).

## Manual task registration (fallback)

If `/workbench-dev-team:setup` fails at step 6 (scheduled-task registration), choose "Skip" when re-prompted to register the schedule, then register manually from any Claude Code session:

```
mcp__scheduled-tasks__create_scheduled_task with
  taskId:         "workbench-dev-team-dispatch"
  cronExpression: "*/20 * * * *"         # or */30 for 30-min cadence
  description:    "Dispatch — poll The Index every 20 min and fire workbench-dev-team agents on pending items."
  prompt:         <body of scheduled-tasks/orchestrator.md, frontmatter stripped>
```

## Why not cloud routines

An earlier iteration targeted Anthropic's cloud-hosted routines (`/fire` endpoint, configured via `/schedule` → `RemoteTrigger`) for event-driven dispatch. Two things killed it:

1. **The 15-routine-runs-per-day cap** on online routines. Dispatch every 20 minutes = 72 fires/day, seven times over.
2. **Added operational surface.** Fire-token storage, a The Index-side webhook dispatcher, per-transition idempotency — a lot of moving parts to event-drive what a 20-minute poll handles just as well.

A local 20-minute poll has higher worst-case latency but zero per-fire cost, simpler failure modes, and no token rotation burden. Given that Watson can run for hours, 20-minute dispatch latency is noise.
