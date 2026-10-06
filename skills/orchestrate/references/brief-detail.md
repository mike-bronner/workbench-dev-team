# Brief detail — each slot's full rule, what a brief must carry, and a database limit

On-demand detail for `skills/orchestrate/SKILL.md`, "The brief". The skill holds
the template, a short form of each slot's rule, and the must-omit list, so they
survive compaction. This file holds each slot's rule in full, and the rules you
need while writing a brief's `Constraints:` and checking it is complete.

## The six slots, one by one

**`Workdir:` is the absolute path, and the workspace when there is one to
state** — the branch or worktree the human agreed to, written beside the path.
A bare path carries no workspace decision and stays valid, which is most
dispatches. The workspace check in `SKILL.md` is where that decision gets made.

**`Goal:` is the one bounded slot: one or two sentences, concise, measurable,
achievable.** Background that will not fit is not cut, it moves to `Context:`,
which exists so `Goal:` never has to carry it. Why `Goal:` is bounded:
`references/brief-rationale.md`.

**`Context:` is unbounded.** It is prose, it may run as long as the reasoning
runs, and no length figure applies to it or to the brief as a whole.

**`Constraints:` is bullets, one limit per bullet, each carrying its own
reason.** A constraint without its reason gets obeyed literally and defeated in
spirit: the agent meets the letter, hits a surprise in the repo, and works
around the part that mattered because nothing told it what the limit protects.
**A limit on a database names the category, never one activity** — how to word
it: "A database limit names the category" (below).

**`Acceptance:` is the list the work is graded against, and it is required.**
Number the criteria, one per bullet. Each one names a result, never a method,
and someone other than you can check it without asking. The receiver grades its
forks against the list and reports against it, and Holmes reviews against it.
When this session ran `/workbench-core:intake`, copy its criteria here. The
reasoning: `references/brief-rationale.md`.

**`Done when:` is an observable finish line** — a state you could check without
asking the agent what it meant. It is where the task stops, such as the change
handed back uncommitted, which is a different thing from what the result must
satisfy.

**`Constraints:` may read "none". `Context:` may not**, and `Context:` carries
at least one sentence on why the task exists. The asymmetry is deliberate, and
`references/brief-rationale.md` says why.

Every slot is required, and every dev-team agent refuses a brief that drops one,
naming what is missing (`agents/*.md`, the brief contract) — this is a receiving
contract, not only a sending one.

**There is no length limit.** Write the reasoning at whatever length it takes,
and write no shell command at any length. The must-omit list in `SKILL.md` is
the whole of the limit; an earlier stated figure and why it went are in
`references/brief-rationale.md`.

## A database limit names the category

**A limit on a database names the category, never one activity.** State the
connection the agent may execute against and forbid every other one, not the one
command you had in mind. The incident behind this:
`references/brief-rationale.md`. Write the limit like this:

```
- Execute nothing against any database connection except <the designated
  test database>. Every other connection holds data we cannot rebuild.
```

## Must carry — the sub-agent cannot derive these

Omitting these causes the opposite failure: an agent inventing requirements,
which `/develop` tells it to refuse rather than guess.

- **The working directory**, absolute. The sub-agent inherits none from this
  conversation. It is often a repository, and does not have to be — a read-only
  research dispatch may point at a directory that is not one.
- **Hard constraints**: decisions the human already made, an interface that must
  not change, files that are out of bounds, a dependency ban, answers to forks
  already settled in chat.
- **The acceptance criteria, in `Acceptance:`**: what must be true of the result
  for it to count.
- **The definition of done**: the state that ends the task, and one the agent's
  lane can reach. A sub-agent cannot commit, push, or open a PR, so a Direct-mode
  or research brief ends at tests green and the work reported back; "a PR is
  open" belongs only to an Index-mode run.
- **The reasoning, in `Context:`** — the measurement, the incident, the argument
  that settled a fork, the reason this outcome is wanted over the obvious one.
  A constraint with its reason survives contact with a surprise in the repo; a
  bare constraint gets worked around. There is no task with nothing here: at
  minimum, why this task exists at all.
