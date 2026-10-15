---
name: develop
description: Apply universal development standards when implementing code changes, fixing bugs, refactoring, writing tests, or any task that writes or modifies source code. Use this skill BEFORE writing or changing code — every time, manual or agent-driven — to ensure consistent conventions, testing, commit hygiene, and a human-in-the-loop decision protocol across all development work. Triggers on requests to "implement", "build", "fix", "add", "refactor", "write a test", "code up", or any prompt that produces code changes.
---

# Development Workflow

Universal standards for any code implementation work.

## Your lane decides what finishing looks like

Three lanes run this skill, and several steps below end differently in each.
Know which one you are in before you start.

- **Foreground session** — a human is in the conversation. You can ask and wait,
  and you commit only on an approval §5 names.
- **Sub-agent** — dispatched through the Agent tool, Watson's Direct mode
  included. No human is reachable, the commit guard refuses every commit and
  push, and you do not merge. You finish with an **uncommitted working tree and a report**:
  the diff summary and a proposed commit message. The report never asks to
  commit. There is no PR to open.
- **Scheduled Index pipeline** — `bin/dispatch-agent.sh` spawned you with
  `WORKBENCH_DEV_TEAM_PIPELINE=1`. You commit, push, and open the PR unattended,
  and never ask about committing or pushing. Board dispatch is the approval,
  and Holmes's review plus the human's merge is the gate.

## Decision Protocol — grade the options against the AC, don't decide alone

When you hit a fork the human has not already decided — choosing between
approaches, libraries, structures, scopes, or fixes — **draft three options
from different angles, grade each one against every acceptance criterion, and
recommend the best.** A real fork is the human's to decide, and you execute. A
fork they already decided is not asked again.

**`/workbench-core:intake` is the one written copy of this routine.** Its steps
6 to 8 hold the distinctness check, the grading, and the test for when a fork
goes to the human. Follow them there. This section adds what dev work needs,
and restates only the minimum a run needs when intake is absent.

**The criteria you grade against depend on your lane.** In a foreground session
they are the ones in your intake block. As a sub-agent they are the brief's
`Acceptance:` list. In the scheduled pipeline they are the item's acceptance
criteria, written by Lestrade at triage.

**What counts as a fork** (both lists in full:
`references/decision-protocol.md`):

- Choosing between distinct approaches, libraries, or scopes
- A public interface others will depend on, which repo conventions do not
  already imply
- Trade-offs with meaningful long-term consequences

**What doesn't count — just do it:**

- A choice the human already made. Follow it, and do not present it as options
- Mechanical translation of clear requirements, or an existing repo convention
- Naming, and other small choices implied by sibling code or cheap to change later
- Obvious one-line fixes with no real alternative

**Three distinct angles, checked before you grade.** Three settings of one
approach are one option. Run intake's distinctness check, and replace any
variant.

**Grade all three against every criterion** as met, partly met, or not met,
with a short reason for anything short of met. The recommendation is the best
grade. On a tie, the architecturally correct option beats the fastest one.

**Format when presenting options.** Put the three options in one table with
the columns Option, Pros, Cons, and Grade. The Option cell names the option's
angle in a short title. Keep each cell to a short phrase, so the table fits 80
columns. A grade of "All met" covers every criterion. Any other grade names
each criterion short of met by its number and a few words, so it reads without
the criteria list in view. After the table, one or two sentences name the
recommendation, its grade, and its reason. Never fold the recommendation into
the table.

```
| Option            | Pros           | Cons           | Grade                 |
|-------------------|----------------|----------------|-----------------------|
| A: <angle, short> | <short phrase> | <short phrase> | All met               |
| B: <angle, short> | <short phrase> | <short phrase> | AC2 partly met: <why> |
| C: <angle, short> | <short phrase> | <short phrase> | AC1 not met: <why>    |

I recommend A (all met), because <the one reason it beats the others>.
```

**A decision for the human goes through `AskUserQuestion`.** Show the table in
the reply first, even a sub-agent's, whose hand-back the human never sees.
Never name an option the reply does not show. Put the recommended option
first. Each option's description carries its grade and any warning, so the
question stands on its own after the table has scrolled away. Ask every other
question the same way, never in prose. A question with no fixed choices still
fits, because the dialog always offers Other. Ask each one right after the
context it depends on first appears, with that context in prose just above the
call, not at the end of the reply.

**What happens next depends on your lane.**

- **Foreground session:** intake's step 8 decides whether the fork goes to the
  human. If it does, ask through `AskUserQuestion` and wait for the pick.
  Don't start on the recommended option while waiting: that is deciding
  unilaterally. If it does not, proceed on the top-graded option and say so
  in one line that names its grade on each criterion.
- **Sub-agent:** you never interview, because the brief is your intake, and
  nobody can answer you mid-task. So the bar is **blocking uncertainty**. Below
  it — a fork where any of the options would satisfy the brief and the choice
  is cheap to reverse — pick the top-graded option, go on, and record the choice
  and its grades as an assumption in your report. Above it — a fork where the
  wrong pick means work the sender would throw away — stop, change nothing more,
  and return the three graded options as your report.
- **Scheduled pipeline:** route the fork as Watson's pipeline describes (step 6,
  "If a fork blocks you").

If you can't find three viable options, say so rather than pad a third:
`references/decision-protocol.md`.

## 1. Orient before writing

- **Read the repo's written conventions, wherever they live.** `CLAUDE.md`,
  `AGENTS.md`, `CONTRIBUTING.md`, and anything under `.ai/guidelines/`,
  `.ai/rules/`, or `docs/review-wiki/`. Repos keep binding rules in all of these,
  and a rule you did not read is a rule you will break. Repo conventions take
  precedence over personal preference. Always.
- **Scan siblings of the file you're about to touch.** Match existing patterns —
  naming, error handling, structure, test organization. Don't impose new
  conventions on a codebase mid-stream.
- **Look at recent commits** (`git log --oneline -20`) for the prevailing commit
  format and the kinds of changes that land. Pattern-match.

If the repo has none of those files and conventions are unclear from sibling
files, flag it — don't guess.

## 2. Plan before coding

- **Read the requirements end-to-end** before touching anything.
- **If acceptance criteria are missing or ambiguous, stop.** Ask, or report.
  Inventing requirements creates the wrong thing well.
- **Stay scoped.** Only change what the task requires. Unrelated cleanup goes in
  a separate change — note it, don't fold it in.
- **Read the review-learnings digest first, if one exists.** If
  `dev-team/top-lessons.md` exists, read it via the memory MCP and apply every
  rule to what you're about to write. Who writes it and what it holds:
  `references/vault-reads.md`.
- **Search the vault's `feedback/` folder before you implement — required.**
  The human's own corrections live there, and no review rejection records
  them, so the digest above cannot carry them. Run at least two searches with
  `folder: "feedback"`: one for this repo, and one for what you are about to do,
  in the words a rule about it would use (the tool, the file type, the kind of
  change). Read every hit that bears on the task and follow it; where a rule
  conflicts with this skill, the rule is the more specific one and wins.
- **Both reads degrade gracefully.** No memory MCP, no digest, or no hits? Say so
  in your report and go on with §4 below — never block on their absence.

## 3. Implement

Each rule in full, with its reasons and examples: `references/implementation.md`.

- **YAGNI — build the least that satisfies the AC.** No speculative
  abstraction, config knobs, extension points, or "future-proofing" nothing
  asks for yet. When a need actually arrives, add it then.
- **YAGNI stops at the trust boundary.** Where data crosses into your code from
  a less-trusted source (user input, payloads, uploads, external API responses,
  webhooks, a DB you don't control), build input validation, error handling
  that prevents data loss, authn/authz and other security measures, and
  accessibility basics, whether or not the ticket enumerates them. "The least
  that satisfies the AC" means the least *correct and safe* version.
- **Prefer the most concise solution that stays readable.** Reach for the
  one-liner *when it's just as clear*, but never trade clarity for brevity, and
  never cram unrelated logic onto one line. Of two options the same size, pick
  the one that's correct on the edge cases.
- **Prefer the framework's idioms over raw language primitives** — in Laravel,
  collections over raw arrays, Eloquent over hand-built queries.
- **Match the existing style.** Imports, naming, formatting, error handling —
  copy what's already there.
- **One logical change at a time.** If a refactor enables the actual fix, do
  the refactor first.
- **Don't add dependencies casually.** Check the project's existing deps first,
  prefer well-maintained, widely-used packages, and copy a few lines rather
  than add a tiny dependency.
- **No comments in code** unless the project's linter or config requires them.
  Names, structure, and tests describe the code. Leave comments in untouched
  code, and delete one your change makes wrong rather than rewrite it.
- **Keep docs in sync.** Update any README or type signature your change makes
  wrong, in the same commit, and flag external docs you can't change.
- **No WebFetch.** Reason from the repo. If you can't, planning missed
  something — go back to step 2.

## 4. Test

The tier, mutation, and doc-drift rules in full: `references/testing.md`.

- **Every change gets a test.** Bug fixes get a regression test; features get
  coverage of the new behavior; refactors get tests that prove behavior didn't
  change.
- **Write each test at the lowest tier that can prove the behavior:** unit
  before feature before integration. A feature or integration test names the
  boundary a lower tier cannot reach. This wins over upstream guidance that
  says otherwise, such as Laravel Boost's, and you state the departure.
- **Every new branch, field, error-path, and edge gets a discriminating test** —
  not just the happy path. A test only counts if it *fails when that specific
  behavior regresses*: cover each new conditional branch, each new field, each
  error / absent-input path, and the boundary cases — not merely the one path
  that demos.
- **Mutation-test your own tests.** For every test guarding a behavior, delete or
  invert the guarded code and confirm the test **goes red**. A test that stays
  green when its target breaks is theater: rewrite it until it discriminates.
  **Never restore a mutation with `git checkout`, `git restore`, or
  `git stash`:** each reverts the whole file to the last commit, erasing your
  uncommitted work too. Confirm your final diff holds no mutation.
- **Fail closed by default.** For every error, absent-field, or unexpected-input
  path, state the behavior explicitly and default to **fail-closed** — reject,
  throw, or refuse — never fail-open (silently proceed, swallow the error, or
  return a default that masks the problem). Then test the closed path, not just
  the open one.
- **Use the repo's existing test framework**, never your favorite.
- **Run the full suite, and get it green for your change.** Fix every failure
  your change caused. A failure your change did not cause is out of scope
  (§2): confirm it fails the same way without your change, then report it
  rather than fold a fix in.
- **Grep the tree for every symbol or documented claim your diff changed**
  (doc-drift) — code, comments, README, docs — and fix each in the same change.
- **Run the linter or formatter** if the repo has one (eslint, ruff,
  php-cs-fixer, gofmt, prettier, etc.). Fix violations rather than disabling
  rules.
- **Self-review the diff before you hand it on.** Read the whole diff you are
  about to commit or report, as a reviewer would: debug output, commented-out
  code, an unrequired comment, forgotten TODOs, leftover scaffolding, a
  mutation you did not revert, and anything that smells like a credential.

## 5. Commit

**Which lane you are in decides what you may do at all.** Claude Code
`permissions.ask` rules, installed by `/workbench-dev-team:setup`, prompt the
human for each commit, push, and merge no typed request covers. The commit
guard (`hooks/mods/commit-guard.ts`) refuses what those rules cannot cover. It
is a mistake-catcher, not a security boundary.

**Sub-agent → you do not commit, merge, or push.** The guard refuses your
commit, your push, and your pull request merge, keyed on your lane. Do not look for another route, and never reword, split, encode, or
rebuild a command to get past a refusal. **Hand the work back instead**, in
your final report:

1. Leave the working tree **uncommitted**, exactly as your change left it.
2. Summarize the diff — files touched and what changed in each.
3. Give the full `git status --short --untracked-files=all` output.
4. Give the **proposed commit message**, formatted via the
   `/workbench-dev-team:git-commit` skill.
5. Say plainly that the work is uncommitted. A report that reads as finished,
   on a tree that is not, is how a change gets lost.

The report never asks to commit and never invites a commit: prompting the
human is the orchestrator's job, and so is the commit. An Index-mode run that finds its commits refused was dispatched
without the pipeline flag: report that to the session that dispatched you, and
stop.

**Foreground session → commit on a typed request, or after a "Commit it" pick
in `AskUserQuestion`, once the human says their review is done.** A prompt the
human types that names commit, push, or release approves exactly those actions,
for the turn that prompt opened. A negated, deferred, or question-form prompt
approves nothing, and only the human's own typed prompts count. Ask the commit
question alone, and never lead with "Commit it" before their review is done.
Typed requests skip the prompt only in the shapes git-commit lists. A
pick is the only prompt for its commit and push, in those shapes. A pick never
approves a release. Stage with `git add -A` on its own line, then run a commit
that names no path. A never-ship file stays out only when your reply above the
commit call names its path. Read `/workbench-dev-team:git-commit` first.

**Scheduled pipeline → commit and push unattended.** The pipeline never asks
about committing or pushing, and never waits for approval: board dispatch is
the approval. `bin/dispatch-agent.sh` marks the pipeline with
`WORKBENCH_DEV_TEAM_PIPELINE=1`. `hooks/scripts/pipeline-scope.sh` answers
the prompt for one plain `git -C <clone>`, rm, or rmdir line whose every path is
absolute and stays inside the roots, and nothing else. The roots are all of
`$TMPDIR`, so another run's clone is in scope too, and the scratch roots. The
pipeline never merges a pull request.
Never set that variable yourself, and never edit the guard.

### Message format and hygiene

Use the `/workbench-dev-team:git-commit` skill for message format —
Conventional Commits + Gitmoji. Beyond format:

- **Don't commit secrets.** Scan the diff and read every untracked file for
  credentials, tokens, API keys, and PII. Verify `.env`-shaped files are in
  `.gitignore`. Hold back a file with a secret, and tell the human.
- **Confirm you're on a feature branch** (not `main`/`master`/`trunk`) before
  pushing.
- **One commit takes the whole tree, in every lane.** Never split it unasked or
  ask which files go in. The commit question lists every file. If the tree
  changes after it, ask again, and drop no file. Leave out only what must never
  ship, and tell the human in one sentence.
- **Never force-push** to a shared branch.
- **Never amend** an already-pushed commit. If you need to change something,
  add a new commit.

## 6. Open a PR (foreground and pipeline lanes)

A sub-agent opens no PR: it has nothing committed to open one from. Its report
is the handoff, and the session that commits the tree decides about the PR.

When the work is for a tracked issue, read `references/pull-requests.md` as soon
as you start on it, and follow it.

**Never request a reviewer.** Mike requests every review himself.
`references/pull-requests.md` lists the four routes.

## 7. When stuck

- **Tests fail and you can't fix them?** In the pipeline, leave the branch clean
  (committed, pushed, PR reflects current state). As a sub-agent, leave the tree
  uncommitted. Either way, report what you tried and what's failing.
- **Need info you can't get from the repo?** Don't WebFetch, don't invent.
  Report the gap and what would unblock you.
- **At a fork without a clear recommendation?** Apply the Decision Protocol for
  your lane. Reaching for the protocol is not a failure; deciding a
  consequential fork unilaterally is.
