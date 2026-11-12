# Brief detail — each slot's full rule, what a brief must carry, and a database limit

On-demand detail for `skills/orchestrate/SKILL.md`, "The brief". The skill holds
the template, a short form of each slot's rule, and the must-omit list, so they
survive compaction. This file holds each slot's rule in full, and the rules you
need while writing a brief's `Constraints:` and checking it is complete.

## The six slots, one by one

**`Workdir:` is the absolute path, and the workspace when there is one to
state** — the branch or worktree the human agreed to, or the worktree you
provisioned for a parallel unit, written beside the path as
`(worktree: <unit>, branch: <unit branch>)`. A bare path carries no workspace
decision and stays valid, which is most dispatches. The workspace check in
`SKILL.md` is where that decision gets made. A unit brief's `Context:` also
names the unit's test database: `references/parallel-units.md`.

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

**A brief for a CI-only failure rules out a local copy of CI.** Mike's machine
stays lean, and CI already proves the other platform, so a brief never asks
Watson to reproduce a Linux or CI failure locally. On 2026-11-12 a brief asked
for that, and Watson built Docker images its guards then kept it from removing.
Write the limit like this:

```
- Do not use Docker, a VM or a source build to mimic CI or another platform
  locally. CI already proves that platform, and what such a build leaves behind
  cannot be removed by the agent.
```

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

**`Constraints:` may read "none" in a brief to Lestrade or another agent, never
in a Watson or Holmes brief, which carries the no-mutation line (below).
`Context:` may not**, and `Context:` carries at least one sentence on why the
task exists. The asymmetry is deliberate, and
`references/brief-rationale.md` says why.

Every slot is required, and every dev-team agent refuses a brief that drops one,
naming what is missing (`agents/*.md`, the brief contract) — this is a receiving
contract, not only a sending one.

**There is no length limit.** Write the reasoning at whatever length it takes,
and write no shell command at any length. The must-omit list in `SKILL.md` is
the whole of the limit; an earlier stated figure and why it went are in
`references/brief-rationale.md`.

## Watson and Holmes briefs carry the no-mutation line

The human ruled that no mutation testing of any kind runs, so every Watson and
Holmes brief carries this exact line as the last item of every `Constraints:`
block:

```
- Run no mutation testing of any kind.
```

Case and the bullet may vary, a leading quote mark, parenthesis or backtick is
accepted, and a reason may follow the line. No other wording counts, even one
that says the same thing. The line does not count when except, but, unless or
other than follows it, in the same item or in any later item of the same
`Constraints:` block, even when that later item is about something else. So put
the line last. A quoted line, led by `>`, never counts and never supplies
a slot. Every `Constraints:` block carries the line, and a sub-bullet under
another bullet does not count.

Never put mutation, mutants included, or both a removal word and a failure word
into one item of a judged block. A sub-bullet counts with its parent item. The
judged blocks are:

- every `Goal:`, `Acceptance:` and `Done when:` block;
- every repeated `Workdir:`, `Context:` or `Constraints:` block, that is, each
  block after the first under its label, minus the no-mutation line itself.

The first `Workdir:`, `Context:` and `Constraints:` blocks are not judged for
this, and every `Constraints:` block is checked for the line. The removal words
are removed, deleted, reverted, restored, inverted, undone, dropped, disabled
and commented out, in any form. The failure words are fail, break, broke and
redden in any form, and go or turn red in any form, with up to three words
between.
The rule is strict on purpose: "no existing test fails after the helper is
removed" is refused too. State what the test covers instead: "a test covers the
expired entry". An item that must quote such words puts them in backticks,
which the gate does not read: "a test covers the `Delete failed` message".

The dev-team mod's no-mutation gate (`hooks/mods/spawn.ts`) enforces both
rules. It refuses a Watson Direct-mode or Holmes Local-mode brief that breaks
either one, or whose `Constraints:` or `Acceptance:` label it cannot find, and
names each fix. When a later item voids the line, the refusal quotes that item
and says to put the line last in its block. It reads a label in any case, with
Markdown decoration around it, such as `**Acceptance**:`. The two machine-built
tokens carry no brief, so the gate never judges them.

When you quote another brief in `Context:`, lead every quoted line with `>`.
The gate reads any other line that opens with a label as a real label.

Accepted limits, because the gate matches words and reads no meaning:

- Wording off these lists passes, such as "the guard is gone and the suite
  is red".
- Honest wording that happens to hold the words is refused, such as "a test
  covers the dropdown that failed to load".
- An honest later `Constraints:` item that holds "but" voids the line, such as
  "keep the API, but rename freely".
- A second `Context:` block is judged, so a second one that describes the rule
  is refused. Merge it into the first, or put the words in backticks.
- A brief quoted in `Context:` without a leading `>`, as bare lines or in a
  fenced block, has its labels read as real ones.
- An asterisk bullet such as `* Goal:` counts as a label.

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
  or research brief ends at the tests that cover the change green and the work
  reported back, never at a full-suite run (the test timeline); "a PR is
  open" belongs only to an Index-mode run.
- **The reasoning, in `Context:`** — the measurement, the incident, the argument
  that settled a fork, the reason this outcome is wanted over the obvious one.
  A constraint with its reason survives contact with a surprise in the repo; a
  bare constraint gets worked around. There is no task with nothing here: at
  minimum, why this task exists at all.
