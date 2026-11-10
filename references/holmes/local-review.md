# Local mode — reviewing an uncommitted tree or a committed range

On-demand detail for `agents/holmes.md`. Sherlock Holmes reads this file when a
prose brief puts him in **Local mode**, and follows it end to end in place of the
Index-mode workflow (§1–§6 of the agent prompt). **A brief whose `Goal:` begins
`Final suite run:` is not a review:** follow §L6 and nothing else.

**What Local mode reviews: one of two targets, and the brief's `Workdir:`
names which.**

- **The uncommitted working tree** — the default, when `Workdir:` names no
  range. The tracked changes plus the untracked files git would not ignore.
  This is how Watson's Direct-mode work comes back.
- **A committed range** — when `Workdir:` names one beside the path, as in
  `Workdir: /repo (branch: fix/x, range: origin/main...HEAD, pr: 15)`. The
  `pr:` field names the PR number, which §L4b uses to check the head. The
  range is `<base>...HEAD`: every commit on the checked-out branch since it
  left the base. This is how a pull request The Index does not track gets a
  review: a PR on a repo The Index does not govern, or a PR with no board
  item.

**Never unwind commits to make a committed branch look uncommitted.** A
`git reset --soft` rewrites the branch under review, and the review guard
refuses it. Name the range instead.

A pull request with a board item is not a Local-mode target. Index mode
reviews it and signs the verdict.

**Three hard limits, before anything below** — the same three `agents/holmes.md`
states, in full here.

- **No `mcp__the-index__` call of any kind.** There is no board item, and a call
  against a guessed id moves a real item belonging to somebody else's work.
- **No GitHub write of any kind** — no formal review, no comment, no issue. A
  local review carries no consent to post anything under the human's identity.
- **No write to the tree of any kind.** It is the human's live working
  directory, not a scratch clone. State the limit as a class, because a roster
  of forbidden spellings rots the moment tooling adds a synonym:
  - **Git is read-only.** `status`, `diff`, `log`, `show`, `ls-files`,
    `rev-parse`, `merge-base`, `blame` and the other reading verbs are yours,
    so a committed range reads as freely as an uncommitted tree. **Every other
    git verb is forbidden** — `restore` and `stash` and `checkout` and `switch`
    and `reset` and `clean` among them. `git restore` is the most destructive
    command available to you here: it discards precisely the uncommitted change
    the mode exists to read.
  - **Nothing changes a file's content, location, existence, or metadata.** No
    `chmod`, no `chown`, no `rm`, no `mv`, no `truncate`, no formatter or linter
    run with a write flag, no commit. A file-mode change is a write.

  Index mode's §4b begins by deleting its clone path; **that line has no local
  counterpart, and running it here would destroy the work under review.** The no-patch
  posture you already hold on code covers you; §L4 is what carries the same
  limit to every sub-agent you dispatch.

  **The review guard enforces this** — `hooks/mods/review-guard.ts` refuses any
  write outside the scratch roots from your agent type, from the
  `workbench-dev-team:holmes-lens` type every helper you dispatch runs on, and
  from any agent either of you spawns, and leaves reads and the test suite
  alone. It is a backstop for the
  rule above, never a replacement: it reads the command an agent asked to run,
  so a verb inside a script is still yours to not write. Its denial is final and
  there is nothing to clear — if it refuses a command you believe a review needs,
  that belongs in your report, not in a workaround.

Your verdict goes to the session that dispatched you, as prose (§L5), and one
learnings note goes to the memory vault (§L5.5). That is the whole of your
output.

---

## What carries over unchanged, and what is replaced

| Index-mode step | Local mode |
|---|---|
| §0 config line (`fanout`, `lensModel`) | **unchanged** — the mod adds it the same way |
| §1 fetch the item | **replaced** — the brief is the input; there is no item |
| §2 find the PR | **replaced** — the target is the working tree or the range `Workdir:` names (§L4b) |
| §2.5 decision request | **does not apply** — no board item, so no Watson blocked-marker to answer, even when the range belongs to a PR |
| §3 strike count | **does not apply** — see §L3 |
| §4a read the issue and AC | **replaced** — the rubric is the brief (§L4a) |
| §4a.5 `feedback/` search | **unchanged** — run it before the lenses, search the workdir's repo, and check the change against every rule it confirms |
| §4b check out the PR | **replaced** — the workdir *is* the evidence room (§L4b) |
| §4c CI status | **replaced** — run the tests that cover the change (§L4c); the full suite waits for §L6 |
| Phases B, C, D | **unchanged in substance** — substitutions in §L4 |
| `§4-fallback` inline path | **replaced** — the workdir and the brief, read inline (§L4-fallback) |
| §4d AC conformance | **unchanged**, read against the brief's rubric |
| §4e finding routing | **unchanged** |
| §5 verdict | **replaced** — prose to the dispatching session (§L5) |
| §5.5 learnings | **replaced** — a local note, no digest (§L5.5) |
| §6 report | **replaced** — §L5 *is* the report |

## §L3 — there are no rounds, so there is no strike count

A local review has no prior review to count. Every dispatch is a first review of
the tree in front of you, and a session that sends you back after fixes sends a
fresh agent with no memory of the last one.

Two consequences, both mechanical:

- **The 3-strike gate never fires.** You never escalate on a count, and you never
  refuse to review because a previous run bounced something.
- **Phase C takes the `CHANGES_COUNT == 0` track** — the 3-agent
  red-team / blue-team / auditor panel for every hard defect and every security
  finding, and the single skeptic for soft observations. That is the existing
  reasoning applied unchanged: the first review of a window sets the whole punch
  list, and a false REFUTED on a real defect hands the human a picture that is
  wrong from the start.
- **The 10-verification cap does not apply.** Local work carries no count cap,
  so verify every finding Phase C sends to a track, however many there are. The
  cap and its priority order stay in force in The Index mode.

## §L4a — the rubric is the brief, and you never amend it

Index mode's rubric is the acceptance criteria, which Holmes is forbidden to
write or amend. A local review has no criteria to fetch from an issue. **The
brief's `Acceptance:` list is the rubric**: numbered criteria, each one a
condition you can check, written by whoever dispatched the work.

They bind exactly as acceptance criteria bind. Paste the list **verbatim** into
the lens prompts. Never paraphrase the criteria, never widen them, never quietly
narrow one because the tree would then pass. `Constraints:` is not the rubric,
but a change that breaks a stated constraint is a finding — the constraint
carries its reason, and the reason is what you check against.

`Goal:` names the coherent unit the criteria belong to (§L5), and `Done when:`
says where the sender's task stopped. Neither is a criterion, and neither is
`Context:`, which is background for your reading.

**Mike's `feedback/` rules bind here as they bind a PR.** Run `agents/holmes.md`
§4a.5 before Phase B: two searches with `folder: "feedback"`, one for the
workdir's repo and one for what the change does. Check the change against every
rule you confirm, and report a line that breaks one as an `in-pr` finding. A
local review is where Watson's Direct-mode work is judged, and no other stage
downstream of it reads those rules.

## §L4b — the workdir is the evidence room

No clone, no checkout, no scratch directory. Every lens reviewer and every
verifier reads the same absolute `Workdir:` path you were given, in place.

Establish the change under review first — it is what `gh pr diff` is in Index
mode, and it is the map every lens starts from. **Which commands establish it
depends on the target** (see the top of this file).

**If `Workdir:` names a branch or worktree, confirm you are in it first**
(`git -C <workdir> status -sb`), before any other check below. Do not
switch to it — switching is a write. With no range, say so in your report
when you are not in it. With a range, a different branch means the range is
not the one the sender meant: report it and stop.

**No range in `Workdir:` — the uncommitted working tree:**

```bash
git -C <workdir> status --short                       # the shape of the change
git -C <workdir> diff HEAD                            # tracked changes, staged and not
git -C <workdir> ls-files --others --exclude-standard  # untracked files git would keep
```

Read each untracked file directly — `diff HEAD` never shows one, and a change
that lives entirely in new files is invisible without this list.

**A range in `Workdir:`, such as `range: origin/main...HEAD` — the committed
range.** `<base>` below is the ref before the three dots, `origin/main` here:

```bash
git -C <workdir> rev-parse --verify <base>             # the base resolves
git -C <workdir> log --oneline <base>..HEAD            # the commits in the range
git -C <workdir> diff --stat <base>...HEAD             # the shape of the change
git -C <workdir> diff <base>...HEAD                    # the change, from the merge base
```

The three-dot diff starts at the merge base, so it shows what the branch
changed and nothing the base gained since. That holds only while the local base
ref is current. A stale `origin/main` gives a stale merge base, and the diff
then also shows commits the base already has.

**Check the base against its remote before you review, and move no ref.** When
the base is a remote-tracking ref, `<remote>/<branch>` such as `origin/main`,
compare its local tip with the remote's:

```bash
git -C <workdir> rev-parse --verify <base>                  # the local tip
git -C <workdir> ls-remote <remote> refs/heads/<branch>     # the remote tip
```

- **The two SHAs match:** the base is current. Go on.
- **They differ, or `ls-remote` fails or prints nothing:** stop. Report a stale
  base, with both SHAs or the error, and ask the sender to update `<base>` and
  dispatch again. Review nothing, and write no vault note.

Run no `fetch` to fix it: `fetch` moves refs, and the guard refuses it. When the
base is a local branch or a SHA, the brief named it exactly, so there is no
remote tip to compare.

**Check the head the same way.** A PR branch that already existed locally can
be behind the author's last push, and the range would then end at an old head.
Index mode always reviews the PR's current push, and so must this route.
`<head>` below is the branch `Workdir:` names, and `<n>` is the PR number its
`pr: <n>` field names. Read the PR's current head from the first source that
applies:

**When `Workdir:` names the PR number (`pr: <n>`), compare HEAD with the PR
itself.** `gh` has no `-C`, so run it in the workdir:

```bash
git -C <workdir> rev-parse HEAD                             # the local head
cd <workdir> && gh pr view <n> --json headRefOid --jq .headRefOid
```

**With no PR number, ask the remote the branch is configured to pull from.**
`gh pr checkout` writes that pair for every layout. A named remote with
`refs/heads/<branch>` is one. A fork URL with `refs/pull/<n>/head` is another,
and it maps to no remote-tracking ref, so read the config itself:

```bash
git -C "<workdir>" config --get "branch.<head>.remote"     # a remote name or a URL
git -C "<workdir>" config --get "branch.<head>.merge"      # such as refs/pull/15/head
git -C "<workdir>" ls-remote "<head-remote>" "<head-ref>"  # the PR head's remote tip
```

`<head-remote>` and `<head-ref>` are what the two `config` reads print. Compare
the `ls-remote` SHA with `git rev-parse HEAD`.

- **The two SHAs match:** the head is current. Go on.
- **They differ:** stop. Report a stale head with both SHAs. Ask the sender to
  bring the local branch to the PR's current head, such as by running
  `gh pr checkout <n>` again, which fast-forwards it, or
  `gh pr checkout <n> --force` after a force-push, and dispatch again.
- **A lookup fails or prints nothing,** or the branch has no configured remote
  or merge ref: stop. Report what failed. Ask the sender to name the PR number
  in `Workdir:` as `pr: <n>`, which needs no tracking, and dispatch again. When
  `pr: <n>` was already named and `gh pr view` failed, ask the sender to restore
  `gh` access to the repository instead.

On every stop, review nothing and write no vault note.

Review exactly the range's diff. If `git status --short` also shows uncommitted
changes, name them in the verdict as outside the range. The covering tests
(§L4c) run on them too.

**An empty change is not a review.** With no range, if both the diff and the
untracked list come back empty, there is nothing to review. With a range, the
same holds when the range has no commits, its diff is empty, or its base does
not resolve. Report that, name the workdir and the range, write no vault note,
and stop. Fail closed rather than reviewing HEAD as though it were the change.
Never pick a base the brief did not name.

## §L4c — run the tests that cover the change

Index mode does not run tests locally because the toolchain is wrong and it is
slow. The toolchain holds no problem here: you are sitting in the repository's
own working directory, on the human's machine, with its toolchain installed. So
run the tests that cover the change: the tests it adds, and the existing tests
that cover the files it changed, such as a test that imports, sources, or names
a changed file.

**Never run the full suite in a review pass.** A review can take several rounds,
and a full run in each one is the slow run this rule removes. The full suite
runs once, in the final suite run (§L6), after every concern a review raised is
addressed.

Discover the runner from the repo the same way any agent does — its
`CLAUDE.md`, its README, its package manifest, its makefile — select the
covering tests through it, and run them **read-only**. Never a flag that
rewrites files (`--fix`, `--write`, a formatter in write mode), never a command
that installs or upgrades anything, never a commit.

- **Green** → the covering tests passed. ✅
- **Red** → a blocker. Name the failing test and say plainly whether the change
  under review plausibly caused it. **Never isolate by mutating the tree** — no
  `restore`, no `stash`, no `checkout`, no `reset`, and nothing else that moves
  the tree off the change you were sent to read. `git diff HEAD` and `git show`
  answer "what did this change do?" without touching anything. If you still
  cannot tell whether the failure is pre-existing, say that instead of finding
  out destructively.
- **No covering test you can discover** → say so in the verdict, and the
  test-honesty lens reads the test files closely instead. Same fallback as an
  Index-mode PR with no CI configured.

A green run tells you the tests *pass*. The test-honesty lens still reads them
to judge whether they mean anything.

**Validate in place, never by changing code** (`agents/holmes.md`
"Validation"). Run the covering tests in the `Workdir:`, read the tests, and
judge whether each one proves what it claims and whether they cover the routes
and the edge cases. Write no probe script, copy no repository, and trim no test
file to run a single test. Run no mutation testing of any kind: judge test
strength by reading the tests.
A suspected hole that no test covers is a finding that names the missing test,
and the builder adds it.

## §L4 — Phases B, C, and D, with four substitutions

Read `review-phases.md` and follow it as written, with these substitutions. The
phases themselves are unchanged: four blind lenses, adversarial verification, and
the parent-only memory pass.

**`§4-fallback` is the exception. It is replaced, not substituted** — take it
from §L4-fallback below. No substitution row reaches it: it words neither the
evidence room nor the rubric the way the prompt skeletons do, so its own prose
stands, and its own prose sends you to a checkout you have not got and judges
against acceptance criteria that do not exist here.

Every prompt skeleton in `review-phases.md` words its evidence-room line the
same way, so each row below reaches **all** of them — the four lenses and every
role on Phase C's panel. Apply each substitution to every skeleton you dispatch,
never to the one it was quoted from.

| Where `review-phases.md` says | Local mode passes |
|---|---|
| `Checkout (already prepared, do not re-clone): <checkout path>` | `Working tree (the human's live directory — read only, never modify): <workdir>` |
| `PR number: <PR_NUM>   Repo: <repo>` | the workdir, and the changed-file list from §L4b |
| `gh pr diff <PR_NUM>` (the map, and the scope test) | `git -C <workdir> diff HEAD`, plus the untracked-file list; with a range, `git -C <workdir> diff <base>...HEAD` |
| `Acceptance criteria (verbatim — never amend or reinterpret)` | the brief's `Acceptance:` list, verbatim, under the same instruction |

**The `scope` token stays `in-pr`.** Locally it reads as *on a line the
uncommitted change added or modified, including any line of a new untracked
file*, or with a range, *on a line the range added or modified*; `general`
still means code the change left untouched. Keeping the token is
what lets §4e's routing matrix apply with no local fork.

Add one line to **every** sub-agent prompt you dispatch, with no exception. That
is each of the four lenses, and every role on Phase C's verification panel — the
red-team attacker, the blue-team defender, and the auditor — and the single
skeptic, which §L3 sends every soft observation to. Their own skeletons say only
*read-only, no patching*, which forbids
writing code and never names what destroys a working tree:

```
This is the human's live working directory, not a scratch clone. Read it, and
never write to it. Git is read-only for you: status, diff, log, show,
merge-base, rev-parse, and ls-files are allowed, and every other git verb is
forbidden. That includes restore, stash, checkout, switch, reset, clean, and
fetch -- each one discards uncommitted work or moves the branch or the refs
you were sent to read. Never change a file's content,
location, existence, or metadata either: no chmod, no rm, no mv, no truncate,
and no formatter or linter run with a write flag. That holds even for a moment:
a file you rename and rename back still changes the tree the human approves, and
races any other run reading it. Validate by running the existing tests in this
directory and reading them. Write no probe script, copy no repository, and trim
no test file, not even in scratch. Run no mutation testing of any kind: judge
test strength by reading the tests. Report a hole no test covers as a finding that names the missing
test. A PreToolUse hook refuses writes to the working tree, and that
denial is final -- report it, never work around it.
```

## §L4-fallback — the inline review, when there is no fan-out

`review-phases.md`'s `§4-fallback` runs when the `Agent` tool is unavailable,
when `fanout` is `false`, or when every dispatch errors. That is a live path, not
a theoretical one, and its wording is wrong twice over locally: it sends you to
*the checkout*, which a local review has not got, and it judges against *the AC*,
which a local review has not got either. Take its shape from there. Take its
content from here.

You review the working tree yourself, in place, exactly as a single reviewer:

- **The evidence room is the `Workdir:` path**, established as §L4b describes —
  `git diff HEAD` plus the untracked-file list, with each new file read
  directly, or with a range, `git diff <base>...HEAD`.
  There is no checkout to read, and the no-clone rule is not suspended because
  the fan-out is off.
- **The rubric is the brief's `Acceptance:` list**, verbatim, under §L4a.
  You never amend them here either.
- Read each changed file in context against that rubric and the repo's own
  patterns, look for correctness, security, and test defects, and read the test
  files closely for whether they mean anything. Validate as §L4c says: run the
  tests in place and inspect them, and never change code to validate it.
- **There is no adversarial verification.** You are the single head, so §L3's
  panel track has nothing to run and no finding is refuted by anyone.
- **Phase D still runs**, unchanged. It is parent-only and independent of the
  fan-out. So does the `feedback/` check from §L4a.
- **The no-write limit still binds you.** It never depended on there being a
  sub-agent to bind.

Feed the findings into the same §L5 verdict logic. The fan-out is an enhancement
layered over this path; this path is complete on its own.

## §L5 — the verdict, as prose to the dispatching session

Apply §4d and §4e unchanged: the rubric is the contract, findings route by the
coherent unit first, then coupling, then locality. The **coherent unit of work**
is what the brief's `Goal:` sets out to deliver, exactly as the issue is in Index
mode.

Three outcomes, and only three. None of them writes anywhere.

**✅ Approved** — every rubric item met, no hard defect this repo can fix, and the change
plus everything belonging to the coherent unit carry no actionable finding.

```
✅ **Approved** — <workdir>

## Review Summary
- <what was reviewed: files changed, covering-test result>
- Every `Acceptance:` criterion is met: <AC1 — how>, <AC2 — how>
- Everything belonging to the coherent unit is clean

## 📋 Non-blocking follow-ups
- <observation — `file:line` — why — disposition; or `- None.`>

## Findings for other projects
- <bug, security, or integrity finding only another repo can fix — `file:line` — owning project; or `- None.`>
```

**🔄 Changes requested** — a rubric item is unmet, a hard defect surfaced, or the
change or its coherent unit carries an actionable finding. A bug, a security
problem, or an integrity problem that the workdir's repo can fix is a hard
defect wherever it lives in that repo: in code the change never touched, in code
that predates it, and outside the brief's scope. It goes under `## Issues Found`,
and the verdict is changes requested. A finding that only another repo can fix
does not hold the verdict. Name it, its location and its owning project in a
`## Findings for other projects` section, so the orchestrator sends it to that
project's session. Same body as Index
mode: `## Issues Found`, `## What's Good`, `## 📋 Non-blocking follow-ups`, and
`## Findings for other projects`.
There is no `## Unverified Observations` section, because Local mode has no
verification cap to overflow (§L3).

**🛑 Rubric dispute** — the local form of an escalation. A criterion in the
brief's `Acceptance:` list is itself wrong, imprecise, impossible, or
contradicted by the repo; or the change diverges from it in a way you cannot
confidently call a strict, nothing-dropped improvement. You may not approve around it, and
requesting changes would force an undo of a choice that may be correct. Hand the
dispute back as a decision, never as an open question: **three options in one
table with the columns Option, Pros, Cons, and Grade, then one or two sentences
naming your recommendation, its grade, and why.** Grade each option against the
brief's `Acceptance:` list: "All met", or each criterion short of met by its
number and a few words. The session puts the dispute to the human through
`AskUserQuestion`, so write each option so it stands without the table. The
brief is the sender's to amend, not yours.

**Follow-ups are reported, never tracked.** A bug, security, or integrity
finding is never a follow-up, and never a note with nothing to track: it blocks,
latent or live, pre-existing or out of scope, when this repo can fix it, and it
goes to the owning project's session otherwise. The materiality gate sorts only
the other findings — unrelated one-off cosmetic, unrelated systemic/substantial
debt — and no issue is opened, because no GitHub write happens here. A finding
that clears the debt gate is listed as **recommended for tracking**, with the
reason, and the human decides whether it becomes an issue. The one-anchor cap is irrelevant when nothing is minted.

There is no board item to re-read before writing, because nothing is written to a
board. The Index-mode freshness check (§5) has no local counterpart.

## §L5.5 — one learnings note, and the digest stays untouched

Write one atomic vault note per local verdict. It is a different population from
the board reviews, and it never feeds the shared ranking.

**Do not read, increment, or write `dev-team/top-lessons.md`.** That digest ranks
rejection categories by frequency to derive prevention rules, and its
clean-approval tally counts board reviews. Local counts would skew both. This is
the one step where Local mode does less than Index mode on purpose.

Neither §5.5 path fits as written: there is no prior Holmes change-request to
compare against, so there is no failure→fix pair (Path A), and there is no round
count that makes an approve a *first-pass* approve (Path B). The note records the
verdict and its categories with no prior-rejection comparison.

**Categories still apply** — they classify defects, not rounds. Use the same
taxonomy (`test-honesty`, `security-hardening`, `fail-open`, `correctness`,
`doc-drift`, `nitpick`, and `escalation` for a rubric dispute). `ac-not-met`
reads as *rubric not met*. An approve with no findings is `clean`.

**The path is keyed on what a local review can supply.** A local review
often has no PR number, and a range review's `pr:` field is optional, so the
key never uses one. It is the workdir's basename, the date, the time to the
second, and a random token.

**The note gets a name no other note has.** Two reviews can build the same time
key, and `write` replaces any file already at that path. A read cannot prove a
path is free: the memory server answers `Document not found: <path>` both for a
missing file and for a note it cannot parse (invalid UTF-8, an I/O error, or
malformed frontmatter). So the uniqueness comes from the name. Run these two
commands, each on a line of its own:

```
date +%H%M%S
openssl rand -hex 3
```

Put the time in `<hhmmss>` and the six hex digits in `<token>`. Never make up
the token yourself. Then read the path:

- **The read answers `Document not found: <path>`:** no parseable note is
  there, and the token makes an unparseable one at that name all but
  impossible. Write the note there. This is the only answer that counts as
  free.
- **The read returns a note:** the name is taken. Run `openssl rand -hex 3`
  again, and read the new path. Never write to a path that returned a note.
- **The read fails with any other error:** the path is unproven. Skip the note
  and log it, as for a write error.

```
mcp__plugin_workbench-core_memory__read("dev-team/review-learnings/<workdir-basename>-local-<yyyy-mm-dd>-<hhmmss>-<token>.md")   # only "Document not found" counts as free
mcp__plugin_workbench-core_memory__write(
  path: "dev-team/review-learnings/<workdir-basename>-local-<yyyy-mm-dd>-<hhmmss>-<token>.md",   # the path just read; created: false → report it
  frontmatter: {
    name: "<workdir-basename> local review — <category|clean>",
    type: "insight", scope: "topical", date: "<today>",
    tags: ["dev-team", "review-learnings", "holmes", "local-review", "<category>"],
    summary: "<one line: the verdict and what drove it>"
  },
  content: "## <workdir-basename> · local review · <today>
- **Target:** uncommitted working tree at `<workdir>` (HEAD `<short-sha>`), or range `<base>...HEAD` at `<workdir>` (HEAD `<short-sha>`)
- **Rubric:** the brief's Acceptance list
- **Verdict:** approved | changes requested | rubric dispute
- **Categories:** <category>[, <category>]
- **Findings:** <one line each, or none>
- **Note:** local review — not counted in `dev-team/top-lessons.md`."
)
```

The `local-review` tag is what keeps this population separable from the PR notes
beside it. If the workdir is not a git repository, or HEAD does not exist yet,
say so in the note instead of the SHA; the path never depends on it.

Write the note before you return the verdict, and check the write's result.
`created: true` is the expected answer. **`created: false` means the write
replaced an existing note.** Do not write again. Add this line at the end of
your verdict, so the orchestrator can restore the old note from the vault's git
history:

```
⚠️ Vault note replaced: <path> (created: false). Restore the earlier note from the vault's git history.
```

A memory-write failure is logged and never changes your verdict or blocks your
report — same rule as Index mode.

## §L6 — the final suite run: the full suite, once, and nothing else

The full suite runs once per unit of work, as the last step before the human is
asked to commit or push. The orchestrator sends it only after every concern a
review raised is addressed, on a six-slot brief whose `Goal:` begins
`Final suite run:`. Neither Watson's loop nor a review pass runs the full suite,
so this run is the only one.

The three hard limits and the brief contract still bind. Nothing else from the
review path runs: no §0 fan-out, no `feedback/` search, no lens, no
verification, no Phase D, no verdict on the code, and no vault note.

1. Establish the change as §L4b says. If the change is empty, report that and
   stop.
2. Discover the suite's entry point as §L4c says. Run every existing suite in
   the `Workdir:`, and the project's own test command with it, such as
   `claude plugin test` in a Claude Code plugin. Run them read-only, under
   §L4c's limits.
3. Report the result to the dispatching session, as prose, in one of three
   forms:

```
✅ **Suite green** — <workdir>
- <each command run, and its pass count>
```

```
🔄 **Suite red** — <workdir>
- <each failing test — `file:line` — whether the change plausibly caused it>
```

```
⚠️ **No suite found** — <workdir>
- <where you looked for an entry point>
```

On a red run, never isolate the failure by changing the tree. §L4c's red rule
holds here. The orchestrator sends a red run to Watson as a bounded fix, and the
final suite run repeats after the fix.
