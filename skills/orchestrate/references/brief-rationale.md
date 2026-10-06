# Why the brief and the workspace check are shaped the way they are

On-demand reasoning for `skills/orchestrate/SKILL.md`. The skill states the
rules; this file holds the measurements and arguments behind them. The
orchestrator loads the skill on every orchestration and this file **only when a
rule is challenged** — that split is the point, so nothing here is a rule and
nothing here needs reading to dispatch correctly.

Each section names the rule it explains. Change a rule in the skill, change its
reasoning here in the same commit.

---

## The workspace check exists because three things pushed the same way

**Rule it explains:** *Check the workspace before you dispatch* in `SKILL.md`.

The orchestrator was creating branches and worktrees on its own initiative,
without asking. Three independent sources in the same skill pushed that
behaviour, which is why removing any one of them would not have fixed it:

1. **Both worked examples** ended their `Done when:` slot with "and a PR is
   open". A PR needs a branch, so every example a reader copied taught
   PR-and-branch as the default finish line. Both examples are Watson
   Direct-mode briefs, and a sub-agent can neither commit nor open a PR, so
   that finish line was unreachable as well as leading. They now end with the
   change handed back uncommitted. The check still supplies what they never
   stated: *which* branch the foreground session commits to.
2. **Worktree isolation for two Watsons on one repo** was stated as a standing
   rule with no counterweight saying when not to reach for it.
3. **The Claude Code harness itself** instructs "If on the default branch,
   branch first", and no skill overrode or qualified it.

The policy is not a prohibition, and reading it as one would be the wrong fix.
Branches and worktrees are the expected, wanted outcome of most dev work. The
failure was creating them without asking, so all three rules in the skill end in
a question to the human and never in a refusal.

**Since 2026-10-05 the human creates every worktree.** Mike's rule is "i create
worktrees, never the agents", because agent-made worktrees leave orphan trees.
workbench-core's provisioning guard denies the Agent tool's
`isolation: "worktree"`, so the skill no longer advises it. For two Watsons on
one repo, the orchestrator proposes the worktrees, the human creates them, and
one Watson runs in each.

**Why the answer is recorded in `Workdir:`** rather than in a `Constraints:`
bullet or a slot of its own: a new slot costs a release of both plugins
together. The workbench-core gate reads its slot list from
`hooks/lib/brief-template.sh`, and every agent in `agents/` refuses a brief
missing a slot, so a slot added on one side alone breaks enforcement or every
receiver. The gate greps line-anchored headers and never slot content, and its
own suite asserts that the README documents each header, never any wording
inside one. Widening what `Workdir:` *means* therefore costs nothing at the
enforcement layer, while a `Constraints:` bullet would have buried a workspace
fact among hard limits. `Acceptance:` later paid the cost of a new slot, for the
reason in its own section below: no existing slot could carry it.

## Why independent units dispatch together

**Rule it explains:** *Dispatch in parallel* in `SKILL.md`.

Mike, 2026-10-05: "i only ever see 1 or 2 subagents running, when i'm pretty
sure there could be more." Units of work were being run one after the other out
of habit, when nothing made one wait on another. He then set the limits in both
directions: "local work should allow any number of sub-agents, while work from
The Index is limited."

- **Local work has no count cap.** That covers interactive sessions, Watson's
  Direct mode, Holmes's Local mode, and research dispatches, and an agent's own
  fan-out inside Local or Direct mode as well.
- **The Index pipeline stays bounded on purpose.** Scheduled Dispatch keeps one
  new Watson per tick, and the Index-mode caps stay. Mike keeps scheduled
  throughput bounded deliberately.
- **Worktrees stay the human's** in both lanes, for the reason in the workspace
  section above. Same-repo parallel work waits for the worktrees he creates.

## Why development goes to a specialist

**Rule it explains:** *Agent choice* in `SKILL.md` — development goes to Watson,
never to a generic agent.

The reason is skill loading, not seniority. A specialist loads
`/workbench-dev-team:develop` and then works *from the repo it was pointed at*:
it reads the repo's conventions, discovers the test framework, follows the
existing file layout, and sequences the work itself. A generic agent never loads
that skill, so it guesses at conventions the repo already states. That is also
why the brief omits implementation detail: the detail belongs to the sub-agent,
and only a specialist carries the standard for choosing it.

## Why research is not exempt from the brief

**Rule it explains:** every handoff uses the brief, read-only research included.

That is load-bearing rather than tidy: it is exactly what lets the companion
gate stop guessing whether a dispatch is code work. A template that applied only
to work ending in a diff would need someone — a hook, or you at speed — to
classify each prompt first, and that classification is the part that never
worked. The measurements are in the gate section below.

## Why `Goal:` is the one bounded slot

**Rule it explains:** `Goal:` is one or two sentences.

Everything downstream checks a result against it — the agent's own report,
Holmes's AC lens, your roster line — and a paragraph is not something a result
can be checked against.

## The incidents behind two brief rules

**Rules they explain:** a database limit names the category, and the must-omit
list bans framing about where the work runs.

- **The database limit.** "Don't run migrations against dev" left a seeder, a
  truncate, and a raw query free to hit the same connection. Six near-misses met
  the letter of limits like that one before the next lost 17,063 rows.
- **Where the work runs.** Framing such as "outside the app" or "a quick Python
  check" once sent Watson to edit PHP with a Python script and to diff a Laravel
  app's data in Python instead of the app's own console and test suite.

## The fan-out exemption, and why it is a boundary

**Rule it explains:** a specialist's own fan-out is not a handoff.

The template governs the **orchestrator boundary** — a dispatch that leaves an
orchestrator for a specialist. Workers a specialist spawns inside a task it
already owns are that specialist's implementation, and they keep whatever prompt
shape that agent's own reference files define.

Three things put the line at the orchestrator boundary rather than at any list
of agent names:

- **The measurement behind the template drew it already.** Of 622 dispatches
  over 14 days, the 422 that came from sessions which were themselves agent runs
  were counted as correct behaviour and excluded from what the rule governs.
- **workbench-core's `delegation-gate.sh` draws the same line**, exempting the
  calls a sub-agent makes, because a sub-agent is the destination that gate
  redirects work to.
- **A parent already holds every fact its own workers need**, so `Context:` has
  nothing left to recover. Those prompts are written against measured cost
  instead, and the reading discipline in them is carried verbatim for that
  reason.

Read as a boundary, a specialist that grows a fan-out later inherits the
exemption with no edit to the skill. Read as a list of two agent names, it would
not.

## Why no length limit is stated on the brief

**Rule it explains:** the brief has no stated length limit; the must-omit list
carries that job alone.

Earlier versions of this template stated one, and it was measuring the wrong
thing. Length was only ever a proxy for prescriptiveness, and a poor one: prose
that honestly explains why a task exists outruns any figure worth setting, so
the limit landed on the *why* — the single part of a brief that cannot be
recovered by reading the repo. Prescriptiveness is attacked directly by the
must-omit list, and that list is the whole of the limit. Write the reasoning at
whatever length it takes. Write no shell command at any length.

**The working-context budget in `agents/*.md` is not that figure returning.**
It sits on the other side of the handoff. This one would have bounded the prose
a *sender* writes, which is the thing that had to stay free, because the why is
the one part of a brief no receiver can recover from the repo. That one is a
target for what a *receiver* accumulates while working — its prompt, the files
it reads, the tool output it collects — which no sender controls and no brief
can shorten. Two quantities, two sides, and the shorter brief does not buy the
cheaper run. `agents/lint-brief-contract.sh` keeps them apart mechanically: it
excuses the word "ceiling" on a line that says "working context" and nowhere
else, and a figure stated in *characters* near the brief still fails whatever
else its line claims to be about.

## Why `Constraints:` may read "none" and `Context:` may not

**Rule it explains:** the asymmetry between the two slots.

They sit that way round deliberately. A task can honestly have no hard limit
beyond what the repo already states, so "none" there is a true answer. A task
always has a reason for existing, so "none" there is never true — and a "none"
the receiver accepts becomes the token senders reach for by default, which
reproduces the bare instruction the whole template exists to kill.

The pair was written the other way round once, which is why
`agents/lint-brief-contract.sh` greps for both halves and fails on a flip.

## Why `Acceptance:` is required, and why it is a slot of its own

**Rule it explains:** every brief carries an `Acceptance:` list, and the
receiver grades its forks and its report against it.

Mike noticed the agent had stopped asking him questions, and an audit found that
intake had never been a step. Asking was a fallback for vague requests, and
several rules pushed against it. workbench-core now carries the routine as
`/workbench-core:intake`: the goal, the context, questions only about gaps the
prompt, repo, and vault cannot fill, then acceptance criteria, and three options
graded against every criterion. That skill is the routine's one written copy.
This repo points at it and does not restate it, because a second copy is how the
old rules drifted apart.

The slot is how the criteria cross a handoff. Before it, a brief said what to do
(`Goal:`) and when the task was over (`Done when:`), but not what "good" meant in
between, so the receiver guessed at every fork. `Done when:` could not carry the
criteria: it is the state that ends the task in the receiver's lane, such as a
tree handed back uncommitted, and folding the criteria into it would bury them
again. So the criteria got a slot, and paid the cost of a release of both plugins
together, which the `Workdir:` widening above could avoid.

Three consequences follow from where the criteria come from.

- **Sub-agents never interview.** The brief is their intake. A sub-agent that
  finds a blocking gap sends it back to the orchestrator, as it did before the
  slot existed. Mike's bar is that an agent asks only when it cannot fill a gap
  itself, and is never kept from working when it already has what it needs.
- **The machine tokens stay exempt.** `Item ID: <n>` and
  `Repo sweep: <owner/repo>` carry no brief. For a Watson or Holmes Index-mode
  run, the item's acceptance criteria, written by Lestrade at triage, are the
  Acceptance list. Lestrade's own flow does not change: it writes those criteria
  and consumes none.
- **Holmes's Local mode reviews against the list.** It used `Goal:` and
  `Done when:` before, which gave it one outcome and a finish line to check
  rather than conditions it could check one by one.

The gate checks the header's presence and nothing inside it, for the reason in
the gate section below.

## Why the companion gate never classifies a dispatch

**Rule it explains:** the gate checks slot presence only, on every handoff, and
decides no routing.

Prompt classifiers were built for that job and measured against real dispatch
traffic. The ones with usable recall were wrong about two calls in three; the
one that was usually right caught barely a quarter of the cases. The misses were
not tunable — a read-only audit names every file it inspects, and a prose task
names the source file it reads but never writes. Telling a write target from a
read target is a semantic judgement, and no shell script makes it honestly.
Requiring the template on *every* handoff, research included, is what let the
guessing go.

Presence is also all the gate checks about a slot's contents, by design. Whether
`Goal:` states an outcome or a numbered implementation script is a judgement
about substance, and it belongs to the receiving agent — the one holding the
repo and the brief together. The hook regexes headers; the agent reads them.
