# Local mode — reviewing an uncommitted working tree

On-demand detail for `agents/holmes.md`. Sherlock Holmes reads this file when a
prose brief puts him in **Local mode**, and follows it end to end in place of the
Index-mode workflow (§1–§6 of the agent prompt).

**What Local mode reviews: the uncommitted working tree in the brief's
`Workdir:`** — the tracked changes plus the untracked files git would not
ignore. Nothing else. It does not review a committed branch against a base, and
it does not review a pull request on a repo The Index does not govern. Those are
Index mode's job or nobody's.

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
    `rev-parse`, `blame` and the other reading verbs are yours. **Every other
    git verb is forbidden** — `restore` and `stash` and `checkout` and `switch`
    and `reset` and `clean` among them. `git restore` is the most destructive
    command available to you here: it discards precisely the uncommitted change
    the mode exists to read.
  - **Nothing changes a file's content, location, existence, or metadata.** No
    `chmod`, no `chown`, no `rm`, no `mv`, no `truncate`, no formatter or linter
    run with a write flag, no commit. A file-mode change is a write.

  Index mode's §4b begins by deleting its clone path; **that line has no local
  counterpart and copying it would destroy the work under review.** The no-patch
  posture you already hold on code covers you; §L4 is what carries the same
  limit to every sub-agent you dispatch.

  **A `PreToolUse` hook enforces this** — `hooks/scripts/local-review-guard.sh`
  refuses those commands for every sub-agent of a session with a local review in
  flight, and leaves reads and the test suite alone. It is a backstop for the
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
| §0 config (`fanout`, `lensModel`) | **unchanged** — read it the same way |
| §1 fetch the item | **replaced** — the brief is the input; there is no item |
| §2 find the PR | **replaced** — the target is the working tree in `Workdir:` |
| §2.5 decision request | **does not apply** — no PR, no Watson blocked-marker |
| §3 strike count | **does not apply** — see §L3 |
| §4a read the issue and AC | **replaced** — the rubric is the brief (§L4a) |
| §4b check out the PR | **replaced** — the workdir *is* the evidence room (§L4b) |
| §4c CI status | **replaced** — run the repo's own suite (§L4c) |
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
  red-team / blue-team / auditor panel for every finding, not the single skeptic.
  That is the existing reasoning applied unchanged: the first review of a window
  sets the whole punch list, and a false REFUTED there hands the human a picture
  that is wrong from the start. The 10-verification cap and its priority order
  are unchanged.

## §L4a — the rubric is the brief, and you never amend it

Index mode's rubric is the acceptance criteria, which Holmes is forbidden to
write or amend. A local review has no acceptance criteria to fetch. **The
brief's `Goal:` and `Done when:` slots are the rubric**: an outcome and an
observable finish line, written by whoever dispatched the work.

They bind exactly as acceptance criteria bind. Paste both slots **verbatim** into
the lens prompts. Never paraphrase them, never widen them, never quietly narrow
one because the tree would then pass. `Constraints:` is not the rubric, but a
change that breaks a stated constraint is a finding — the constraint carries its
reason, and the reason is what you check against.

`Context:` is background for your reading. It is not a criterion.

## §L4b — the workdir is the evidence room

No clone, no checkout, no scratch directory. Every lens reviewer and every
verifier reads the same absolute `Workdir:` path you were given, in place.

Establish the change under review first — it is what `gh pr diff` is in Index
mode, and it is the map every lens starts from:

```bash
git -C <workdir> status --short                       # the shape of the change
git -C <workdir> diff HEAD                            # tracked changes, staged and not
git -C <workdir> ls-files --others --exclude-standard  # untracked files git would keep
```

Read each untracked file directly — `diff HEAD` never shows one, and a change
that lives entirely in new files is invisible without this list.

**An empty change is not a review.** If both the diff and the untracked list come
back empty, there is nothing to review: report that, name the workdir, write no
vault note, and stop. Fail closed rather than reviewing HEAD as though it were
the change.

**If `Workdir:` names a branch or worktree, confirm you are in it** (`git -C
<workdir> status -sb`) and say so in your report when you are not. Do not switch
to it — switching is a write.

## §L4c — run the repo's own suite

Index mode does not run tests locally because the toolchain is wrong and it is
slow. Neither holds here: you are sitting in the repository's own working
directory, on the human's machine, with its toolchain installed. So run it.

Discover the entry point from the repo the same way any agent does — its
`CLAUDE.md`, its README, its package manifest, its makefile — and run it
**read-only**. Never a flag that rewrites files (`--fix`, `--write`, a formatter
in write mode), never a command that installs or upgrades anything, never a
commit.

- **Green** → the suite passed. ✅
- **Red** → a blocker. Name the failing test and say plainly whether the change
  under review plausibly caused it. **Never isolate by mutating the tree** — no
  `restore`, no `stash`, no `checkout`, no `reset`, and nothing else that moves
  the tree off the change you were sent to read. `git diff HEAD` and `git show`
  answer "what did this change do?" without touching anything. If you still
  cannot tell whether the failure is pre-existing, say that instead of finding
  out destructively.
- **No suite you can discover** → say so in the verdict, and the test-honesty
  lens reads the test files closely instead. Same fallback as an Index-mode PR
  with no CI configured.

A green suite tells you the tests *pass*. The test-honesty lens still reads them
to judge whether they mean anything.

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
| `Checkout (already prepared, do not re-clone): /tmp/holmes-<issue_number>` | `Working tree (the human's live directory — read only, never modify): <workdir>` |
| `PR number: <PR_NUM>   Repo: <repo>` | the workdir, and the changed-file list from §L4b |
| `gh pr diff <PR_NUM>` (the map, and the scope test) | `git -C <workdir> diff HEAD`, plus the untracked-file list |
| `Acceptance criteria (verbatim — never amend or reinterpret)` | the brief's `Goal:` and `Done when:`, verbatim, under the same instruction |

**The `scope` token stays `in-pr`.** Locally it reads as *on a line the
uncommitted change added or modified, including any line of a new untracked
file*; `general` still means code the change left untouched. Keeping the token is
what lets §4e's routing matrix apply with no local fork.

Add one line to **every** sub-agent prompt you dispatch, with no exception. That
is each of the four lenses, and every role on Phase C's verification panel — the
red-team attacker, the blue-team defender, and the auditor. §L3 puts every local
review on that panel track, so those three are the verifiers a local review
actually dispatches; the single skeptic takes the line too, wherever a track
reaches it. Their own skeletons say only *read-only, no patching*, which forbids
writing code and never names what destroys a working tree:

```
This is the human's live working directory, not a scratch clone. Read it, and
never write to it. Git is read-only for you: status, diff, log, show, and
ls-files are allowed, and every other git verb is forbidden. That includes
restore, stash, checkout, switch, reset, and clean -- each one discards the
uncommitted change you were sent to read. Never change a file's content,
location, existence, or metadata either: no chmod, no rm, no mv, no truncate,
and no formatter or linter run with a write flag. A PreToolUse hook refuses
these too, and its denial is final -- report it, never work around it.
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
  `git diff HEAD` plus the untracked-file list, with each new file read directly.
  There is no checkout to read, and the no-clone rule is not suspended because
  the fan-out is off.
- **The rubric is the brief's `Goal:` and `Done when:`**, verbatim, under §L4a.
  You never amend them here either.
- Read each changed file in context against that rubric and the repo's own
  patterns, look for correctness, security, and test defects, and read the test
  files closely for whether they mean anything.
- **There is no adversarial verification.** You are the single head, so §L3's
  panel track has nothing to run and no finding is refuted by anyone.
- **Phase D still runs**, unchanged. It is parent-only and independent of the
  fan-out.
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

**✅ Approved** — every rubric item met, no hard defect anywhere, and the change
plus everything belonging to the coherent unit carry no actionable finding.

```
✅ **Approved** — <workdir>

## Review Summary
- <what was reviewed: files changed, suite result>
- Goal and Done when are both met
- Everything belonging to the coherent unit is clean

## 📋 Non-blocking follow-ups
- <observation — `file:line` — why — disposition; or `- None.`>
```

**🔄 Changes requested** — a rubric item is unmet, a hard defect surfaced, or the
change or its coherent unit carries an actionable finding. Same body as Index
mode: `## Issues Found`, `## What's Good`, `## 📋 Non-blocking follow-ups`, and
`## Unverified Observations` only when Phase C's cap overflowed.

**🛑 Rubric dispute** — the local form of an escalation. The brief's `Goal:` or
`Done when:` is itself wrong, imprecise, impossible, or contradicted by the
repo; or the change diverges from it in a way you cannot confidently call a
strict, nothing-dropped improvement. You may not approve around it, and
requesting changes would force an undo of a choice that may be correct. Hand the
dispute back as a decision, never as an open question: **three options, pros and
cons each, then your recommendation and why**, so the session can answer with a
number. The brief is the sender's to amend, not yours.

**Follow-ups are reported, never tracked.** The materiality gate still sorts
them — unrelated one-off cosmetic, unrelated latent hazard, unrelated
systemic/substantial debt — but no issue is opened, because no GitHub write
happens here. A finding that clears the hazard or debt gate is listed as
**recommended for tracking**, with the reason, and the human decides whether it
becomes an issue. The one-anchor cap is irrelevant when nothing is minted.

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

**The path is keyed on what a local review can supply.** There is no PR number,
so the key is the workdir's basename, the date, and the time to the minute:

```
mcp__plugin_workbench-core_memory__write(
  path: "dev-team/review-learnings/<workdir-basename>-local-<yyyy-mm-dd>-<hhmm>.md",
  frontmatter: {
    name: "<workdir-basename> local review — <category|clean>",
    type: "insight", scope: "topical", date: "<today>",
    tags: ["dev-team", "review-learnings", "holmes", "local-review", "<category>"],
    summary: "<one line: the verdict and what drove it>"
  },
  content: "## <workdir-basename> · local review · <today>
- **Target:** uncommitted working tree at `<workdir>` (HEAD `<short-sha>`)
- **Rubric:** the brief's Goal and Done when
- **Verdict:** approved | changes requested | rubric dispute
- **Categories:** <category>[, <category>]
- **Findings:** <one line each, or none>
- **Note:** local review — not counted in `dev-team/top-lessons.md`."
)
```

The `local-review` tag is what keeps this population separable from the PR notes
beside it. If the workdir is not a git repository, or HEAD does not exist yet,
say so in the note instead of the SHA; the path never depends on it.

A memory-write failure is logged and never changes your verdict or blocks your
report — same rule as Index mode.
