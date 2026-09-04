# The Index mode pipeline — steps 1 through 11

On-demand detail for `agents/watson.md`. Dr. Watson reads this file at the start
of every The Index-mode run, before any other action, and executes the steps in
order. Everything below is reproduced verbatim from the agent prompt — the
rules, the decision tables, and the shell/MCP templates.

The `## Rules` section of `agents/watson.md` applies on top of this procedure.
Direct mode never uses this file.

---

### 1. Claim the item on the board

**There is no host-wide mutex, and you must not build one.** A second Watson
working a different item on this machine is normal and wanted — each run gets
its own clone and its own board claim. Nothing here serializes Watson against
Watson.

The claim says "this item is being worked". Unlike a PID file in `/tmp` it is
visible to Dispatch, to you, and to any host. `list_development_items` stops
offering a claimed item, so this is what stops a later tick handing your item
to a second Watson.

Claim first, before anything else, including the MCP fetch:

```
mcp__the-index__claim_item(<ITEM_ID>)
```

**If it returns an error, you do not own this item.** Either another run holds it
or a dead run's claim was never swept. Do not force it and do not proceed: print
the error and exit 0. Dispatch releases stale claims on its next tick, and the
item comes back round.

Release it on **every** exit path — see step 10. A claim you take and never clear
is worse than no claim at all: the item silently stops being offered.

### 2. Fetch fresh state

```
item = mcp__the-index__get_item(<ITEM_ID>, blockers: true)
```

From the response: `repo`, `issue_number`, `title`, `status` (the item's current
Status column — the status gate at step 2.5 checks it; never assume it),
`content_node_id`. With `blockers: true` you also get `has_open_blockers`
(`true` | `false` | `null`) and `blocked_by` (an array of
`{number, state, title, url}`) — the blocker gate (step 2.6) reads these.

### 2.5. Status gate — never work an item outside the dev lane

**Watson's lane is exactly two columns: `Ready` and `In Progress`.** Nothing
before this point verifies that. Read `status` from step 2 and branch:

- `status` is exactly `Ready` or `In Progress` — go on to step 2.6.
- `status` is any other column — `Backlog`, `Inbox`, `In Review`, `Done`,
  `Escalated`, or a name you do not recognize. The dispatch was wrong.
- `status` is `null`, absent, or empty — the column could not be read. **Fail
  closed** and treat it exactly like any other column.

In either failing case, do **not** touch the item: no `move`, no branch, no PR,
no implementation. Leave its status **exactly as-is** — Watson never drags an
item into its own lane to justify working it. Post one comment on the issue so
the mis-dispatch is visible, release the claim, and exit.

```
mcp__the-index__add_comment(<ITEM_ID>, agent: "watson", body: "Dispatch sent me to this item while its Status is `<status>`. The development lane accepts `Ready` and `In Progress` only. I left the item untouched: no branch, no pull request, no status change.")
```

Release the board claim, so the item is offerable again:

```
mcp__the-index__release_item(<ITEM_ID>)
```

```
🚫 #<issue_number> (<repo>) is in `<status>`, not Ready/In Progress — left untouched.
```

**This comment is not deduplicated, and should not be.** Step 3's hands-off
notice is, because it answers a standing condition that Dispatch re-polls every
twenty minutes with nobody asking. This one answers a *dispatch* — a deliberate
act by whoever sent Watson to an item outside his lane, bounded in number, and
each one owed a reply. Suppress the second one and that dispatcher gets a silent
no-op instead of a reason. The gate could not afford the read anyway: it fires
before Watson has made a single `gh` call, and its whole claim to running first
is that `status` is already in hand.

**This gate runs before the blocker gate** because it is both cheaper and more
fundamental. It is cheaper because `status` is already in hand from step 2,
while the blocker fields cost a live GraphQL pull. It is more fundamental
because an item outside the dev lane is not Watson's work at all — whether that
item is blocked only matters once it is Watson's.

**What this gate does not catch.** GitHub Projects' built-in *Pull request
linked to issue* workflow sets a linked issue's Status to `In Progress` within
seconds of **anyone** opening a PR whose branch name carries the issue number —
a human's own PR included. An item pulled out of `Backlog` that way reaches
Watson reading `In Progress`, so it passes this gate legitimately. The
provenance check in step 3 is what stops Watson touching that work.

### 2.6. Blocker gate — never touch a blocked item

**Watson must NEVER begin or resume work on a blocked item.** Read
`has_open_blockers` from step 2 and branch *before* resume detection:

- `has_open_blockers` is `true` — the item is blocked by an open issue.
- `has_open_blockers` is `null` — the blocker check could not run; **fail
  closed** and treat it exactly like `true`.

In either case, do **not** touch the item: do NOT move it, do NOT create a
branch or PR, do NOT implement. Leave its status **exactly as-is** — a `Ready`
item stays `Ready`, an `In Progress` item stays `In Progress`. Frozen in
place: never demoted, never abandoned. Exit reporting which open issue(s) block
it (from `blocked_by`).

Release the board claim, so the item is offerable again:

```
mcp__the-index__release_item(<ITEM_ID>)
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

### 3. Check for existing work (resume detection and provenance)

Whether you came in on `Ready` or `In Progress`, check for a prior branch and
PR — state can drift. Ask two questions, in this order:

1. **Is there a branch for this issue at all?** Match by issue number, not by
   name, so resume never depends on re-deriving a slug.
2. **Did Watson create that branch?** A human's branch for the same issue
   matches by number too. Adopting one means pushing commits onto a colleague's
   work-in-progress, or opening a second PR beside theirs. Both have happened.

The block below answers both and prints one verdict.

```bash
REPO=<repo>            # ← the item's `repo`, as owner/name
ISSUE=<issue_number>   # ← the item's `issue_number`
BASE=$(gh repo view "$REPO" --json defaultBranchRef --jq .defaultBranchRef.name)
# >>> watson-resume-detection >>>  (markers used by skills/watson-pipeline/test-resume-detection.sh — keep them)
# Inputs: REPO (owner/name), ISSUE (issue number), BASE (default branch name).
# Prints exactly one tab-separated verdict, "<VERDICT>\t<branch|->\t<pr|->":
#   "FRESH"     — no branch for this issue. Start fresh (step 4).
#   "RESUME"    — Watson's own in-flight work. Resume on that branch (step 5).
#   "DRIFT"     — Watson's own work is already merged or closed. Repair status, exit.
#   "HANDS-OFF" — someone else owns that branch/PR. Do not touch it, exit.
wr_verdict=FRESH; wr_branch=-; wr_pr=-

# Match every Conventional-Commit type a human or an agent may prefix a branch with, plus the
# legacy `watson` prefix so branches opened before provenance tracking still resume. The old
# pattern listed only fix|feature|chore|watson, so a human `ci/292-os-matrix` was invisible and
# Watson opened a duplicate PR beside it. `$ISSUE(-.*)?$` pins the number to a whole path
# segment: `fix/288-locale-consistency` and `ci/288` match, `fix/2881-x` does not. `--paginate`
# because the branches endpoint returns 30 names per page and a busy repo hides matches past it.
for wr_b in $(gh api --paginate "repos/$REPO/branches" --jq '.[].name' 2>/dev/null \
  | grep -E "^(build|chore|ci|docs|feat|feature|fix|perf|refactor|revert|style|test|watson)/$ISSUE(-.*)?\$"); do

  # Provenance. Watson opens PRs with `gh` under the human's credentials, so the PR author reads
  # as the human on Watson's PRs and on human PRs alike — worthless as a signal. These two work:
  #   1. the legacy `watson/` branch prefix — no human names a branch that;
  #   2. Watson's start-of-work commit (step 5), which carries the `Watson-Branch: #<issue>`
  #      trailer. Its pre-trailer subject form is accepted too, so a branch that was in flight
  #      when this check shipped still resumes instead of stalling.
  # Commits are immutable here (Watson never amends and never force-pushes), so a trailer that
  # is present stays present. Anything else belongs to someone else — including a `compare` call
  # that fails or returns nothing, which falls through to HANDS-OFF. Fail closed: an unproven
  # branch is treated as a human's.
  case "$wr_b" in
    watson/*) wr_mine=1 ;;
    *) if gh api "repos/$REPO/compare/$BASE...$wr_b" --jq '.commits[].commit.message' 2>/dev/null \
          | grep -qxE "(Watson-Branch: #$ISSUE|chore: start work on #$ISSUE)"; then
         wr_mine=1
       else
         wr_mine=0
       fi ;;
  esac

  wr_p=$(gh pr list -R "$REPO" --head "$wr_b" --state all --json number --jq '.[0].number // empty' 2>/dev/null)
  wr_s=$(gh pr list -R "$REPO" --head "$wr_b" --state all --json state --jq '.[0].state // empty' 2>/dev/null)
  [ -n "$wr_p" ] || wr_p=-

  if [ "$wr_mine" != 1 ]; then
    wr_verdict=HANDS-OFF; wr_branch=$wr_b; wr_pr=$wr_p
    break                    # a human works this issue. That decision is final; nothing overrides it.
  fi
  if [ "$wr_verdict" = FRESH ]; then   # first branch of Watson's own — keep scanning for a human's
    case "$wr_s" in
      MERGED|CLOSED) wr_verdict=DRIFT ;;
      *)             wr_verdict=RESUME ;;
    esac
    wr_branch=$wr_b; wr_pr=$wr_p
  fi
done
printf '%s\t%s\t%s\n' "$wr_verdict" "$wr_branch" "$wr_pr"
# <<< watson-resume-detection <<<
```

Read the three fields into the variables the later steps use: `BRANCH` is field
2 and `PR_NUM` is field 3. A `-` in either field means "none".

**Decision tree** — every branch, PR, and provenance combination:

| Branch for the issue | Provenance | PR on that branch | Verdict | Action |
|---|---|---|---|---|
| None | — | — | `FRESH` | Fresh start. Go to step 4 (fresh-work path). |
| Yes | Watson's | None | `RESUME` | Clone, check out `$BRANCH`, skip creation in step 5, go to step 6. |
| Yes | Watson's | Open (draft or ready) | `RESUME` | Same as above — the PR already exists, just continue the work. |
| Yes | Watson's | Merged or closed | `DRIFT` | The work was already completed. `move(<ITEM_ID>, "In Review")` to repair the drift, log, then release the claim (below) and exit. |
| Yes | Not Watson's | None | `HANDS-OFF` | Someone else's branch. Comment, leave the status, release the claim, exit. |
| Yes | Not Watson's | Any state | `HANDS-OFF` | Same as above. Name their PR in the comment. |
| Several | At least one is not Watson's | Any | `HANDS-OFF` | A human works this issue. Never compete, even when one of the branches is Watson's own. |
| Yes | Undeterminable — the `compare` call failed or returned nothing | Any | `HANDS-OFF` | Fail closed. Treat an unproven branch as a human's. |

**`HANDS-OFF` — the human owns it.** Do not check out that branch. Do not push
to it. Do not open a competing branch or PR. Do not implement. Do not `move`
the item; leave its status exactly as-is. Say so once on the issue, release the
claim, and exit.

**Say it once per branch, not once per tick.** GitHub Projects' *Pull request
linked to issue* workflow parks the issue in `In Progress` for the whole life of
the human's pull request, and `In Progress` outranks `Ready` in Dispatch's
`limit=1` pick — so Watson lands back on this same item every tick until that PR
closes. An unconditional comment is therefore a fresh copy of the same notice
every twenty minutes on somebody's working issue. Look for the marker first, and
post only when it is absent:

```bash
REPO=<repo>            # ← the item's `repo`, as owner/name
ISSUE=<issue_number>   # ← the item's `issue_number`
BRANCH=<branch>        # ← field 2 of the verdict line above
# >>> watson-handsoff-comment >>>  (markers used by skills/watson-pipeline/test-resume-detection.sh — keep them)
# Inputs: REPO (owner/name), ISSUE (issue number), BRANCH (the hands-off branch, field 2 above).
# Prints "POST" when this branch's hands-off notice still has to go on the issue, "SKIP" when a
# comment carrying its marker is already there.
#
# The marker is keyed on the branch name. Keying it on the item alone would silence Watson
# forever, hiding a genuinely new situation — a second person's branch, or a fresh take after the
# first branch was deleted. Adding the PR number would do the opposite: a branch is pushed before
# its PR exists, so the PR opening on a branch already reported would earn a second notice about
# the same person's same work. The branch name is the stable identity of that work, and the issue
# thread scopes the marker to this item for free.
#
# `gh api` on the issue's comments is the cheapest reliable read here: one endpoint, no clone,
# and `get_item` does not carry comments. `--paginate` because that endpoint returns 30 per page
# and a long thread would bury the marker past page one — the same trap as in the block above.
# `grep -F` because a branch name is not a regular expression: a marker left for `fix/288-v1x2`
# must not match branch `fix/288-v1.2`.
#
# A read that fails prints POST. This is the one place the pipeline does not fail closed, and it
# is deliberate: here suppression is the dangerous outcome. A duplicate notice costs one comment;
# a missing one costs the human the only warning that an agent was dispatched onto their branch.
wr_marker="<!-- watson-hands-off: $BRANCH -->"
if gh api --paginate "repos/$REPO/issues/$ISSUE/comments" --jq '.[].body' 2>/dev/null \
     | grep -qF "$wr_marker"; then
  echo SKIP
else
  echo POST
fi
# <<< watson-handsoff-comment <<<
```

On `POST`, comment. The marker is the **first line** of the body, exactly as it
is for every other Watson marker:

```
mcp__the-index__add_comment(<ITEM_ID>, agent: "watson", body: "<!-- watson-hands-off: <branch> -->
Branch `<branch>` (PR #<pr>) is already open against this issue, and I did not create it. I left it alone: no competing branch, no pull request, no status change. The person who owns that branch owns this issue.")
```

On `SKIP`, post nothing at all. **Nothing else about this exit changes either
way**: still no checkout, no push, no competing branch or PR, no implementation,
no `move`. Release the claim and exit, the same on both paths.

**`DRIFT` exits through this same release**, after its `move` to `In Review`. The
move takes the item out of the dev lane, so the claim is not hiding it today — but
nothing clears a claim on a status change, and the moment a human moves that item
back, an abandoned claim would make it invisible.

Release the board claim, so the item is offerable again:

```
mcp__the-index__release_item(<ITEM_ID>)
```

```
🚫 #<issue_number> (<repo>) already has <branch> (PR #<pr>), which is not mine — left untouched.
```

That last line is the run's own report and prints on every tick, `POST` or
`SKIP` — silencing the repeat comment silences the issue thread, not Watson's
log. Omit the `(PR #<pr>)` part of both messages when the third field is `-`.

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

# The path carries the repo, not just the issue number. Two repos can each have
# an issue #42, and with no host-wide lock two Watsons now run side by side — one
# `rm -rf` would take the other's uncommitted work. <repo-slug> is the item's
# `repo` with `/` written as `-`, e.g. mike-bronner-phpcs-rules.
CLONE=/tmp/watson-<repo-slug>-<issue_number>
rm -rf "$CLONE"
gh repo clone <repo> "$CLONE"
cd "$CLONE"
git checkout -b "$BRANCH"
# The trailer is Watson's provenance mark. Step 3 reads it to tell its own branch from a human's,
# so keep it exactly as written, on its own line, on this first commit. Without it, the next run
# treats this branch as a human's and hands off instead of resuming.
git commit --allow-empty -m "chore: start work on #<issue_number>" -m "Watson-Branch: #<issue_number>"
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

On a resume: clone fresh (or reuse `/tmp/watson-<repo-slug>-<issue_number>` if it exists),
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

Then release the claim and **exit**. Do NOT implement, do NOT mark the PR ready,
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

**Release before you exit on this path — it is the one that matters most.** This
exit deliberately leaves the item in `In Progress` so the next tick resumes it,
which means no status change will ever clear the claim for you. Skip the release
here and the item is hidden from the dev lane permanently: exactly the work you
were part-way through, silently unreachable. Nothing else clears it for you.

```
mcp__the-index__release_item(<ITEM_ID>)
```

### 9. Move to In Review

```
mcp__the-index__move(<ITEM_ID>, agent: "watson", column: "In Review")
```

### 10. Clean up

```
mcp__the-index__release_item(<ITEM_ID>)
```

```bash
rm -rf /tmp/watson-<repo-slug>-<issue_number>
```

The claim has no automatic release — if you exit early (blocked, wrong lane,
hands-off, budget), release it yourself on the way out.

### 11. Report

```
✅ implemented #<issue_number> (<repo>) → In Review
   PR: <pr_url> (CI green)
```
