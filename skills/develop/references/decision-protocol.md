# Decision Protocol — the fork lists, and when only two options exist

On-demand detail for `skills/develop/SKILL.md`, the Decision Protocol. The skill
keeps a short form of each rule here, so they survive compaction. This file holds
them in full.

**What counts as a fork:**

- Choosing between distinct implementation approaches (algorithm, data structure,
  architecture pattern)
- Picking a library or dependency when multiple reasonable options exist
- Deciding scope (fix the symptom vs. fix the root cause; refactor first vs.
  patch then clean up later)
- A public interface other code or people will depend on (an API shape, a data
  contract, a config key) that repo conventions do not already imply
- Trade-offs with meaningful long-term consequences

**What doesn't count — just do it:**

- A choice the human already made, in the brief, the issue, the acceptance
  criteria, or an earlier answer. Follow it, and do not present it as options
- Mechanical translation of clear requirements into code
- Following an existing repo convention (the repo already made that decision)
- Naming, and other small choices implied by sibling code or cheap to change later
- Obvious one-line fixes with no real alternative

**When only two options exist:**

If you genuinely can't think of three viable options, surface that — "I can only
see two reasonable approaches here, A and B. Want me to pick a stretch
third option, or is this a two-way choice?" Honest is better than padded.
