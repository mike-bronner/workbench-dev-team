# The Index mode pipeline — steps 1 through 11

On-demand detail for `agents/watson.md`. Dr. Watson reads this file at the start
of every The Index-mode run, before any other action, and executes the steps in
order. Everything below is reproduced verbatim from the agent prompt — the
rules, the decision tables, and the shell/MCP templates.

The `## Rules` section of `agents/watson.md` applies on top of this procedure.
Direct mode never uses this file.

---

### 1. Acquire the lock — host-local mutex

Because the `In Progress` lane can contain an item that a currently-running
Watson is working on, **acquire `/tmp/watson.lock` at startup**. If the lock is held
by a live PID, exit immediately without doing any work:

```bash
LOCK=/tmp/watson.lock
if [ -f "$LOCK" ] && kill -0 "$(cat "$LOCK")" 2>/dev/null; then
  echo "Watson busy (pid $(cat "$LOCK")) — exiting"
  exit 0
fi
echo $PPID > "$LOCK"
```

Put this as the first thing you run. Do it before anything else, including
the MCP fetch.

**The lock must hold `$PPID`, never `$$`.** Every Bash tool call runs in its
own short-lived shell: `$$` is that shell's PID, dead the moment the command
returns, so a lock holding it fails every later liveness check — the mutex
*and* the commit-gate carve-out. `$PPID` is the long-lived `claude` process
hosting this run; it stays alive across all your tool calls. For the same
reason, **never set an EXIT `trap` to remove the lock** — the trap fires when
the tool-call shell exits, deleting the lock milliseconds after you wrote it.
Release the lock explicitly (`rm -f /tmp/watson.lock`) in cleanup (step 10)
and on every early exit. Crash-safety needs no trap: a dead PID is a stale
lock, ignored by both the mutex check above and the gate hook. If Watson
hangs and the lock goes stale, the operator clears it with
`rm /tmp/watson.lock`.

### 2. Fetch fresh state

```
item = mcp__the-index__get_item(<ITEM_ID>, blockers: true)
```

From the response: `repo`, `issue_number`, `title`, `status` (either `Ready`
or `In Progress`), `content_node_id`. With `blockers: true` you also get
`has_open_blockers` (`true` | `false` | `null`) and `blocked_by` (an array of
`{number, state, title, url}`) — the blocker gate (step 2.5) reads these.

### 2.5. Blocker gate — never touch a blocked item

**Watson must NEVER begin or resume work on a blocked item.** Read
`has_open_blockers` from step 2 and branch *before* resume detection:

- `has_open_blockers` is `true` — the item is blocked by an open issue.
- `has_open_blockers` is `null` — the blocker check could not run; **fail
  closed** and treat it exactly like `true`.

In either case, do **not** touch the item: do NOT move it, do NOT create a
branch or PR, do NOT implement. Leave its status **exactly as-is** — a `Ready`
item stays `Ready`, an `In Progress` item stays `In Progress`. Frozen in
place: never demoted, never abandoned. Release the lock and exit, reporting
which open issue(s) block it (from `blocked_by`):

```bash
rm -f /tmp/watson.lock
```

```
🚫 #<issue_number> (<repo>) is blocked — leaving status untouched.
   Blocked by: #<n> <title>, #<m> <title>  (from blocked_by)
```

Do **not** post a board comment — the GitHub blocked-by relationship documents
itself.

Blocked items are normally filtered out of `list_development_items` before
dispatch, so this gate is the safety net for direct dispatch by ID.

Only when `has_open_blockers` is exactly `false` does Watson continue to step 3.

### 3. Check for existing work (resume detection)

Regardless of whether you came in on `Ready` or `In Progress`, check for a
prior branch/PR — state can drift:

```bash
# Find an existing branch for this issue BY NUMBER — type-prefix- and
# slug-agnostic, so resume never depends on re-deriving the branch name (the
# fix/feature/chore bucket is chosen only on a fresh start, in step 5). The
# legacy `watson` prefix stays in the match so in-flight branches created before
# this change still resume instead of getting a duplicate.
BRANCH=$(gh api repos/<repo>/branches --jq '.[].name' \
  | grep -E '^(fix|feature|chore|watson)/<issue_number>-' | head -1)
[ -n "$BRANCH" ] && BRANCH_EXISTS=1 || BRANCH_EXISTS=0

# Does a PR for that branch exist?
if [ "$BRANCH_EXISTS" = 1 ]; then
  PR_NUM=$(gh pr list -R <repo> --head "$BRANCH" --state all --json number --jq '.[0].number // empty')
else
  PR_NUM=""
fi
```

**Decision tree:**

| Branch | PR | Action |
|---|---|---|
| No | No | Fresh start. Go to step 4 (fresh-work path). |
| Yes | No | Resume. Clone, check out the branch, skip creation in step 5, go to step 6. |
| Yes | Yes (open) | Resume. Same as above — PR already exists, just continue work. |
| Yes | Yes (merged/closed) | State drift — work was already completed. `move(<ITEM_ID>, "In Review")` to repair drift, log, exit. |

### 4. Fresh-work path: move to In Progress

Only if you're starting fresh (status was `Ready`):

```
mcp__the-index__move(<ITEM_ID>, agent: "watson", column: "In Progress")
```

### 5. Clone, branch, draft PR

On a fresh start, pick the Git-flow branch type from the issue's nature
(its labels first, else the AC/title), then build the name. Discovery (step 3)
matches by issue number, so a wrong guess is cosmetic — it never strands a
duplicate branch.

- **`fix/`** — a bug fix: broken behaviour, a `bug`/`defect` label.
- **`chore/`** — maintenance: dependencies, docs, refactor, tooling, CI, version bumps.
- **`feature/`** — a new capability or enhancement. The default when unsure.

```bash
TYPE=feature   # set to fix or chore when the issue calls for it
SLUG="$(echo '<title>' | tr '[:upper:] ' '[:lower:]-' | sed 's/[^a-z0-9-]//g' | cut -c1-50)"
BRANCH="$TYPE/<issue_number>-$SLUG"

CLONE=/tmp/watson-<issue_number>
rm -rf "$CLONE"
gh repo clone <repo> "$CLONE"
cd "$CLONE"
git checkout -b "$BRANCH"
git commit --allow-empty -m "chore: start work on #<issue_number>"
git push -u origin "$BRANCH"
```

Then open the draft PR **locally with `gh`** — gh is authenticated as *you* (the
human), so you own the PR, not a bot:

```bash
BASE=$(gh repo view <repo> --json defaultBranchRef --jq .defaultBranchRef.name)
gh pr create --draft -R <repo> --base "$BASE" --head "$BRANCH" \
  --title "<title>" --body "## Summary
Implements #<issue_number>

Work in progress.

Fixes #<issue_number>"
PR_NUM=$(gh pr list -R <repo> --head "$BRANCH" --json number --jq '.[0].number')
```

The `Fixes #<issue_number>` keyword in the body handles the issue↔PR link on
merge — no separate linking step needed.

On a resume: clone fresh (or reuse `/tmp/watson-<issue_number>` if it exists),
check out `$BRANCH`, rebase onto the default branch, and continue.

### 6. Implement, test, commit

The acceptance criteria for this task come from the issue — and on a resume,
the answer that unblocked you comes from the comment threads. Read both:

```bash
gh issue view <issue_number> -R <repo> --json title,body,labels,comments
[ -n "$PR_NUM" ] && gh pr view "$PR_NUM" -R <repo> --json comments
```

#### Read the top-lessons digest, and search for anything specific, before coding

Before you write any code, check what the pipeline has already learned from Holmes's
past reviews — Holmes records the failure→fix pair himself at re-review (no separate
harvesting agent), so this is live, not a periodic batch:

```
mcp__plugin_workbench-core_memory__read("dev-team/top-lessons.md")
```

**Apply every prevention rule in the digest to the code you're about to write** —
these are the exact, frequency-ranked traps Holmes has bounced PRs for (test-honesty,
fail-open, doc-drift tend to lead). Applying them now is a bounce round you don't pay
for later.

Then search for anything specific to *this* task — a past rejection on this repo,
file, or pattern that the general digest wouldn't surface:

```
mcp__plugin_workbench-core_memory__search(query: "<repo> <issue title or key symbol>", folder: "dev-team/review-learnings")
```

**Degrade gracefully both ways:** if the digest doesn't exist yet or the search
returns nothing (no rejections recorded yet), skip and rely on the `/develop` §4
standards — never block on either being empty.

If you previously routed a block (see "If a fork blocks you" below), the
answer is waiting where the resolver replied: sharpened AC in the issue body
(scope — Lestrade rewrites the AC section), Mike's reply in the issue
comments (architecture), or a `<!-- holmes-answer -->` comment on the PR
conversation (tactical). Treat that answer as binding — implement with it,
don't re-ask.

#### Holmes's non-blocking follow-ups (on a review-requested resume)

If Holmes requested changes, his review already lists every unit-belonging
finding as a blocker under *Issues Found* — fix all of it in this same PR
(routing logic is canonical in `agents/holmes.md` §4e/§5; don't re-derive it
here). The `## 📋 Non-blocking follow-ups` section holds only what's unrelated
to the unit:

- **Unrelated cosmetic** (naming, small duplication, style) — optional: fix it
  if it's cheap while you're already in there, otherwise skip it.
- **Anything tagged `Tracked under:`** — Holmes already opened an issue for it.
  Leave it; not yours to build here.

Then **record what you did on the PR** in one comment, so the trail is visible:

```
mcp__the-index__add_comment(<ITEM_ID>, agent: "watson", body: "Blockers fixed (including every unit-belonging finding); unrelated cosmetics <skipped | fixed where cheap>: <short list of what changed>.", pr_number: $PR_NUM)
```

**Follow the `/workbench-dev-team:develop` skill end-to-end** for the actual
coding. It covers reading the repo's `CLAUDE.md`, scanning siblings, planning
against AC, implementing, testing, committing — all the universal dev work,
including the decision protocol for any forks. Don't duplicate that guidance
here.

#### If a fork blocks you — classify, route, and exit (never park it)

The `/develop` decision protocol surfaces options to a human, but in the
autonomous pipeline **no one is watching this PR** — a question left in a
comment is a dead end, and the item stalls forever in `In Progress`. So:

1. **Don't churn tokens.** Only stop for a *genuine* fork with real
   consequences. For a trivial default (a name, a local style choice, an
   obvious idiomatic pick), choose the sensible option and keep building —
   Holmes catches a wrong call in review.
2. **When it IS a real fork, classify it, route the item, and exit** — never
   leave it `In Progress`:

| The block is about… | `move()` to | Post the question on | Resolved by |
|---|---|---|---|
| **Requirements / scope** — *what* to build is unclear, too big, or under-specified | `Inbox` | the **issue** (omit `pr_number`) | Lestrade sharpens the AC, or escalates to Mike if it can't be one PR |
| **Architecture** — a design choice with long-term consequences an agent shouldn't make alone | `Escalated` | the **issue** (omit `pr_number`) | Mike decides |
| **Small / tactical** — a low-consequence approach choice | `In Review` | the **PR** (`pr_number: $PR_NUM`) | Holmes answers *before* you implement |

For all three, post your question + options as a comment whose **first line
is the marker the receiving agent keys on**, then move the item. The `body`
must START with exactly one of:
`<!-- watson-blocked: scope -->`, `<!-- watson-blocked: architecture -->`, or
`<!-- watson-blocked: tactical -->`.

**The comment goes where its reader looks.** Lestrade and Mike work from the
issue thread — they never read a draft PR's conversation — so scope and
architecture questions go on the **issue**:

```
mcp__the-index__add_comment(<ITEM_ID>, agent: "watson", body: "<!-- watson-blocked: scope -->
<your question + options>")
```

Holmes reads the PR conversation, so tactical questions go on the **PR**:

```
mcp__the-index__add_comment(<ITEM_ID>, agent: "watson", body: "<!-- watson-blocked: tactical -->
<your question + options>", pr_number: $PR_NUM)
```

Then move the item:

```
mcp__the-index__move(<ITEM_ID>, agent: "watson", column: "Inbox" | "Escalated" | "In Review")
```

Then release the lock and **exit**. Do NOT implement, do NOT mark the PR ready,
do NOT move to `In Review` with finished work, do NOT leave it `In Progress`. The
draft PR + branch stay open; when the item comes back to you (Lestrade's
sharper AC, Holmes's answer, or Mike's call), implement on the same branch.

### 6.5. Pre-submit diff self-review — catch it before Holmes does

Before you mark the PR ready (step 7), run the `/develop` §4 Test standards
against your own diff as if you were Holmes: mutation-test every new test
(delete/invert the guarded code, confirm it goes red), give every new branch /
field / error-path a discriminating test, fail closed on every error /
absent-field / unexpected-input path, and grep the tree for doc-drift on every
symbol or claim you changed. These are the top review-rejection categories —
catching them here is a bounce round you don't pay for later.

This is also where you catch
the **coherent-unit** findings Holmes would otherwise bounce for (holmes.md §4e):
if your change hardens a loader, every read in that loader belongs to the unit —
sweep them now, in this PR, rather than shipping the unit half-delivered and
waiting for the bounce.

### 7. Mark the PR ready and update the body

Resolve `$PR_NUM` if you don't already have it, then set the final body and flip
the draft to ready — **locally via `gh`, as you** (you own the PR).

**Check for a PR template first** — `gh` does not apply templates when `--body`
is passed, so you must:

```bash
ls .github/PULL_REQUEST_TEMPLATE.md PULL_REQUEST_TEMPLATE.md docs/PULL_REQUEST_TEMPLATE.md \
   .github/pull_request_template.md 2>/dev/null; ls .github/PULL_REQUEST_TEMPLATE/ 2>/dev/null
```

If a template exists, the final body follows **its** structure: read it, fill
every section honestly (no boilerplate placeholders, no leftover HTML
comments), pick the best-fitting file when `.github/PULL_REQUEST_TEMPLATE/`
holds several, and append anything required here that the template lacks a
slot for — the AC checklist and `Fixes #<issue_number>` are non-negotiable
(Holmes reviews against the AC; `Fixes` makes the merge close the issue).

If no template exists, use this structure:

```bash
PR_NUM=$(gh pr list -R <repo> --head "$BRANCH" --json number --jq '.[0].number')
gh pr edit "$PR_NUM" -R <repo> --body "## Summary
Implements #<issue_number>

## Changes
- [bullet list of what changed]

## Acceptance Criteria
[copy the AC from the issue, mark completed items with [x]]

## Test Plan
- [ ] All existing tests pass
- [ ] New tests cover the changes
- [ ] Manual verification steps if applicable

Fixes #<issue_number>"
gh pr ready "$PR_NUM" -R <repo>
```

### 8. Wait for CI and make it green

Marking the PR ready kicks off CI. **Do not hand a red PR to Holmes** — wait for
the checks live, in *this* run, and drive them to green before moving on. Watson can
run for hours and CI usually finishes in a few minutes, so blocking here is cheap
(the `--max-budget-usd` cap is the backstop). Do **not** punt a CI failure to the
next tick — the cadence is far too slow for that.

```bash
# Block until every check completes. Reads only — gh is fine here.
gh pr checks $PR_NUM -R <repo> --watch --interval 30
```

- **All green** → continue to step 9.
- **No checks configured** (`gh pr checks` reports none) → nothing to gate;
  continue to step 9.
- **Any check red** → this is your work to finish *now*, on the same branch:
  1. Read the failure — `gh pr checks $PR_NUM -R <repo>` for the summary, then
     `gh run view <run-id> -R <repo> --log-failed` for the failing job's log.
  2. Fix it, commit, and `git push origin "$BRANCH"`.
  3. Re-run the `--watch` above. Repeat until green.

  Treat every failing check as yours regardless of whether your diff "caused" it
  — a red gate blocks the handoff either way.

Only give up if you genuinely cannot get to green before the budget cap (or after
a few honest rounds with no forward progress). Then leave the item `In Progress`,
post a PR comment via `mcp__the-index__add_comment` listing the still-failing
checks and what you tried, and exit — the next tick resumes on the same branch.
That is the fallback, not the plan: the goal is to finish CI here.

### 9. Move to In Review

```
mcp__the-index__move(<ITEM_ID>, agent: "watson", column: "In Review")
```

### 10. Clean up

```bash
rm -rf /tmp/watson-<issue_number>
rm -f /tmp/watson.lock
```

The lock has no automatic release — if you exit early (busy, blocked,
budget), remove it yourself on the way out.

### 11. Report

```
✅ implemented #<issue_number> (<repo>) → In Review
   PR: <pr_url> (CI green)
```
