# Why the brief is shaped the way it is

On-demand reasoning for `skills/orchestrate/SKILL.md`. The skill states the
rules; this file holds the measurements and arguments behind them. The
orchestrator loads the skill on every orchestration and this file **only when a
rule is challenged** — that split is the point, so nothing here is a rule and
nothing here needs reading to dispatch correctly.

Each section names the rule it explains. Change a rule in the skill, change its
reasoning here in the same commit.

---

## The fan-out exemption, and why it is a boundary

**Rule it explains:** a specialist's own fan-out is not a handoff.

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

## Why `Constraints:` may read "none" and `Context:` may not

**Rule it explains:** the asymmetry between the two slots.

They sit that way round deliberately. A task can honestly have no hard limit
beyond what the repo already states, so "none" there is a true answer. A task
always has a reason for existing, so "none" there is never true — and a "none"
the receiver accepts becomes the token senders reach for by default, which
reproduces the bare instruction the whole template exists to kill.

The pair was written the other way round once, which is why
`agents/lint-brief-contract.sh` greps for both halves and fails on a flip.

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
