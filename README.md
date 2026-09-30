# workbench-dev-team

A Claude Code plugin that runs a three-agent development pipeline against a GitHub project board. Items flow from triage → development → review without you touching them. Part of the [`claude-workbench`](https://github.com/mike-bronner/claude-workbench) marketplace.

## What it does

You work out of a GitHub project board. New issues land with no acceptance criteria. Well-refined ones sit in `Ready`. Work-in-progress has open draft PRs. PRs waiting on review pile up.

This plugin runs a team of agents on a local 20-minute clock that move items through the pipeline for you — and records what the reviews teach as it goes, so the team stops repeating itself:

- **Inspector Lestrade** (`claude-opus-5-5[1m]` at medium effort, Sonnet lenses) — triage. Reads items in the `Inbox` lane, writes acceptance criteria as a managed follow-up comment on the issue (the description is left untouched). Before scoring, the draft AC is checked by four blind lens sub-agents (malicious-compliance, testability, completeness, edge-case) that each try to find a gap Holmes and Watson would otherwise hit downstream — a much more expensive place to catch it, since Lestrade only ever sees an issue once while Watson and Holmes cycle back on it every bounce. Real gaps get folded in with one bounded tightening pass, never a re-verification loop; a lightweight comment marks when the AC changed this way. Scores WSJF, moves them to `Backlog` for your review. The WSJF write also lands two GitHub-native issue attributes The Index derives server-side: the issue **Type** (`PBI`) and an issue-level **Priority** (`Urgent/High/Medium/Low`) mapped from the WSJF — org-repo-only and best-effort. Also runs **blocker + consolidation sweeps**: after a repo gets fresh triage work, he re-reads all of its open issues and (1) marks blocked-by dependencies (native GitHub issue dependencies, additive only) so blocked items stay out of Dr. Watson's queue, and (2) consolidates follow-ups — folds `expand-from` comments into the issue they target and merges unmistakable near-duplicate follow-ups into the earliest anchor (native duplicate-close, high bar, ambiguous clusters flagged not closed) so the backlog stops sprawling.
- **Dr. Watson** (`claude-opus-5-5[1m]` at medium effort, $10/run cap) — development. Has two modes: **Direct mode**, the default (invocable as a sub-agent from Claude Code or Cowork for ad-hoc dev work — no The Index calls, just runs the `/develop` skill in a sub-agent context, and hands its work back as an uncommitted working tree for the dispatching session to commit) and **The Index mode**, entered only on an explicit `Item ID: <n>` token (Dispatch-driven, picks the top `Ready`/`In Progress` item, clones the repo, writes code and tests against AC, opens a PR, moves to `In Review`). Ambiguous prose resolves to Direct mode, never to the board. Both modes follow the `/develop` skill for the actual coding.
- **Sherlock Holmes** (`claude-opus-5-5[1m]` parent at medium effort, Sonnet lenses, $10/run cap) — code review. Has two modes, the same way Watson does: **Local mode**, the default (invocable as a sub-agent on a six-slot prose brief — reviews the *uncommitted working tree* in the given workdir, tracked changes and untracked files, against the brief's `Acceptance:` list as the rubric it never amends, and returns the verdict as prose) and **The Index mode**, entered only on an explicit `Item ID: <n>` token (Dispatch-driven, reviews the board item's PR and posts an App-signed verdict). Ambiguous prose resolves to Local mode, never to the board. Local mode makes **no The Index call and no GitHub write at all** — no review, no comment, no issue — so it is safe on any repo, and it closes the loop on Watson's Direct mode, whose output is exactly an uncommitted tree with no review path otherwise. It replaces the board-coupled steps rather than skipping them: the brief is the rubric, the workdir is the evidence room (never cloned, never written to — a harness-level guard enforces that, see **Review guard** below), and the repo's own suite is run locally in place of reading CI, because the toolchain objection that keeps Index mode off local test runs does not hold when the agent is already in the repo's directory on your machine. It records a vault note per local verdict but deliberately never touches the `top-lessons.md` digest, since local reviews are a separate population whose counts would skew a frequency ranking. Everything in between — the lens fan-out, adversarial verification, the memory pass, the finding-routing matrix — runs unchanged. The rest of this entry describes The Index mode: reviews open PRs, approves or requests changes. Escalates to you after 3 change rounds — but your input resets that count: comment, review, or weigh in on the PR and the window restarts from your last word, so an escalated PR you've decided on gets a fresh review instead of bouncing straight back. Reviews fan out across blind, read-only lens sub-agents (AC conformance, correctness, security, test honesty), with every blocker adversarially verified before it lands — a 3-agent red-team/blue-team/auditor pipeline handles security-lens findings every round and hard defects on the PR's first review, and a single skeptic handles the rest, soft observations included (the fullest check lands where a wrong verdict costs a round, not on a naming nit). After verification, Holmes (and only Holmes — no sub-agent touches the vault) checks each surviving finding against the memory vault for relevant context — a documented decision that reframes it, a past incident that reinforces it — always re-verified against the current tree before it's trusted, never used to waive a real defect or mark an AC item met. Only the parent writes, so there's still exactly one App-signed verdict. Falls back to a single inline pass when the fan-out is unavailable. Findings route by the **coherent unit of work** — *what the issue is really about* — then coupling and locality: a finding that **belongs to the unit blocks and is fixed in this PR**, even in untouched code the diff never caused, because a half-delivered unit is itself the defect. On top of that, anything actionable in the code a PR touched blocks (request changes, however minor), a hard correctness/security/test defect blocks wherever it lives, and — coupling beating locality — untouched code the diff made stale, inconsistent, or wrong blocks too. The self-test: *block and fix here if EITHER the diff caused it OR it belongs to the coherent unit* — a follow-up only when both are false. The precise routing rule lives in Holmes's canonical review contract (`agents/holmes.md`, §4e/§5). The **non-blocking follow-up tier is then gated by materiality, default-deny**: it holds only findings *unrelated* to the unit, and most of those — one-off cosmetics (naming, small duplication, style) — are **noted in the verdict, not tracked**. Only an unrelated **latent hazard** (security/data-integrity/correctness not live enough to block) or **systemic/substantial debt** (a schedulable chunk with its own testable "done") earns **one tracked issue**, tagged `Tracked under:`, capped at one new anchor per PR — the materiality bar that stops the follow-up flood. When Holmes does track, he **expands the earliest related open issue** in place (a comment Lestrade folds into its acceptance criteria) rather than opening a near-duplicate, and opens a new anchor via `create_issue` (App-signed as Holmes, board-added and `PBI`-typed) only when nothing related exists. A class of sites violating one *invariant* (a containment guard, a null-check, a helper every caller owes) is swept whole: if the class belongs to the unit it's folded into the PR; if it's an unrelated anti-pattern agents will replicate it becomes **one umbrella issue with a checkbox per site** — either way closing the class at once rather than minting a fresh single-site issue every review, the treadmill that otherwise turns one finding into an endless `#A → #B → #C` chain. A finding gets the **same disposition regardless of verdict**, so a clean PR never generates more tracked work than a messy one: on a change request, unit-belonging findings are blockers Watson folds into the **same PR**, unrelated cosmetics are optional (fix if cheap, else skip), and the unrelated hazard/debt tier is tracked exactly as on approval.

A fourth component — **Dispatch** — is the local scheduled task that polls the board every 20 minutes and fires the right agent for each pending item. Dispatch is the only thing that's scheduled; the three agents run as dispatched subprocesses.

### The feedback loop

Lestrade, Watson, and Holmes used to have no memory of their own reviews: nothing recorded *what* Holmes rejected, *why*, or *how* it got fixed, so the same lessons got re-taught every review (test-honesty is ~38% of all rejections, fail-open ~11%, doc-drift ~11%). There's no separate harvesting agent for this — **Holmes is the only one who holds both halves of a rejection** (what he flagged, and whether the next push actually fixed it), so he records it himself, live, at re-review: one atomic vault note per bounce or AC-dispute event, categorized against a fixed taxonomy, plus an incrementally-refreshed `dev-team/top-lessons.md` digest (recurring categories, frequency-ranked, each with the concrete prevention rule). **Watson reads that digest and searches the vault for anything task-specific before coding; Lestrade reads it before writing acceptance criteria**, so the pipeline gets smarter instead of repeating itself on both sides — what gets built and what gets asked for. Your own corrections take a second channel, because no review rejection records them: they live under `feedback/` in the vault, and all three agents are required to search it: Watson before building (`/develop` requires it in every lane, Direct mode included), Holmes before judging, in both Local and Index mode, and Lestrade before writing acceptance criteria. Your corrections bind every stage, and a stage that never reads them never catches a violation of one.

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

Four more skills exist for the agents rather than for you. **`comms-style`** is how Lestrade, Watson, and Holmes write every piece of prose that isn't code — ticket comments, PR bodies, review verdicts — modeled on ASD-STE100 (Simplified Technical English). **`holmes-review`**, **`watson-pipeline`**, and **`lestrade-triage`** hold each agent's long, situational procedure: each agent prompt in `agents/` is a thin router that keeps the always-relevant rules inline and points at `skills/<name>/references/` for the detail it only needs at one moment — Holmes's review phases and sub-agent prompt skeletons plus his Local-mode path, Watson's Index-mode pipeline, Lestrade's acceptance-criteria lenses and Sweep mode. The router pattern mirrors `git-commit`, and it keeps the per-dispatch prompt small without putting any rule out of reach.

Plugin configuration lives in a slash command (`/workbench-dev-team:setup`), not a skill — see the [Setup](#setup) section below.

### `develop`

Universal dev workflow + standards: orient before writing (the repo's `CLAUDE.md`, `AGENTS.md`, `CONTRIBUTING.md`, `.ai/` rules, and review wiki), plan before coding (including a required `feedback/` vault search), atomic commits, every change gets a test, no committed secrets, lint before pushing. Triggers whenever code is being implemented, fixed, refactored, or tested — manual or agent-driven.

It names three lanes (foreground, sub-agent, scheduled pipeline) and ends each step the way that lane can: a sub-agent finishes with an uncommitted tree and a report, never a commit or a PR. Includes a **decision protocol** that presents three options, each as its own heading with pros and cons, then a separate recommendation, for a meaningful fork the human has not already decided — implementation approach, library choice, scope decisions, a public interface. A fork they already decided is not asked again. In the foreground the human decides; a sub-agent picks and records the assumption below the blocking-uncertainty bar and stops with the options above it. Trivial choices (mechanical translation, following existing repo conventions, naming, one-line obvious fixes) are exempt.

Also defines the **commit approval** lanes (see [Commit approval](#commit-approval) below): a sub-agent commits, merges, and pushes nothing, a foreground commit waits for your "commit it" in chat, with Claude Code's permission prompt on every `git commit` and `git push` as the backstop, and a push that forces or deletes remote refs is refused outright.

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

**Every handoff is written to a fixed six-slot brief** — `Workdir:` / `Goal:` / `Context:` / `Constraints:` / `Acceptance:` / `Done when:` — read-only research dispatches included, which is what makes classifying a prompt as code work unnecessary in the first place. `Workdir:` is the absolute path, plus the branch or worktree when the human settled one (`Workdir: /Users/mike/Developer/foo (branch: fix/retry-backoff)`); a bare path stays valid and means there was no workspace decision to record. `Goal:` is bounded at one or two sentences, because it's the only slot tight enough to check a result against; `Context:` is prose and deliberately unbounded, since that's where the reasoning goes so `Goal:` doesn't have to carry it; `Constraints:` is bullets that each state their own reason, because a constraint without its reason gets obeyed literally and defeated in spirit. `Acceptance:` is the numbered list of criteria the work is graded against: the receiver grades its forks and its report against it, Holmes reviews against it, and it is where the criteria from `/workbench-core:intake` cross the handoff. For a Watson or Holmes `Item ID: <n>` run, the item's acceptance criteria from triage are that list. No length limit is stated anywhere — length was only ever a proxy for prescriptiveness, and the must-omit list (shell commands, numbered steps, named test paths, framework choices) attacks that directly. `Constraints:` may read "none"; `Context:` may not, and carries at least one sentence on why the task exists. The brief binds the **receiver** too, and in two ways: every agent in `agents/` refuses a brief missing a slot and names what's missing, and an agent handed a complete-but-unusable brief stops and sends its questions back to the orchestrator instead of guessing — the bar there is blocking uncertainty only, so anything short of it proceeds with the assumption stated. The two fixed dispatch tokens (`Item ID: <n>`, `Repo sweep: <owner/repo>`) are exempt from both, since they aren't briefs. A third exemption is the **orchestrator boundary** itself: the template governs a dispatch that leaves an orchestrator for a specialist, and a specialist's own fan-out to internal workers is outside it. The measurement behind the rule already excluded that traffic — of 622 dispatches, the 422 sent from sessions that were themselves agent runs were counted as correct behaviour — the parent holds every fact those workers need, so `Context:` has nothing to recover, and their prompts are written against measured cost rather than to a template. It's stated as a boundary and not as a list of agents, so a specialist that grows a fan-out later inherits it with no edit. A companion `PreToolUse` gate in workbench-core checks one thing — that the slots are present — and refuses a handoff that drops one; judging whether the prose inside them is any good is the receiving agent's job, not a shell script's.

**The orchestrator asks before a branch or a worktree is created.** Not a prohibition — branches and worktrees are the wanted outcome of most dev work, and a PR is a normal finish line. What changed is who decides. Ahead of any dispatch whose work ends in a commit, the skill reads the target tree and asks in three cases: on `main`/`master`/`trunk` it proposes a branch name; on a feature branch already carrying unrelated work it names what's there and proposes a branch off the base; inside a worktree it confirms that worktree is the one meant for this task. All three end in a question to you, never in a refusal, and your answer is recorded in the brief's `Workdir:` slot so the sub-agent works where you said. Two Watsons on one repo still get separate worktrees (`isolation: "worktree"`) — asked for the same way. The reasoning, including why the answer widened `Workdir:` instead of adding a slot, sits in `skills/orchestrate/references/brief-rationale.md`, which loads only when a rule is challenged rather than on every orchestration.

The skill also **routes GitHub actions to the right executor**. Two rules: (1) *agent work products* (formal reviews, AC, status moves) only ever go through The Index, signed as the dispatched agent — never `gh`; (2) *your own actions* (comments you dictate, merges you order) go through `gh` under your identity, on any repo. Whether a repo is Index-governed is answered by `check_repo_access` — a server-side tool that checks The Index GitHub App's installation list (spec in `THE_INDEX_HANDOFF_ROUTING.md`; until it ships, the skill degrades to a `list_items` scan and says so). Merges are never delegated to agents and only happen on your explicit request.

## Commit approval

**A sub-agent does not commit, merge, or push. In the foreground session, the agent commits only after you review the tree and say "commit it" in chat. That is the approval.** Claude Code's permission prompt on each `git commit`, `git push`, and `gh pr merge` is the mechanical backstop, because a prompt that appears mid-flow gets answered without a review. After a commit you approved, the agent attempts the push itself and lets the prompt ask you. The scheduled pipeline commits and pushes unattended, inside its own clone and the scratch roots, and never merges.

**No agent disguises a command to get past a gate.** Watson, Holmes, and Lestrade each carry a `## When a gate or guard refuses you` section: never reword, split, encode, or rebuild a command to get past a gate or guard, and report the refusal instead. It exists because Holmes once got past the installed commit gate by building the words "commit" and "push" from pieces at run time. `agents/lint-gate-refusal.sh` pins the section in every agent file.

**Every agent makes its own scratch in a scratch root and deletes it itself.** Each agent file carries a `## Scratch folders` section. A clone or a probe copy goes in `mktemp -d <root>/<agent>.XXXXXX`, where the root is the session scratchpad, or `~/Developer/scratchpad` when the harness names none. The agent deletes that folder before it reports, with the literal path as a command of its own. A refused delete is respelled and retried, never handed to you as a `!` command, and a delete that still fails is named in the report. Git branches and stashes are out of scope. `agents/lint-scratch-cleanup.sh` pins the section in every agent file, the probe-copy block in every Holmes helper skeleton, and the absence of a bare `mktemp -d` from every agent and skill instruction.

**This is a mistake-catcher, not a security boundary.** It stops an honest agent that moves too fast. It does not stop an agent that sets out to evade it: a script file, an interpreter such as `python3 -c`, a shell alias such as `gp`, or a program that runs another program gets past every part of it. Nothing checks that the staged diff is still the one you saw when you answered the prompt. Your review, and your merge of the pull request, stay the real gate.

It has three parts.

**1. Ten `permissions.ask` rules**, installed by `/workbench-dev-team:setup` (Step 6.6) into `~/.claude/settings.json`:

```
Bash(git commit *)    Bash(git push *)    Bash(git * commit *)    Bash(git * push *)
Bash(git * commit)    Bash(git * push)
Bash(gh pr merge:*)   Bash(gh * pr merge *)    Bash(gh * pr merge)    Bash(gh api *pulls/*/merge*)
```

The mid-rule `*` forms catch `git -C <dir> push`, `git -c <key>=<value> commit`, and `gh -R <owner/repo> pr merge <n>`, which workbench-core's own `gh pr merge:*` misses. A trailing ` *` also matches the bare command only when it is the rule's only wildcard, so each mid-rule form has a twin with no trailing `*`: `git * push`, `git * commit`, and `gh * pr merge` catch a bare `git -C <dir> push`, `git -C <dir> commit`, and `gh -R <owner/repo> pr merge`. The last rule catches a merge through the REST API. Per the Claude Code permissions docs, an ask rule applies to every subcommand of a compound command, including `$( … )`, subshells, and loop bodies. It is checked before auto mode and before `bypassPermissions`, and the harness strips `timeout`, `time`, `nice`, `nohup`, `stdbuf`, `command`, `builtin`, and `noglob` before it matches. Some costs are accepted: in the foreground, `git stash push`, `git log --grep commit`, and a `gh api` read of `pulls/<n>/merge` prompt too. For a sub-agent, the guard below refuses the git ones outright.

**2. A `PreToolUse` hook** ([hooks/scripts/commit-guard.sh](hooks/scripts/commit-guard.sh), under 100 lines) refuses what the rules cannot cover:

| Refused | Why |
|---|---|
| A pull request merge from a sub-agent or from the pipeline: `gh pr merge` in any spelling (`gh -R o/r pr merge` included), or `gh api` on `pulls/<n>/merge` | Holmes and Watson never merge. The pipeline carries an `agent_id` and nobody sees its prompts, so without this a merge spelled past the ask rules would be left to the auto-mode classifier |
| A commit or push from a sub-agent, keyed on the harness-supplied `agent_id` | A sub-agent's prompt reaches no human. It hands its work back uncommitted instead |
| A push that forces or deletes: `--force`, `--force-with-lease`, `--force-if-includes`, `--mirror`, `--delete`, `--prune` (and their prefixes), `-f` or `-d` in a short cluster, or a refspec that starts with `+` or `:` | Never wanted. Your user deny rules already cover some spellings, and this covers the rest |
| A commit, push, or merge behind `bash -c`, `sh -c`, `zsh -c`, `env`, `eval`, a leading `NAME=value` such as `HUSKY=0`, or a program named by its path (`/usr/bin/git`) | The ask rules do not match those forms, so no prompt would appear. The harness strips only known-safe variables before it matches. The refusal asks for a plain line |

The match is plain text, on purpose. A large parser is what failed before. A word such as `env` in a commit message ahead of a push, as in `git commit -m "load env vars" && git push`, is refused as a wrapper. Pass that message with `git commit -F <file>`. For a sub-agent, the text match is deliberately broad: any Bash call that names a commit or push is refused, reads included, so that `xargs` and `sudo` forms are caught too. `grep -rn "git push" README.md` is refused, and the refusal tells the agent to use the Grep or Read tool. A payload the hook cannot read with `jq` is refused when its text names a commit or push.

**Known gaps.** Beyond scripts, interpreters, and aliases, these reach a commit, push, or merge with no prompt and no refusal: `yadm`, `xargs` (in the foreground), `find -exec`, a shell fed a script through stdin, a merge through `gh api graphql`, and a remote whose config sets `mirror = true` or a forcing push refspec.

**3. A `PermissionRequest` hook** ([hooks/scripts/pipeline-scope.sh](hooks/scripts/pipeline-scope.sh)) keeps the pipeline running and holds it to its own folders. `bin/dispatch-agent.sh` runs `claude -p --agent workbench-dev-team:<agent> --permission-mode auto --permission-prompts none` from a fresh, empty folder in `~/Developer/scratchpad`, and exports `WORKBENCH_DEV_TEAM_PIPELINE=1` onto it. Settings cannot drop your user ask rules for that run, because permission lists merge across scopes, and an ask rule is matched before the auto-mode classifier. With `--permission-prompts none`, a run denies every prompt unless a `PermissionRequest` hook allows it. So the hook answers "allow" when, and only when, every one of these holds:

- The flag is exactly `1` in the hook's own environment.
- The command is one simple command: `git -C <absolute dir> <subcommand> …`, `rm …`, or `rmdir …`. A separator, a variable, `$( … )`, a backtick, a glob, a pipe, a redirect, a subshell, `~`, `^`, or a leading `=` ends the check. `gh` is never allowed.
- Every path is absolute, with no `.` or `..` part, and lands inside a root once symlinks resolve: the `-C` directory, the top level and git directory of the repository git finds there, every absolute git argument, and every `rm` and `rmdir` operand, which must sit strictly beneath a root. `rmdir` takes no option, since `-p` climbs up through a root, and `rm` reads options only before its first operand, as BSD `rm` does. The payload's working directory is never read. The roots are all of `$TMPDIR` (where a bare `mktemp -d` lands; on macOS `mktemp -d` uses `DARWIN_USER_TEMP_DIR`, which is the same folder unless something changes `TMPDIR`, and a mismatch fails closed), `~/Developer/scratchpad`, and the session scratchpad. Watson's clone lives in one of the last two, so another run's clone is in scope too. The last two are found by name, so each is kept only when its physical path is the path itself: a planted symlink never becomes a root.
- git's own options cannot appear, since the subcommand must follow `-C <dir>`. The subcommand is one the pipelines use: `add`, `checkout`, `commit`, `diff`, `log`, `merge`, or `push`. Every other subcommand is refused, because `submodule foreach`, `bisect run`, `difftool -x`, and a `!` alias each run a program.
- A push is `push [-u] <remote> <refspec>`: one refspec naming one branch, and not the branch that `<remote>/HEAD` points at in the clone. Its source must resolve in the clone to a local branch under `refs/heads/`. A tag, a remote-tracking ref, a commit id, an ambiguous name, or a name that does not resolve is refused, because git sends a tag source to `refs/tags/` and a tag push can start a release workflow. A bare push, `HEAD`, `@`, `--all`, `--branches`, a force, a delete, and a destination that starts with `heads/`, `tags/`, or `remotes/` are all refused. git reads such a destination as `refs/<destination>`, so `heads/main` is `main`.
- No Bash deny rule in `~/.claude/settings.json` matches the command with `-C <dir>` left out, either as written or with its trailing ` *` removed, since the harness matches a bare `git gc` against `git gc *`. The harness checks deny rules before any prompt, but only against the line as typed, and a rule written as `git push …` never matches a `git -C` line.

Anything else stays silent, and the run denies it. The pipeline's own templates (Watson's pipeline step 5 and step 10) are plain lines that fit, and the tests run them. The hold covers what prompts. A pipeline command that matches no ask rule never reaches the hook. The auto-mode classifier judges it, its deletes are held to scope by workbench-core's destructive-scope guard, and a git verb outside both lists, such as `git restore` in another tree, is held by the classifier alone.

**Re-check after a Claude Code upgrade.** The pipeline depends on one harness behaviour, verified live on Claude Code 2.1.286: in a `claude -p` run with `--permission-mode auto --permission-prompts none`, a command that matches an ask rule calls the `PermissionRequest` hook, the hook's "allow" lets the command run, and its silence denies it. The suite does not test this, because it needs a live headless run. If a later version stops calling the hook, or ignores its answer, every scheduled run dies at its first commit. After each upgrade, check it by hand, with a harmless command in place of a commit:

1. Make a folder in `~/Developer/scratchpad` with `mktemp -d`.
2. In a settings file there, add an ask rule such as `Bash(echo probe-ask:*)`, and a `PermissionRequest` hook that is a stand-in script. The script prints an allow decision when the command is `echo probe-ask allow`, and nothing otherwise.
3. From that folder, run `claude -p --no-session-persistence --settings <file> --permission-mode auto --permission-prompts none --output-format stream-json --verbose` with a prompt that runs `echo probe-ask allow` and then `echo probe-ask silent`.
4. Confirm the first command printed its text and the second was refused. If the first was refused, the run denied the prompt, and the pipeline is broken on this version. Then delete the folder.

**Why the run starts in an empty folder.** Dispatch itself runs in `~/Developer/workbench-dev-team`. A run started there would take the live plugin repo as its project folder, and workbench-core's destructive-scope guard lets a delete or `git reset --hard` inside the project folder run with no prompt. So `bin/dispatch-agent.sh` starts every run in a fresh folder, `~/Developer/scratchpad/dispatch-<agent>.XXXXXX`, and unsets `CLAUDE_PROJECT_DIR`. If the folder cannot be made, or lands inside a git repository, nothing is dispatched. The wrapper that starts the agent deletes the folder when the agent exits, whether the run succeeded or failed. The accepted cost: a run loads no project `CLAUDE.md` and no project settings. Your user settings, deny rules included, still apply. The 24 tool deny rules runs used to take from this repo's `.claude/settings.local.json` (`Workflow`, `SendMessage`, the `Cron*` and `Task*` tools, `EnterWorktree`, `NotebookEdit`, and the rest) are passed with `--disallowedTools` instead. The list is `DENIED_TOOLS` in `bin/dispatch-agent.sh`, because the installed copy runs from `~/.claude-workbench/bin` and that settings file is personal and untracked. `bin/test-dispatch-agent.sh` pins every name. To change the list, edit both, then re-run setup to install the new wrapper.

**Why auto mode, and what it costs.** Runs used to start with `--dangerously-skip-permissions`. The auto-mode classifier's own default rules name that flag as an unsafe way to start an agent loop, and Mike's sessions run in auto mode. Now the classifier judges every call that no rule decides. Two consequences:

- Board and memory calls are allowed by rule, so the classifier never judges them: `--allowedTools` names `mcp__the-index__*` and `mcp__plugin_workbench-core_memory__*`, the two servers the agents' frontmatter uses. Its default rules name board writes and review approvals, which are these agents' whole job. The Agent tool has no such rule, because auto mode drops an Agent allow rule. A live run on 2.1.286 started a sub-agent in auto mode with no refusal.
- The classifier can refuse a call bypass mode ran, and a `-p` run still exits 0 when it does. So every refusal is written to the run's log as one line, `Permission denied: <tool>[ in a sub-agent] <input> -- <reason>`. Find them with `grep '^Permission denied: ' ~/.claude-workbench/dev-team-logs/<agent>-<item>-*.log`. The run streams JSON (`--output-format stream-json --verbose`), and the wrapper turns it back into the plain-text log it always wrote, so the circuit breaker reads it as before. The breaker skips the refusal lines, because they quote the refused call.

Two interactions are handled. `--agent` puts an `agent_id` in every payload of a pipeline run, so the sub-agent refusal checks the flag first and lets the pipeline through. The merge refusal does not check the flag. A sub-agent of an interactive session (the Agent tool) does not carry the flag unless the session itself does, so it stays refused. The Agent-tool sub-agents of a dispatched Watson or Holmes inherit the flag, and are treated as the pipeline. The flag must be exactly `1`.

**So an Index item dispatched from a conversation must go through the dispatcher.** The Agent tool cannot set an environment variable on the agent it spawns, so an Index-mode Watson dispatched that way is a sub-agent with no flag. Watson checks the flag before it claims the item, and refuses there, so no claim leaks. Dispatch it with `bash "$HOME/.claude-workbench/bin/dispatch-agent.sh" watson <item-id>`.

The pipeline signal is per-process. It reaches the dispatched agent and its children, and nothing else. An interactive session running beside a scheduled tick never sees it. A shell `export` before you start Claude Code, or an `env` block in a settings file, would set it for an interactive session too, so set it in neither. With the flag set that way, the `PermissionRequest` hook allows that session's in-scope commit and push prompts with no human asked, and the sub-agent refusal is off. This replaced a live-PID `/tmp/watson.lock` check, which exempted every concurrent interactive session for the life of a tick. Do not reintroduce a host-wide substitute.

**Why not a hook that asks.** A hook's `ask` is classifier-approvable: under `permissions.defaultMode "auto"` the auto-mode classifier answers it, and no human is prompted. A permission rule's prompt is not. So the rules raise the prompt, and the hook only ever answers `deny` or, for the pipeline, `allow`.

**What it replaced.** The commit approval gate kept approval records in `~/.claude-workbench/commit-approvals/`, granted by `approve` (`bin/approve-commit.sh`), and parsed command text to decide what could be approved. Any process you run could write a record, the text parser could never be complete, and a caller check could be faked. Setup now removes its three `approve` ask rules. It prints the commands that remove the installed script and the records, for you to run with the `!` prefix, because workbench-core's destructive-scope guard refuses a removal outside the project.

Tests: `hooks/scripts/test-commit-guard.sh` (each refusal and its reason, the `NAME=value` prefix with a quoted value that holds `;`, `&`, or `|`, the plain forms left to the ask rules, reads left alone, a sub-agent read that names the words and its Grep hint, the exact-match flag, the sub-agent-versus-pipeline interaction, merges prompted in the foreground and refused for a sub-agent and the pipeline in every spelling, merge-like reads left alone, the fail-closed path for an unreadable payload, the `hooks.json` wiring, and the size limit). `hooks/scripts/test-pipeline-scope.sh` feeds `PermissionRequest` payloads against real sandbox roots: one plain git or `rm` line allowed inside the clone and each scratch root; relative, `cd`, and compound lines never allowed; nothing allowed outside the roots through `git -C`, a repository above a root, a path argument, a symlink, or `..`; a planted symlink at either named scratchpad never made a root; a root itself never removed; git's own options refused spaced or attached; every bare, implicit, forcing, or deleting push refused, and a push to the clone's real default branch refused, with a clone whose default is `develop`; a push whose source is a real local tag, a remote-tracking ref, a commit id, an ambiguous name, or a missing ref refused; merges never allowed; deny-listed commands never allowed, with `git log` and `git diff` deny rules that show the rules are read; every shape the grammar cannot read; the exact-match flag; no roots; no `jq`; the pipeline doc's own commit, push, and cleanup lines; and the wiring. `commands/test-commit-ask-rules-setup.sh` runs the setup block for real against a sandbox `HOME`: the ten rules added, existing settings kept, a re-run idempotent, the old approval rules removed, the old script and records reported but left in place, no temporary file left behind, and an unreadable settings file left alone.

**Every setup block passes workbench-core's destructive-scope guard.** That guard refuses a whole Bash call that removes a path it cannot resolve, such as `rm -f "$tmp"`, so a setup step written that way never ran from a session. Every block now holds its new file in a variable, checks it, and writes it in place, with no temporary file and no `rm`. When state outside the roots must go, setup prints `! rm` lines for you to run. `commands/test-setup-scope-guard.sh` checks every shell block in `commands/setup.md`: it greps each one for the guard's verbs, which runs in CI, and also runs the real guard on it when a workbench-core checkout is found.

## Review guard

**Holmes and his helpers read the code under review and run its test suite. They cannot write to it.** Enforced by the harness rather than by prose: the prohibition was already prose at five separate sites across two files, and sat verbatim in every sub-agent prompt Local mode dispatches, and on the mode's first real exercise a lens sub-agent ran `chmod` against the tree under review and changed a script from 755 to 644. It disclosed the breach itself. Prose in an agent prompt is advisory and drifts under pressure.

**The helpers run on their own read-only type.** Every lens, skeptic, red-team, blue-team, and auditor dispatch names `subagent_type: "workbench-dev-team:holmes-lens"` ([agents/holmes-lens.md](agents/holmes-lens.md)), which holds `Bash`, `Read`, `Grep`, and `Glob` and no write tool. The helpers used to go out on `general-purpose`, which carries Write, Edit, and Bash, and that is how one lens mutated a checkout.

This is a **second, independent** hook ([hooks/scripts/local-review-guard.sh](hooks/scripts/local-review-guard.sh)), living beside the commit guard rather than inside it. It runs on `PreToolUse` for `Bash`, `Edit`, `Write`, and `NotebookEdit`, and it applies **one static rule, with no state**: a call whose `agent_type` is `workbench-dev-team:holmes` or `workbench-dev-team:holmes-lens` may not write outside the scratch roots. The scratch roots are the session scratchpad, where Holmes's Index-mode clone and a helper's probe copy live, `~/Developer/scratchpad`, where they live when the session has no scratchpad, and `$TMPDIR`, where a bare `mktemp -d` lands. The rule holds at any time, in both of Holmes's modes, in the scheduled pipeline (where Holmes runs as the main thread of an `--agent` session), and in a helper's own helpers. Claude Code sets `agent_type` from the running agent's own definition on every hook input, so the agent cannot forge it. Every other agent, and your own session, is untouched.

**Why it is static.** The guard used to arm a hold per session when a Local-mode review was dispatched, and release it when the review ended. Every release event the harness offers fired at the wrong time or not at all: a failed or classifier-denied dispatch never reached `PostToolUse`, a background dispatch reached it at launch, and `SubagentStop` could not tell a final stop from a paused turn. The hold existed only because the helpers ran on a write-capable type. With a read-only type of their own, `agent_type` names the reviewer on every call, and there is no lifecycle to track.

**For git, what it refuses is a rule, not a roster — and the rule is inverted.** `GIT_READ_ONLY` in the hook enumerates git's *reading* verbs, and every other git verb is refused, wherever it points. That is the opposite of the list it replaces, which named stash, checkout, reset and clean and therefore never saw `git restore` — the modern spelling, and the single most destructive command available in this context, since it discards precisely the uncommitted change a Local-mode review exists to read. A verb git ships next year is refused on the day it ships, and a verb missing from the read-only set costs a denied read rather than an allowed write. Verbs that both list and write (`branch`, `tag`, `remote`, `config`, `stash`, `worktree`) pass in their listing forms only: `git branch --show-current`, `git branch --contains <sha>`, and `git stash list` run, `git branch -D` and `git stash drop` do not. Beside git, a fixed list of commands that write or remove files — `chmod`, `chown`, `rm`, `mv`, `truncate`, `touch`, `tee`, `cp`, `ln`, `install`, `dd`, `patch`, `mkdir`, `rsync`, `tar`, `unzip`, `sort -o`, `uniq`, and their siblings (a file-mode change *is* a write, and is what the breach used) — is **judged by the paths it writes**, resolved two ways: through every symlink, and with only the final name unresolved, because `rm <dir>/link` removes a link where it lives, wherever it points. It is allowed only when both land strictly beneath a scratch root, and refused when a path cannot be resolved (a variable, a glob, a quote, a relative path with no cwd, or arguments fed by `xargs`), so a reviewer can still clear its own `mktemp -d` directory. `sed -i`, any `--write` / `--fix` / `--in-place` flag, a common formatter's short write flag (`gofmt -w`, `prettier -w`, `clang-format -i`), and a common formatter that writes by default (`black`, `rustfmt`, `cargo fmt`, `go fmt`, `ruff format`, `pint`, `php-cs-fixer fix`) are refused outright, inside a scratch root too, while their check modes (`black --check`, `gofmt -l`, `pint --test`) and their help and config forms run. A formatter is found behind a project runner's run form too (`bundle exec`, `uv run`, `poetry run`, `pipx run`, `pnpm exec`, `npm exec`, `composer exec`, `yarn`), while `npm test` and `uv run pytest` stay silent. `command -v black` is a lookup and runs nothing. Redirection is judged by target path too, so `git diff HEAD > <mktemp path>/x.diff` and `2>/dev/null` still work. **The lists have a limit, stated in the hook's header:** a program on neither list that writes outside the scratch roots runs silently — `gh pr checkout`, which fills Holmes's Index-mode clone, is one — and so does code inside an interpreter, a package script, or a runner the hook does not name (`uvx`, `bun x`). The reviewer prompts' no-mutation rule and the human review of the diff are the backstop. A read allowlist would close that gap and was rejected: it refuses reads too, and a guard that blocks reading gets switched off.

**Reads and the suite stay legal**, which is the binding constraint: a guard that stops either one makes the review useless and gets switched off. `git status`, `git diff HEAD`, `git ls-files`, `git show`, `grep`, and `bash run-tests.sh` all pass. The temporary files a suite writes are invisible to the hook, because it reads the command the agent asked to run and not what that command's script goes on to do — the same boundary the commit guard draws, working in the review's favour here. The verdict is `deny` for the same reason the commit guard's is — of the three a hook can return, only `deny` binds.

**When `python3` is missing or fails**, the guard cannot tell a read from a write. So it refuses every Bash and editing call whose `agent_type` names a reviewer, and every other agent keeps its tools. That is a broken install, and the refusal names the fix.

**What it does not cover**, stated plainly in the hook's own header: a verb inside `bash -c` or inside a script; a review a foreground session runs inline, which carries no `agent_type`; and a reviewer dispatched on some other type, which is why the prose names the helper type on every dispatch and why the prose prohibition stayed where it was — this is a backstop, never a replacement.

It refuses on the two channels a `PreToolUse` hook has, as the commit guard does: `permissionDecisionReason` is the one line a person reads, and `additionalContext` reaches only the model (measured on Claude Code 2.1.274, `insights/2026-09-17-hook-message-channels-measured.md` in the memory vault). You read ``🛑 Blocked: `chmod`. A Holmes reviewer writes only in scratch.``, with its own action word per rule — `git restore`, `sed -i`, `prettier` with a rewrite flag, redirecting output outside the scratch roots — and the reason, the scratch roots, and the allowed alternatives go to the model in `additionalContext`.

Tests: `hooks/scripts/test-local-review-guard.sh` (455 cases — the rule keyed on `agent_type`: Holmes, the helper, a pipeline main thread started with `--agent`, and a nested helper refused, while Watson, a generic type, and a session with no type are untouched; the scratch roots, including a symlinked named root dropped and a root itself never writable; a directory change found behind wrappers and shell keywords (`builtin cd`, `command cd`, `( cd`, `{ cd`, `then cd`, and zsh `chdir`); the `python3` fast path proved by a spy interpreter (skipped for a non-reviewer, reached for a reviewer, through a `\u` escape, and for non-ASCII); every command the reference tells a reviewer to run staying legal; every mutation class refused including the breach command against the tree; every file-writing command allowed beneath a scratch root and refused outside one, through a symlink, on a link entry that points out of a root, or on an unresolvable path; git's listing forms allowed (including `--contains <sha>` and its siblings) and their writing forms refused; a listed writer refused behind each project runner while test runs through those runners stay silent; a write letter bundled into a short-flag cluster refused for the formatters whose parsers bundle; formatter stdin forms left silent; `command -v`, help, and config-printing forms left silent; the three editing tools judged by path with `hooks.json` routing them and nothing else; the `python3` fail-closed path for a missing interpreter and a failing one; redirection judged by target (a descriptor number before `>`, `>|`, zsh's `>!` and `>>!`, and `>& file` all refused outside the scratch roots, while `2>&1`, `>&2`, `2>&-`, and `/dev/null` stay legal); a guard proving no path can return `ask`; the fail-safe inputs; the two-channel split asserted field by field with one action word per rule; and the `--classify` mode). `agents/lint-holmes-local-mode.sh` feeds the reference's fenced blocks to that same classifier, so the shipped documentation and the shipped enforcement cannot drift apart.

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

Prerequisites on your machine: `gh` (authenticated), `jq`, `security` (built into macOS), `git`, and `python3`. The commit guard reads its payload with `jq`, and without it refuses any call whose text names a commit or push. The review guard classifies commands in `python3`, and without it refuses every Bash and editing call from Holmes and his helpers.

You'll be prompted in chat for any of these Keychain entries that aren't already present:

| Entry | Purpose |
|---|---|
| `the-index-mcp / client-id` | The Index OAuth client ID |
| `the-index-mcp / client-secret` | The Index OAuth client secret |
| `github-cli / token` | GitHub token for dispatched agents (auto-extracted from your existing `gh auth login` Keychain entry when present) |
| `claude-code / oauth-token` | Claude Code OAuth token for scheduled `claude -p` invocations. Get one with `claude setup-token` |

### What `/workbench-dev-team:setup` does, in order

The numbers are the setup command's own step numbers.

1. **Asks for the cadence** (20 or 30 min) and whether to register the schedule.
2. **Verifies prerequisites** (`gh`, `jq`, `security`, `git`, `python3`).
3. **Seeds Keychain credentials**; prompts for anything missing.
4. **Fetches an OAuth bearer token** from The Index (client_credentials grant, 1-year lifetime).
5. **Registers The Index MCP** with Claude Code at user scope, passing the bearer via `--header`. This makes `mcp__the-index__*` tools available to every future Claude Code session, including the dispatched agents.
6. **Creates the log directory** at `~/.claude-workbench/dev-team-logs/` and **writes the default agent config** to `~/.claude-workbench/dev-team-config.json` if (and only if) it doesn't already exist, then (6a) stamps each agent's model and effort into its frontmatter. Step 6.5 sets commit attribution.
7. **Step 6.6 installs the ten commit, push, and merge `permissions.ask` rules** (`git commit *`, `git push *`, `git * commit *`, `git * push *`, `git * commit`, `git * push`, `gh pr merge:*`, `gh * pr merge *`, `gh * pr merge`, `gh api *pulls/*/merge*`) and removes what the old approval gate installed. Without this step a foreground commit, push, or merge runs with no prompt, and the pipeline's commits and pushes are not scope-checked. See [Commit approval](#commit-approval).
8. **Step 7a and 7a-bis resolve and verify the orchestrator prompt** — takes the install path from `~/.claude/plugins/installed_plugins.json` (never the running `${CLAUDE_PLUGIN_ROOT}`, which can be a frozen per-session snapshot), strips the frontmatter, and refuses to continue unless the resulting body still has its expected structure — all three dispatch lanes, the circuit breaker's `--mark-escalated` and `--check` calls, and a plausible size. The lane check is derived from the body rather than matched against a list of agent names. Fails closed: an unverifiable body is never deployed.
9. **Step 7a-ter installs the dispatch wrapper** at `~/.claude-workbench/bin/dispatch-agent.sh`, after its own suite and the circuit-breaker suite pass, and adds its `permissions.allow` rules.
10. **Steps 7b–7d register the scheduled Dispatch task** by calling `mcp__scheduled-tasks__create_scheduled_task` (or `update_scheduled_task` if it already exists) directly from the running session, then pin its model on a best-effort basis. Task ID: `workbench-dev-team-dispatch`. Cron: `*/20 * * * *` (or `*/30` if you chose 30 min).

Re-run the skill any time you need to refresh the OAuth token, re-register the MCP, or change the Dispatch cadence. **Also re-run it after a plugin update that changes Dispatch's flow** (a change to `scheduled-tasks/orchestrator.md` or `bin/dispatch-agent.sh`, not the agent contracts): Step 7 reads the prompt file, strips its frontmatter, verifies the body, and passes it as the scheduled task's prompt, so the deployed task holds a *baked-in copy*, and it installs a copy of the wrapper at a stable path. A plugin update refreshes the files on disk but neither copy — the re-run redeploys both. (Agent definitions and skills are read live per dispatch, so those need no re-run — only the Dispatch prompt and its wrapper are copied.)

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
            (Opus 5.5)  (Opus 5.5,$10) (Opus 5.5,$10)
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

Because an agent only writes its status change at the *end* of its run, an item stays lane-eligible for as long as the run takes — so a run that outlives the tick interval would otherwise be dispatched a second time, and the two would race each other's board writes. Every dispatch therefore drops a per-item lock (`<agent>-<id>.lock`, holding the run's PID) next to the logs, and the circuit-breaker pre-flight inside `bin/dispatch-agent.sh` skips any item whose lock PID is still alive. The same pre-flight escalates a wedged item (a content-filter kill, repeated identical fatals, or a budget wall) and grants one raised-budget reprieve when you move an escalated item back, consuming its marker itself. It used to be a ~115-line block the Dispatch prompt re-typed per item per tick, and its `rm` of the marker was denied by workbench-core's destructive-scope guard, so a reprieve repeated every tick. As a second line of defence, Holmes re-reads his item immediately before writing a verdict and writes nothing if it is no longer `In Review`.

### The Index does the filtering

All "what's pending in each lane" logic lives server-side in The Index's MCP tools. Dispatch never interprets item status, field changes, or priority — it just asks The Index "what's pending in each lane?" and fires the matching agent per returned item. Adding a new dispatch rule means editing The Index, not this plugin.

### Concurrency

- **Inspector Lestrade and Sherlock Holmes** are idempotent within a tick. Status lanes (`null` and `In Review`) act as the serialization.
- **Dr. Watson** picks from `In Progress` OR `Ready` (In Progress first — that's the resume path for crashed runs). A per-item **board claim** (`claim_item` / `release_item`) is what stops two Watsons stepping on the same item: it is visible, it works across hosts, and `list_development_items` hides a claimed item. Watson releases it on every exit path, success or not — an abandoned claim hides the item from the lane for good. There is deliberately **no** host-wide lock, so two Watsons on two different items run side by side.
- **Watson also refuses work that isn't his**, on two independent gates, both fail-closed and both leaving the item's status exactly as it found it. A **status gate** drops any item dispatched outside the `Ready`/`In Progress` lane (or with an unreadable status) — he never moves an item into his own lane to justify working it. A **provenance check** in resume detection means he only ever adopts a branch he created himself, identified by a `Watson-Branch: #<issue>` trailer on its start-of-work commit (PR authorship can't serve: he opens PRs with `gh` under your credentials, so his PRs and yours both read as you). Both gates exist because GitHub Projects' built-in *Pull request linked to issue* workflow flips a linked issue to `In Progress` seconds after **anyone** opens a branch-named PR — including yours, which is how a human's work-in-progress once got commits pushed onto it and, on a branch prefix the old matcher didn't know (`ci/`), got a duplicate PR opened beside it. The hands-off notice is posted once per branch (an `<!-- watson-hands-off: <branch> -->` marker on the issue tells him he has already said it) — that same Projects workflow parks the issue in `In Progress` for the whole life of your PR, so he is dispatched onto it every tick until you close it, and the notice would otherwise repeat every twenty minutes.

### Token cost

| Scenario | Tokens |
|---|---|
| Idle Dispatch tick (no work in any lane) | The prompt (about 11K characters, roughly 3K tokens), one `ToolSearch`, and four list calls on the router model. Each dispatched item adds one `dispatch-agent.sh` call |
| Lestrade triage | 5–8K `claude-opus-5-5[1m]` tokens at medium effort + four blind Sonnet lens sub-agents verifying the draft AC |
| Lestrade blocker sweep | `claude-opus-5-5[1m]` tokens scaling with open-issue count (reads every open title + body in the repo); fires only on ticks that triaged new items |
| Holmes review | `claude-opus-5-5[1m]` parent at medium effort + four blind Sonnet lens sub-agents + adversarial verification per blocker (a 3-agent red/blue/auditor panel for security findings every round and for hard defects on the PR's first review; one skeptic for everything else; at most 10 verifications per review); capped at $10 per run |
| Watson development | Full `claude-opus-5-5[1m]` session at medium effort, capped at $10 per run |

The scheduled-tasks tools expose no model selector, so a registered task inherits the app's default model. Setup Step 7d then pins Dispatch to `claude-sonnet-5` by patching the per-profile `scheduled-tasks.json` directly. That file is not a supported API, so the patch is best-effort: confirm the model in the Scheduled panel after setup.

## Dispatch paths

Two ways to invoke the same agents, same definitions:

1. **Unattended (default).** The scheduled Dispatch task polls The Index every 20 minutes and dispatches via `claude -p --agent`. This is what `/workbench-dev-team:setup` registers.
2. **Interactive.** Any Claude Code session can dispatch an agent directly via the Agent tool, e.g., `Agent(subagent_type: "workbench-dev-team:lestrade", ...)`. For multi-agent delegation with config-driven models, background execution, and roster tracking, use the `orchestrate` skill — it wraps this path with the full protocol. Useful for manual triage, one-off runs, ad-hoc dev work (Watson Direct mode), or debugging without waiting for the next scheduled tick. **One exception: an Index item you want built now.** The Agent tool cannot set an environment variable on the agent it spawns, so an Index-mode Watson dispatched through it carries no pipeline flag and refuses before it claims the item. Run `bash "$HOME/.claude-workbench/bin/dispatch-agent.sh" watson <item-id>` for that — the same wrapper the scheduled task uses, immediately.

## Monitoring

- **Agent logs.** `~/.claude-workbench/dev-team-logs/<agent>-<item>-<timestamp>.log` — full agent output per dispatch.
- **Review-learnings notes.** `dev-team/review-learnings/<repo>-pr<n>-<date>.md` (one note per bounce/escalation, written by Holmes at re-review) and `dev-team/top-lessons.md` (the frequency-ranked digest Watson and Lestrade read) in your memory vault. Nothing there yet means no PR has bounced or been AC-disputed since this shipped.
- **Scheduled task panel.** Claude Code's scheduled-tasks panel shows the Dispatch task's run history and next-run time.
- **Project board.** Items flow Inbox → Backlog → Ready → In Progress → In Review → Approved / Escalated. Status drift (items stuck in a column) is your canary.

## Tests and CI

`bash run-tests.sh` runs the whole suite from the repo root and exits non-zero if
anything fails. Pass `tests` or `lints` to run one group.

The two groups are named apart on purpose:

- **`test-*.sh`** — eleven scripts that execute shipped shell logic and assert
  on its behaviour. Five run a shipped `.sh` as a subprocess. Five extract the
  real bash from between sentinel markers in a Markdown prompt and run it against
  fixtures, so the test cannot drift from the logic it guards. One,
  `commands/test-setup-scope-guard.sh`, checks every shell block in
  `commands/setup.md` against workbench-core's destructive-scope guard.
- **`lint-*.sh`** — six scripts that grep English prose and YAML frontmatter in
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
| Item stuck in `In Review` with no PR | Holmes couldn't find a PR for the issue. He looks for the PR linked through `Fixes #<issue>`, then for Watson's branch pattern. Check `gh issue view <issue> -R <repo> --json closedByPullRequestsReferences`. |
| Scheduled task isn't firing | Check Claude Code's scheduled-tasks panel. The Mac must be awake (this is a local scheduler). |

## Risks and limitations

- **Local execution.** Dispatch runs on your Mac. If the host is off, no work moves. Fine for home/dev setups; move Dispatch to an always-on box if you need 24/7 coverage.
- **Budget caps.** `--max-budget-usd 10.00` limits Watson's per-run spend, and Holmes's too (`10.00` in the shipped config and as the dispatcher's fallback when the config is missing), since its lens fan-out is the only uncapped, multi-agent lane — measured over 50 fan-out reviews, a review's mean cost is ~$7.33 with a long tail past $17 when Phase C verification fires, so a cap at $7 sat below the median and killed roughly a quarter of runs mid-review. Complex work may hit the ceiling and leave the item in `In Progress`; the next tick resumes. (The $10 figure was originally sized for Fable's 2× Opus pricing; on Opus it now buys roughly twice the tokens per run.)
- **The Index must be reachable.** If the MCP server is down, all three list tools fail and Dispatch logs `the-index unreachable` and exits cleanly. The next tick retries.
- **OAuth token lifetime.** The Index issues 1-year tokens via client_credentials. Re-run `/workbench-dev-team:setup` annually (or whenever you rotate the OAuth client secret).

## Manual task registration (fallback)

If `/workbench-dev-team:setup` fails at Step 7 (scheduled-task registration), choose "Skip" when re-prompted to register the schedule, then register manually from any Claude Code session:

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
