# Parallel units — worktrees, test databases, commits and landing

On-demand detail for `skills/orchestrate/SKILL.md`, "Dispatch in parallel". The
skill holds the short rules that must survive compaction. This file holds the
steps and the exact lines workbench-core's provisioning guard accepts.

**This flow needs workbench-core 0.59.0 or later**, the first release with the
provisioning ledger (commit 7ef2854). An older core refuses every create, and
same-repo units then run one at a time.

## When work splits into units

Same-repo work splits into parallel units when each unit:

- touches files that no other unit touches, and
- needs nothing that another unit produces.

A unit that depends on the others, such as docs regenerated from all of them,
waits until they land, then runs as a unit of its own. Units that touch the
same files run one at a time, the short unit first.

Units land on a feature branch. Settle that branch with the workspace check in
`SKILL.md` before the first unit starts. The project tree stays on it until the
last unit lands.

## Who does what

- **The main session provisions, commits, lands and cleans up.** It does each
  step itself, with no question to the human, for the units it dispatched and
  for no other. The guard holds this rule: it accepts a database create, a
  worktree remove, a database drop and the unit commit with no question only
  for a unit that this session recorded in the ledger.
- **A sub-agent provisions nothing and commits nothing.** Watson works in the
  unit worktree his brief names, and reports a need for anything else.
- **Holmes reviews each unit in its own tree**, on a Local-mode brief whose
  `Workdir:` is the unit worktree.

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
   fails. Before the first unit's add, record the commit the feature branch
   holds, as `git -C <project folder> rev-parse HEAD` prints it. That commit is
   `<base>` in step 8.
2. **Create the database once, under the reserved name only.**
   `createdb [-h <host>] [-p <port>] [-U <user>] [-w] <db>`, or
   `psql [-h -p -U -w] -d postgres -c 'CREATE DATABASE "<db>"'`.
   Use the host, port and user of the project's test connection. A project
   whose tests use no database server skips this step and step 7's drop.
3. **Dispatch one Watson per unit, all in one message.** `Workdir:` is
   `<path> (worktree: <unit>, branch: <unit branch>)`. `Context:` names the
   unit database, and says when `TEST_DB_DATABASE` must be set to it.
4. **Review and fix in the unit's own tree.** Holmes reviews each unit. A fix
   goes back to that unit's Watson, and the review repeats.
5. **Commit the unit after Holmes's review.** Run `git -C <path> add -A` on its
   own line, then `git -C <path> commit -m <message>` or `-F <file>`, with HEAD
   on the unit branch. The commit needs no question. Never `cd <path> &&`, and
   never `git -c`.
6. **Land the unit with a merge commit.** In the project folder, on the
   feature branch, run `git merge --no-ff <unit branch>`. It needs no
   question. Never cherry-pick, rebase or reset a unit onto the branch. A merge
   that stops on a conflict means the units were not independent: stop, and ask
   the human.
7. **Clean up the unit once it lands.**
   - `git worktree remove <path>`, with the same path as the add and without
     `--force`.
   - `psql [-h -p -U] -d postgres [-w] -c 'DROP DATABASE "<db>"'`, with exactly
     the create's `-h`, `-p` and `-U`. `dropdb` stays refused.
   - `git branch -d <unit branch>`, which is ungated in the main session.

   A tree that git will not remove without `--force` holds work that did not
   land. Ask the human about it.
8. **Run the final suite once, after the last unit lands.** Dispatch Holmes
   with a `Goal:` that begins `Final suite run:`, as the test timeline in
   `SKILL.md` says. The landed units leave the project tree clean, so name
   them as a committed range:
   `Workdir: <project folder> (branch: <feature branch>, range: <base>...HEAD)`.
   Holmes reviews nothing in this run. He runs the full suite on the feature
   branch, and he skips the PR head check, because the run judges no PR.
   The unit commits and merges needed no question. Ask the push question only
   after this run comes back green.

A merge into the default branch and every push still ask the human, as they do
for any other work.

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
  - A commit in that unit's tree gets no exemption, so the commit gate asks
    Mike, as it does outside a unit.
- **Session start reports leftovers, and only reports them.** The
  "Provisioning ledger leftovers" block lists each unit that another session
  recorded, with a "Mike runs:" list of `!` commands. Report each unit to Mike
  with its commands. Remove nothing, and run none of the commands.
