# Parallel units — worktrees, test databases, commits and landing

On-demand detail for `skills/orchestrate/SKILL.md`, "Dispatch in parallel". The
skill holds the short rules that must survive compaction. This file holds the
steps and the exact lines workbench-core's provisioning guard accepts.

**This flow needs workbench-core 0.59.0 or later**, the first release with the
provisioning ledger (commit 7ef2854). An older core refuses every create, and
same-repo units then run one at a time. The landing and commit steps below run
with no question from the first workbench-core release after 0.66.1, which
carries commit 6e6b534. With an older core, its commit gate still raises a
question for each.

## Cut the task into units first

Before the first dispatch, cut the task into its smallest units. A unit is one
step that one brief delivers, with its own criteria and its own files. When
`/workbench-core:intake` ended with a unit list, start from it: each unit there
carries its criteria, its files, and whether it runs in parallel or in order.
Otherwise cut the units yourself from the criteria.

Dispatch each unit on its own brief. Its `Unit:` line names the step and the
criteria it meets, such as `Unit: 2 of 4, the focus ring. Meets AC3, AC4.`, and
`Acceptance:` may keep the whole task's criteria for context. This holds for
every task, one repo or many. The rest of this file covers same-repo units.

**Size each dispatched task to finish within about 10 minutes.** This is a
strong recommendation, not a hard limit, and it holds for every dispatch,
a review and a final suite run included. A dev-team agent runs every Bash
command in the foreground, inside its own turn: the dev-team mod refuses its
`run_in_background`, and the Bash tool cuts a foreground command off at
600000 ms. So never ask an agent for a background command. When a task looks
longer, cut it smaller: fewer criteria, fewer files, or a narrower test run.
When the task holds a run that may pass 10 minutes, such as a large suite,
say in the brief how to split it into parts that each finish within the limit.

## When work splits into units

Same-repo work splits into parallel units when each unit:

- touches files that no other unit touches, and
- needs nothing that another unit produces.

A unit that depends on the others, such as docs regenerated from all of them,
waits until they land, then runs as a unit of its own. Units that touch the
same files run one at a time, the short unit first.

**A later unit runs in the project tree, with no worktree.** A squash landing
leaves the feature branch's committed tip where it was, and a worktree is cut
from that tip. So a worktree never holds the units landed before it. A unit
that depends on landed units, or that shares files with one, runs in the
project tree on the feature branch after those units land. Watson's `Workdir:`
is the project folder, and Holmes reviews that unit in the same tree.

Units land on a feature branch. Settle that branch with the workspace check in
`SKILL.md` before the first unit starts. The project tree stays on it until the
task's commit.

**The task gets one commit.** Each unit lands in the feature branch's working
tree with `git merge --squash`, which makes no commit. A fix after a red final
suite run goes in the same tree. The main session commits once, after the green
final suite run. The feature branch gains no merge commit and no commit per
unit.

## Who does what

- **The main session provisions, lands, tears down and commits.** It does each
  step itself, for the units it dispatched and for no other, and asks the
  human nothing for any of them. The guard holds the ownership rule: it
  accepts a database create, a worktree remove and a database drop with no
  question only for a unit that this session recorded in the ledger.
- **A sub-agent provisions nothing and commits nothing.** Watson works in the
  unit worktree his brief names, and reports a need for anything else.
- **Holmes reviews each unit in its own tree**, on a Local-mode brief whose
  `Workdir:` is the unit worktree.

## What asks the human

Mike's rules, from 2026-11-27: never ask him whether to land a unit branch, and
anything a session creates without asking, it also tears down without asking.

- **Land, tear down and commit with no question.** A main-session commit runs
  free on any branch. So does a local merge, or a pull that does not rebase,
  onto a branch other than the default branch, a unit landing included.
- **A catch-up merge runs with no question.** A merge that brings the base
  branch into a feature branch, such as `git merge origin/main`, lands no unit.
  Mike updates branches with `git merge`.
- **Sync a branch with its own remote by fetch, pull and push.** When a local
  branch is out of step with its own remote, such as after a rejected push, run
  `git fetch --all`, then `git pull`, then `git push`. Never rebase, and never
  hand-run a merge for this.
- **Catch up or sync only before the first worktree add or after the task
  commit, never while units are out.** A catch-up after the worktrees are cut
  moves HEAD off the units' base, so each squash becomes a true merge, and a
  merge or pull refuses to run on an index that holds staged squashes.
- **A plain push of the feature branch runs with no question.**
- **These still ask the human:**
  - a push to the default branch, except a plain push whose every commit came
    from a green final suite run
  - a merge or pull into the default branch
  - a pull that rebases, which asks as a history rewrite
  - a release, a history rewrite and a branch reset
  - a remote-tracking ref update, `gh alias set`, and a write to the default
    branch through the GitHub API

## Names

- `<project>` is the base name of the session's project folder.
- `<unit>` matches `[A-Za-z0-9][A-Za-z0-9._-]*`, and no folder of that name may
  exist yet.
- The unit worktree is `~/Developer/worktrees/<project>/<unit>`. Write it as an
  absolute path, because the guard refuses a path that holds `~`.
- The unit database is `wt_<project>_<unit>_testing`, lowercased, with each run
  of other characters turned into `_`.
- **A database name is at most 55 characters.** Postgres truncates a name at 63
  bytes, and Laravel parallel testing appends `_test_N`, so a longer name makes
  every worker share one database. A longer name becomes its first 46
  characters, then `_`, then the first 8 hex digits of the SHA-256 of the full
  name. The guard computes this name, and the context of the create names it.
- **When the name is long, set `TEST_DB_DATABASE` in the worktree** to the
  shortened name, because the project's own test config derives the full name.
  Set it in the worktree's local, untracked settings, never in a tracked file,
  so it never lands on the feature branch.

## The accepted lines

Every line is one plain statement. No `&&`, wrapper, variable, redirect or
`cd`, and nothing runs in the background. Run the worktree add and remove lines
in the project folder or with `git -C <project folder>`. The stage and commit
lines of step 5 target the unit tree, with `git -C <path>`. Any other shape
goes to the guard's ordinary rules, which refuse it.

1. **Create the worktree first.** It reserves the unit database.
   `git worktree add -b <unit branch> <path> <feature branch>`
   The guard records the entry before the line runs, and takes it out when git
   fails.
2. **Create the database once, under the reserved name only.**
   `createdb [-h <host>] [-p <port>] [-U <user>] [-w] <db>`, or
   `psql [-h -p -U -w] -d postgres -c 'CREATE DATABASE "<db>"'`.
   Use the host, port and user of the project's test connection. A project
   whose tests use no database server skips this step and step 9's drop.
3. **Dispatch one Watson per unit, all in one message.** `Workdir:` is
   `<path> (worktree: <unit>, branch: <unit branch>)`. `Context:` names the
   unit database, and says when `TEST_DB_DATABASE` must be set to it.
4. **Review and fix in the unit's own tree.** Holmes reviews each unit. A fix
   goes back to that unit's Watson, and the review repeats.
5. **Commit the unit on its own branch after Holmes's review.** Run
   `git -C <path> add -A` on its own line, then
   `git -C <path> commit -m <message>` or `-F <file>`, with HEAD on the unit
   branch. This commit only carries the unit to its landing. It never reaches
   the feature branch, and it goes with the unit branch in step 9. Never
   `cd <path> &&`, and never `git -c`.
6. **Land the unit with a squash, unasked.** In the project folder, on the
   feature branch, run `git merge --squash <unit branch>`. It stages the
   unit's changes in the feature branch's working tree and makes no commit.
   The feature branch gains no commit while units land, so each later squash
   adds its unit beside the units already in the tree. Never `--no-ff`, and
   never cherry-pick, rebase or reset a unit onto the branch. A squash that
   stops on a conflict, or on local changes it would overwrite, means the
   units were not independent: stop, and ask the human. Run no catch-up merge
   and no sync while units are out, as "What asks the human" says.
7. **Run the final suite once, after the last unit lands.** Ask the human
   through `AskUserQuestion` whether they run it or Holmes does, as the test
   timeline in `SKILL.md` says. On the Holmes pick, dispatch Holmes with a
   `Goal:` that begins `Final suite run:`. The landed units sit uncommitted in
   the project tree, so name the tree:
   `Workdir: <project folder> (branch: <feature branch>)`.
   Holmes reviews nothing in this run. He runs the full suite on that tree.
   A red run goes to Watson as a bounded fix in the same tree, and the question
   repeats.
8. **Commit the task once the run comes back green.** In the project folder,
   run `git add -A` on its own line, then `git commit -m <message>` or
   `-F <file>`. The commit needs no question.
9. **Tear every unit down after the task commit, unasked.** Until that
   commit, a unit's work after its squash lives only uncommitted in the
   project tree, and its unit branch is the one ref that keeps its commit.
   Tear down earlier, and a tree thrown away after a red run leaves that
   commit on no ref. So keep every worktree, unit branch and database until
   the task commit has landed. Then, for each unit, run each line on its own:
   - `git worktree remove <path>`, with the same path as the add and without
     `--force`.
   - `git diff --no-renames --name-only HEAD...<unit branch>`, to list every
     path the unit added, changed or deleted since its base. Without
     `--no-renames`, a rename lists only its new path. Then run
     `git diff --quiet <unit branch> HEAD -- <those paths>`. An exit of 0
     proves that the committed HEAD holds the unit's version of each listed
     path, so a path the unit deleted is absent from it too.
   - `git branch -D <unit branch>`. A squash-landed branch is not merged in
     git's sense, so `git branch -d` refuses it. Run `-D` only when the check
     above exits 0, with no exception.
   - `psql [-h -p -U] -d postgres [-w] -c 'DROP DATABASE "<db>"'`, with exactly
     the create's `-h`, `-p` and `-U`. `dropdb` stays refused.

   Report the teardown in one line. A tree that git will not remove without
   `--force` holds work that did not land, so ask the human about it.
   **On any difference, keep the unit branch.** Report it in one line that
   names the branch and the differing paths. Read the difference with
   `git diff <unit branch> HEAD -- <those paths>`. A fix from step 7 or a
   later project-tree unit that shares the path explains a difference. Ask
   the human only when the difference cannot be traced to either. A
   misjudgment then costs a kept branch, never lost work.
   workbench-core's Stop check holds an attended session that leaves a landed
   unit in place. It counts a squash-landed unit as landed only once HEAD's
   committed tree matches the unit's files, so it waits for the task commit
   too.

The push then follows the test timeline in `SKILL.md`, as it does for any other
work. A plain push of the feature branch runs with no question. Anything on the
list in "What asks the human" still asks.

## Refusals and leftovers

- A refusal that starts "Provisioning guard (workbench-core):" is the rule
  working. Report it. Never respell the line to get past it.
- `EnterWorktree`, `ExitWorktree` with `remove`, and the Agent tool's
  `isolation: "worktree"` stay refused. The guard cannot record them.
- The ledger is `~/.claude-workbench/provisioning/ledger.json`. Only the guard
  writes it. Read it with the Read tool to see what a unit recorded.
- **A unit that another session recorded is not yours.** The guard refuses a
  create, a remove or a drop for it. The refusal names what it refused, and
  says it "belongs to a unit that session <id> recorded in the provisioning
  ledger, not this session".
  - A remove or a drop refusal says "Remove nothing", then gives the `!`
    command Mike runs himself. Report the refusal to Mike with that command as
    the refusal gives it. Never run the command.
  - A create refusal says "Create nothing". Report it to Mike, who decides what
    happens to that unit.
  - Commit, land and tear down nothing of that unit. Its work belongs to the
    other session.
- **Session start reports leftovers, and only reports them.** The
  "Provisioning ledger leftovers" block lists each unit that another session
  recorded, with a "Mike runs:" list of `!` commands. Report each unit to Mike
  with its commands. Remove nothing, and run none of the commands.
