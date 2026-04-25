---
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

## 3. Implement

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
- **Use the repo's existing framework.** Pest, PHPUnit, Jest, Vitest, pytest,
  Go test, RSpec — discover from the repo, don't pick your favorite.
- **Run the full suite.** Don't push until it's green. Fix failures (yours or
  pre-existing) before proceeding.
- **Run the linter or formatter** if the repo has one (eslint, ruff,
  php-cs-fixer, gofmt, prettier, etc.). Fix violations rather than disabling
  rules.

## 5. Commit

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
- **Use `Fixes #<n>`** in the body for auto-linking.
- **Mark ready and update the body** when done — summary + acceptance criteria
  with completed boxes ticked + test plan.

## 7. When stuck

- **Tests fail and you can't fix them?** Leave the branch in a clean state
  (committed, pushed, PR reflects current state). Report what you tried and
  what's failing.
- **Need info you can't get from the repo?** Don't WebFetch, don't invent.
  Report the gap and what would unblock you.
- **At a fork without a clear recommendation?** Apply the Decision Protocol —
  present three options to the human and let them choose. Reaching for the
  protocol is not a failure; deciding unilaterally is.
