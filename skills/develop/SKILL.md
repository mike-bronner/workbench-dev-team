---
name: develop
description: Apply universal development standards when implementing code changes, fixing bugs, refactoring, writing tests, or any task that writes or modifies source code. Use this skill BEFORE writing or changing code — every time, manual or agent-driven — to ensure consistent conventions, testing, commit hygiene, and a human-in-the-loop decision protocol across all development work. Triggers on requests to "implement", "build", "fix", "add", "refactor", "write a test", "code up", or any prompt that produces code changes.
---

# Development Workflow

Universal standards for any code implementation work. The goal isn't compliance —
it's predictably high-quality changes that future-you (or anyone else) can read,
trust, and extend.

## Your lane decides what finishing looks like

Three lanes run this skill, and several steps below end differently in each.
Know which one you are in before you start.

- **Foreground session** — a human is in the conversation. You can ask and wait,
  and you commit and push through the approval gate (§5).
- **Sub-agent** — dispatched through the Agent tool, Watson's Direct mode
  included. No human is reachable, and the commit gate refuses every commit,
  merge, and push. You finish with an **uncommitted working tree and a report**:
  the diff summary and a proposed commit message. There is no PR to open.
- **Scheduled Index pipeline** — `bin/dispatch-agent.sh` spawned you with
  `WORKBENCH_DEV_TEAM_PIPELINE=1`. You commit, push, and open the PR unattended;
  board dispatch is the approval, and Holmes's review plus the human's merge is
  the gate.

## Decision Protocol — present options, don't decide alone

When you hit a fork the human has not already decided — choosing between
approaches, libraries, structures, scopes, or fixes — **stop and surface three
options** with reasoning for each, and a recommendation for the best one. The
human decides; you execute. A fork they already decided is not asked again.

**What counts as a fork:**

- Choosing between distinct implementation approaches (algorithm, data structure,
  architecture pattern)
- Picking a library or dependency when multiple reasonable options exist
- Deciding scope (fix the symptom vs. fix the root cause; refactor first vs.
  patch then clean up later)
- A public interface other code or people will depend on (an API shape, a data
  contract, a config key) that repo conventions do not already imply
- Trade-offs with meaningful long-term consequences

**What doesn't count — just do it:**

- A choice the human already made, in the brief, the issue, the acceptance
  criteria, or an earlier answer. Follow it, and do not present it as options
- Mechanical translation of clear requirements into code
- Following an existing repo convention (the repo already made that decision)
- Naming, and other small choices implied by sibling code or cheap to change later
- Obvious one-line fixes with no real alternative

**Format when presenting options.** Each option is its own heading, with its
pros and cons under it. The recommendation is a separate paragraph after all
three, never folded into the option it picks, and it names its reason. Pick the
architecturally correct option over the fastest one.

```
### 🔹 Option A: <short descriptive title>
- Pros: ...
- Cons: ...

### 🔹 Option B: <short descriptive title>
- Pros: ...
- Cons: ...

### 🔹 Option C: <short descriptive title>
- Pros: ...
- Cons: ...

I recommend Option B, because <reason this is the best fit>.
```

**What happens next depends on your lane.**

- **Foreground session:** wait for the human's pick before proceeding. Don't
  half-commit by starting on the recommended option while waiting — that's the
  same as deciding unilaterally, just with extra steps.
- **Sub-agent:** nobody can answer you mid-task, so the bar is **blocking
  uncertainty**. Below it — a fork where any of the options would satisfy the
  brief and the choice is cheap to reverse — pick the recommended option, go on,
  and record the choice and its reason as an assumption in your report. Above
  it — a fork where the wrong pick means work the sender would throw away —
  stop, change nothing more, and return the three options as your report.
- **Scheduled pipeline:** route the fork as Watson's pipeline describes (step 6,
  "If a fork blocks you").

If you genuinely can't think of three viable options, surface that — "I can only
see two reasonable approaches here, A and B. Want me to pick a stretch
third option, or is this a two-way choice?" Honest is better than padded.

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
- **Read the review-learnings digest first, if one exists.** Holmes records what
  he rejects and what fixed it, and a lightweight note on a clean first-pass
  approve, directly to the memory vault at review time. If
  `dev-team/top-lessons.md` exists (a frequency-ranked digest of recurring
  rejection categories, each with the concrete prevention rule, plus a running
  clean-approval tally above the list), read it via the memory MCP and apply
  every rule to what you're about to write.
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
  Rewrite it until it discriminates. This is the single cheapest defense against
  the most common review rejection: tests that don't actually test.
  **Never restore a mutation with `git checkout`, `git restore`, or
  `git stash`:** each one reverts the whole file or tree to the last commit, and
  in an uncommitted change that erases your own work along with the mutation.
  Before you hand the work back, read your final diff and confirm no mutation is
  left in it.
- **Fail closed by default.** For every error, absent-field, or unexpected-input
  path, state the behavior explicitly and default to **fail-closed** — reject,
  throw, or refuse — never fail-open (silently proceed, swallow the error, or
  return a default that masks the problem). Then test the closed path, not just
  the open one.
- **Use the repo's existing framework.** Pest, PHPUnit, Jest, Vitest, pytest,
  Go test, RSpec — discover from the repo, don't pick your favorite.
- **Run the full suite, and get it green for your change.** Fix every failure
  your change caused. A failure your change did not cause is out of scope
  (§2): confirm it fails the same way without your change, then report it
  rather than fold a fix in.
- **Grep the tree for every symbol or documented claim your diff changed**
  (doc-drift). Renamed a symbol, changed a documented behavior, altered a
  contract or type signature? `grep`/`rg` for every reference — code, comments,
  README, docs — and update each in the same change. A stale reference the tests
  won't catch is a silent regression for the next reader.
- **Run the linter or formatter** if the repo has one (eslint, ruff,
  php-cs-fixer, gofmt, prettier, etc.). Fix violations rather than disabling
  rules.
- **Self-review the diff before you hand it on.** Read the whole diff you are
  about to commit or report, as a reviewer would: debug output, commented-out
  code, forgotten TODOs, leftover scaffolding, a mutation you did not revert, and
  anything that smells like a credential.

## 5. Commit

**Which lane you are in decides what you may do at all.** A plugin
`PreToolUse` hook (`hooks/scripts/commit-approval-gate.sh`) sorts every Bash
call by lane, and its verdict is `deny`, in every permission mode.

**Sub-agent → you do not commit, merge, or push.** The hook refuses every git
verb that writes a commit, integrates another history, or publishes one, plus
every `gh` call that is not a read. No approval command is offered to you, and that is deliberate:
anything you can run yourself is not an approval. The denial writes no pending
record and ignores any record you might write by hand, so there is no route to
find. Do not go looking for one. **Hand the work back instead**, in your final
report:

1. Leave the working tree **uncommitted**, exactly as your change left it.
2. Summarize the diff — files touched and what changed in each.
3. Give the **proposed commit message**, formatted via the
   `/workbench-dev-team:git-commit` skill.
4. Say plainly that the work is uncommitted. A report that reads as finished,
   on a tree that is not, is how a change gets lost.

The session that dispatched you commits it, where a prompt reaches a human. An
Index-mode run that finds its commits refused was dispatched without the
pipeline flag: report that to the session that dispatched you, and stop.

**Foreground session → attempt the commit or the push yourself, and let the gate
prompt.** The human approves each `git commit` and each `git push` by answering a
real prompt. The plain form the gate prompts for, and the approval steps, are
canonical in the `/workbench-dev-team:git-commit` skill ("Committing and
pushing"). Read it before your first commit.

**Scheduled pipeline → commit and push unattended.** The hook recognizes the
pipeline by `WORKBENCH_DEV_TEAM_PIPELINE=1`, which `bin/dispatch-agent.sh`
exports onto the process it spawns. Never set that variable yourself, never
write an approval record by hand, and never edit the gate.

### Message format and hygiene

Use the `/workbench-dev-team:git-commit` skill for message format —
Conventional Commits + Gitmoji. Beyond format:

- **Don't commit secrets.** Scan your diff for credentials, tokens, API keys,
  PII. Verify `.env`-shaped files are in `.gitignore`. If anything smells like
  a credential, stop and remove it before staging.
- **Confirm you're on a feature branch** (not `main`/`master`/`trunk`) before
  pushing.
- **Atomic commits.** One logical change each. Don't bundle.
- **Never force-push** to a shared branch.
- **Never amend** an already-pushed commit. If you need to change something,
  add a new commit.

## 6. Open a PR (foreground and pipeline lanes)

A sub-agent opens no PR: it has nothing committed to open one from. Its report
is the handoff, and the session that commits the tree decides about the PR.

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

- **Tests fail and you can't fix them?** In the pipeline, leave the branch clean
  (committed, pushed, PR reflects current state). As a sub-agent, leave the tree
  uncommitted. Either way, report what you tried and what's failing.
- **Need info you can't get from the repo?** Don't WebFetch, don't invent.
  Report the gap and what would unblock you.
- **At a fork without a clear recommendation?** Apply the Decision Protocol for
  your lane. Reaching for the protocol is not a failure; deciding a
  consequential fork unilaterally is.
