---
name: develop
description: Apply universal development standards when implementing code changes, fixing bugs, refactoring, writing tests, or any task that writes or modifies source code. Use this skill BEFORE writing or changing code — every time, manual or agent-driven — to ensure consistent conventions, testing, commit hygiene, and a human-in-the-loop decision protocol across all development work. Triggers on requests to "implement", "build", "fix", "add", "refactor", "write a test", "code up", or any prompt that produces code changes.
---

# Development Workflow

Universal standards for any code implementation work. The goal isn't compliance —
it's predictably high-quality changes that future-you (or anyone else) can read,
trust, and extend.

## Decision Protocol — present options, don't decide alone

When you hit a fork — choosing between approaches, libraries, structures, scopes,
or fixes — **stop and surface three options to the human** with reasoning for
each, and a recommendation for the best one. The human decides; you execute.

**What counts as a fork:**

- Choosing between distinct implementation approaches (algorithm, data structure,
  architecture pattern)
- Picking a library or dependency when multiple reasonable options exist
- Deciding scope (fix the symptom vs. fix the root cause; refactor first vs.
  patch then clean up later)
- Naming or API design choices not already implied by repo conventions
- Trade-offs with meaningful long-term consequences

**What doesn't count — just do it:**

- Mechanical translation of clear requirements into code
- Following an existing repo convention (the repo already made that decision)
- Tiny stylistic choices implied by sibling code
- Obvious one-line fixes with no real alternative

**Format when presenting options:**

```
1. **Option A** — short description.
   Pros: ...
   Cons: ...

2. **Option B** — short description.
   Pros: ...
   Cons: ...

3. **Option C** — short description.
   Pros: ...
   Cons: ...

**Recommendation: B** — because [reason this is the best fit].
```

Then **wait for the human's pick** before proceeding. Don't half-commit by
starting on the recommended option while waiting — that's the same as deciding
unilaterally, just with extra steps.

If you genuinely can't think of three viable options, surface that — "I can only
see two reasonable approaches here, A and B. Want me to pick a stretch
third option, or is this a two-way choice?" Honest is better than padded.

## 1. Orient before writing

- **Read `CLAUDE.md` if present.** Repo conventions take precedence over personal
  preference. Always.
- **Scan siblings of the file you're about to touch.** Match existing patterns —
  naming, error handling, structure, test organization. Don't impose new
  conventions on a codebase mid-stream.
- **Look at recent commits** (`git log --oneline -20`) for the prevailing commit
  format and the kinds of changes that land. Pattern-match.

If the repo has no `CLAUDE.md` and conventions are unclear from sibling files,
flag it — don't guess.

## 2. Plan before coding

- **Read the requirements end-to-end** before touching anything.
- **If acceptance criteria are missing or ambiguous, stop.** Ask, or report.
  Inventing requirements creates the wrong thing well.
- **Stay scoped.** Only change what the task requires. Unrelated cleanup goes in
  a separate change — note it, don't fold it in.
- **Read the review-learnings digest first, if one exists.** Holmes records what
  he rejects and what fixed it, and a lightweight note on a clean first-pass
  approve, directly to the memory vault at review time (no separate harvester
  agent). If `dev-team/top-lessons.md` exists (a frequency-ranked digest of
  recurring rejection categories, each with the concrete prevention rule, plus a
  running clean-approval tally above the list for context), read it via the
  memory MCP and apply every rule to what you're about to write. Absent (nothing
  recorded yet)? Skip it and rely on §4 below — never block on its absence.

## 3. Implement

- **YAGNI — build the least that satisfies the AC.** Implement only what the
  current requirement needs. No speculative abstraction, config knobs,
  extension points, or "future-proofing" nothing asks for yet — that code is
  unproven, untested-against-reality, and a cost the next reader inherits. When
  a need actually arrives, add it then. The simplest thing that passes the AC
  and the tests is the target, not a floor to build past.
- **YAGNI stops at the trust boundary.** Minimalism never means dropping a
  safeguard the AC didn't spell out. A *trust boundary* is any point where data
  crosses from a less-trusted source into your code — user input, request
  payloads, query params, uploaded file contents, external API responses,
  webhook bodies, anything off the wire or out of a DB you don't control.
  Input validation at those boundaries, error handling that prevents data loss,
  authn/authz and other security measures, and accessibility basics are not
  optional scope — build them whether or not the ticket enumerates them. "The
  least that satisfies the AC" means the least *correct and safe* version, not
  the least code that demos.
- **Prefer the most concise solution that stays readable.** Reach for the
  one-liner or the single idiomatic expression over a verbose multi-step
  construct *when it's just as clear*. Concision is a means to readability, never
  an end in itself — never trade clarity for brevity, and never cram unrelated
  logic onto one line to save a line. Plain-and-obvious beats clever-but-opaque
  every time. When two options are the same size, pick the one that's correct
  on the edge cases — concise means less code, never the flimsier algorithm.
- **Prefer the framework's idioms over raw language primitives.** When the
  project runs on a framework, reach for what it already provides instead of
  hand-rolling against the bare language — in Laravel, collections over raw
  arrays, Eloquent over hand-built queries, the framework helper over a
  reimplementation. The provided abstraction is tested, conventional, and
  shorter; the raw-primitive version is more code doing the same job worse.
- **Match the existing style.** Imports, naming, formatting, error handling —
  copy what's already there.
- **One logical change at a time.** If a refactor enables the actual fix, commit
  the refactor separately, before the fix.
- **Don't add dependencies casually.** Each one is a maintenance and supply-chain
  surface that outlives the immediate convenience. Check the project's existing
  deps first — chances are something close already exists. Prefer well-maintained,
  widely-used packages over niche ones. And for tiny utility functions (a few
  lines), a little copying is better than a little dependency.
- **Keep docs and comments in sync with the code.** If your change makes an
  existing comment, README section, JSDoc/docstring parameter, or type signature
  wrong, update it in the same commit. Stale docs and comments actively mislead
  — they're worse than missing ones, because the next reader trusts them. For
  external docs (Notion, Confluence, design specs), flag what needs updating
  even if you can't change them yourself.
- **No WebFetch.** Reason from the repo. If you can't, planning missed
  something — go back to step 2.

## 4. Test

- **Every change gets a test.** Bug fixes get a regression test; features get
  coverage of the new behavior; refactors get tests that prove behavior didn't
  change.
- **Every new branch, field, error-path, and edge gets a discriminating test** —
  not just the happy path. A test only counts if it *fails when that specific
  behavior regresses*: cover each new conditional branch, each new field, each
  error / absent-input path, and the boundary cases — not merely the one path
  that demos.
- **Mutation-test your own tests.** For every test guarding a behavior, delete or
  invert the guarded code and confirm the test **goes red**. A test that stays
  green when its target breaks is theater — it asserts trivia or the wrong thing.
  Rewrite it until it discriminates, then restore the code. This is the single
  cheapest defense against the most common review rejection: tests that don't
  actually test.
- **Fail closed by default.** For every error, absent-field, or unexpected-input
  path, state the behavior explicitly and default to **fail-closed** — reject,
  throw, or refuse — never fail-open (silently proceed, swallow the error, or
  return a default that masks the problem). Then test the closed path, not just
  the open one.
- **Use the repo's existing framework.** Pest, PHPUnit, Jest, Vitest, pytest,
  Go test, RSpec — discover from the repo, don't pick your favorite.
- **Run the full suite.** Don't push until it's green. Fix failures (yours or
  pre-existing) before proceeding.
- **Grep the tree for every symbol or documented claim your diff changed**
  (doc-drift). Renamed a symbol, changed a documented behavior, altered a
  contract or type signature? `grep`/`rg` for every reference — code, comments,
  README, docs — and update each in the same change. A stale reference the tests
  won't catch is a silent regression for the next reader.
- **Run the linter or formatter** if the repo has one (eslint, ruff,
  php-cs-fixer, gofmt, prettier, etc.). Fix violations rather than disabling
  rules.

## 5. Commit

### 🔒 Commit approval gate — non-negotiable

**Which lane you are running in decides what you may do at all.** A plugin
`PreToolUse` hook (`hooks/scripts/commit-approval-gate.sh`) sorts every Bash
call into one of three, and its verdict is `deny`, in every permission mode.

**You are a sub-agent → you do not commit, merge, or push.** The hook refuses
every git verb that writes a commit, integrates another history, or publishes
one, plus `gh pr merge`. **No approval command is offered to you, and that is
deliberate — anything you can run yourself is not an approval.** The denial
carries no request id, writes no pending record, and ignores any record you
might write by hand, so there is no route to find. Do not go looking for one.

**Hand the work back instead**, in your final report:

1. Leave the working tree **uncommitted**, exactly as your change left it.
2. Summarize the diff — files touched and what changed in each.
3. Give the **proposed commit message**, formatted via the
   `/workbench-dev-team:git-commit` skill.

The session that dispatched you commits it. A prompt reaches a human there, and
reaching a human is the entire point.

**You are the foreground session → attempt the commit or the push yourself, and
let the gate prompt.** Every `git commit` and every `git push` needs the human's
explicit approval of that specific command. Do not hand either one to the human
to run: the gate is how the human is asked. A push that forces or deletes
remote refs (`--force`, `-f`, a `+` refspec, `--mirror`, `--delete`, `-d`, a
`:branch` refspec, `--prune`) is refused with no approval path, and merge stays
an explicit human request.

**Write it as the plain form, or it is refused.** The gate does not parse bash.
It prompts only for one line that is exactly `git [-C <path>] commit …`,
`git [-C <path>] push …`, or `git [-C <path>] commit … && git [-C <path>] push …`,
with every word bare or quoted. A double-quoted string may not hold `$`, a
backtick, or a backslash. There is no `cd`, pipe, redirect, comment, heredoc,
variable, wrapper, or second line, and no bare word that starts with `=`. Any
other command whose text names git and a commit or push is refused with no
approval path, and so is one that names git and holds a shell-building
character. Write it this way from the start, so the first attempt is the one the
gate prompts for:

- Run `git add` as its own call, never chained to the commit.
- Write a multi-line message to a file in the session scratchpad, and commit
  with `git commit -F <absolute path>`. Claude Code's default
  `git commit -m "$(cat <<'EOF' … EOF)"` is refused. A one-line message can go
  in `-m '…'` or `-m "…"` with no `$`, backtick, or backslash.
- Use `-C <path>` rather than `cd`.
- Never use a shell alias such as `gp` or `gcmsg`: the gate cannot see through
  one, so it would commit or push unprompted.

If an innocent read is refused because its text names a verb, run it on its own
line. Before any commit:

1. **Show the diff** that will be committed — the human reviews the actual
   change, not your summary of it.
2. **Show the proposed commit message** (formatted via the
   `/workbench-dev-team:git-commit` skill).
3. **Wait for an explicit yes.** General approval of the task, "looks good"
   about the code, or approval of a *previous* commit do not carry over.
   One approval covers one commit — for multi-commit work, present each
   commit (or an explicitly enumerated batch) for its own approval.

Before a push, show what it publishes: the branch, the remote, and the commits
it sends. Then attempt it.

The denial here is not a wall, it is the next step, and it prints one:

```
bash "$HOME/.claude-workbench/bin/approve-commit.sh" <request-id> "<commit subject>"
```

For a push it prints the same command with no subject, because a push has none.

Run that command *after* doing the steps above, never before. Permission rules
cover it, so the harness raises a real prompt the human must answer, and their
answer is the approval. Then run the same `git commit` or `git push` again — the
same one, from the same directory: the approval is bound to that exact command,
to your agent, to this session, and to the working directory, it is spent by the
run that uses it, and it expires in 15 minutes. A commit is also bound to HEAD
and the staged diff, and to the working tree when it takes files from there
(`-a`, `--only`, `--include`, or a pathspec), so restaging voids the approval. A
push is also bound to the repository's branches, tags, HEAD, and remote, branch,
push, and url config, so a pull, rebase, or new commit before it runs voids the
approval and asks again.

Two rules about the command itself. Run it **exactly** as the denial prints it,
because a different spelling is not covered by the rules and prompts nobody.
And never run it before the human has seen what it approves: the prompt asks
them to approve a commit or a push, and only your output tells them what is in
it.

If it refuses — missing permission rules, or an id with nothing waiting —
report that and stop. `/workbench-dev-team:setup` installs the command and its
rules; until it has run, no commit or push can be approved. That is the gate failing
closed, which is the designed direction. Never edit the gate, never set
`WORKBENCH_DEV_TEAM_PIPELINE`, and never write an approval record by hand.

**You are the autonomous Index pipeline → commit and push unattended.**
Scheduled runs are headless; there, dispatching an item to the board is the
approval, and Holmes review plus the human's PR merge is the gate. The hook
recognizes the pipeline by `WORKBENCH_DEV_TEAM_PIPELINE=1`, which
`bin/dispatch-agent.sh` exports onto the process it spawns, and it checks that
first — so a scheduled agent commits and pushes freely while an unflagged one
cannot. Never set that variable yourself. An Index item you want built from a
conversation is dispatched with
`bash "$HOME/.claude-workbench/bin/dispatch-agent.sh" watson <item-id>`, which
sets the flag for you. The Agent tool cannot set it, so an Index-mode run
spawned that way is a sub-agent like any other, and is refused at its first
commit.

### Message format and hygiene

Use the `/workbench-dev-team:git-commit` skill for message format —
Conventional Commits + Gitmoji. Beyond format:

- **Don't commit secrets.** Scan your diff for credentials, tokens, API keys,
  PII. Verify `.env`-shaped files are in `.gitignore`. If anything smells like
  a credential, stop and remove it before staging.
- **Re-read your own diff before staging.** `git diff` what you're about to
  commit — catch debug `console.log`s, commented-out code, TODOs you forgot
  to address, leftover scaffolding.
- **Confirm you're on a feature branch** (not `main`/`master`/`trunk`) before
  pushing.
- **Atomic commits.** One logical change each. Don't bundle.
- **Never force-push** to a shared branch.
- **Never amend** an already-pushed commit. If you need to change something,
  add a new commit.

## 6. Open a PR (when applicable)

When the work is for a tracked issue:

- **Create the PR as a draft early** — before implementation is complete.
  Visible work-in-progress is better than a black-box dump at the end.
- **Use the repo's PR template when one exists.** `gh pr create --body`
  silently bypasses templates, so discover and apply it yourself. Check, in
  order: `.github/PULL_REQUEST_TEMPLATE.md`, `PULL_REQUEST_TEMPLATE.md`
  (root), `docs/PULL_REQUEST_TEMPLATE.md` — any letter case — and
  `.github/PULL_REQUEST_TEMPLATE/` (multiple templates; pick the one that
  fits the change, or the default). Fill its sections honestly — never leave
  boilerplate placeholders or HTML comments behind. If the template has no
  slot for something required below (issue link, acceptance criteria, test
  plan), append it after the template content. No template → use the
  structure in the next bullets.
- **Use `Fixes #<n>`** in the body for auto-linking.
- **Mark ready and update the body** when done — summary + acceptance criteria
  with completed boxes ticked + test plan.
- **CI green is the real "done" line.** Local-green isn't enough — CI runs checks
  your machine may skip (strict lint gates, integration suites, environment
  differences). The work isn't done until CI is green. For automated or
  unattended work especially, wait for CI to finish and fix any failures before
  handing the PR off for review — never pass a red PR downstream.

## 7. When stuck

- **Tests fail and you can't fix them?** Leave the branch in a clean state
  (committed, pushed, PR reflects current state). Report what you tried and
  what's failing.
- **Need info you can't get from the repo?** Don't WebFetch, don't invent.
  Report the gap and what would unblock you.
- **At a fork without a clear recommendation?** Apply the Decision Protocol —
  present three options to the human and let them choose. Reaching for the
  protocol is not a failure; deciding unilaterally is.
