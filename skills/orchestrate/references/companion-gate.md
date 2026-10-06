# The companion gate

On-demand detail for `skills/orchestrate/SKILL.md`, "The brief". Read it when
the workbench-core dispatch gate refuses a handoff, or when you need to know
what that gate checks.

A `PreToolUse` hook in workbench-core checks **one thing**: that the prompt you
are dispatching uses the six-slot brief template. Six slot headers present, the
call goes through. One missing, the call is refused and the message names the
slots you dropped. It fails open rather than bricking a session, and it points
back at the orchestrate skill.

- **It does not guess whether a dispatch is code work, and it does not decide
  routing.** Classifiers were built for that job, measured against real dispatch
  traffic, and were not good enough to keep. Requiring the template on *every*
  handoff is what let the guessing go.
- **Presence is all it checks, by design.** Whether the prose inside a slot is
  any good — whether `Goal:` states an outcome or a numbered implementation
  script — belongs to the receiving agent, the one holding the repo and the
  brief together. The hook regexes headers; the agent reads them. The recall
  figures behind both bullets: `references/brief-rationale.md`.
- **Neither slot order nor length is enforced there.** Order is worth keeping
  for readability, and refusing a well-formed brief over it would cost a real
  dispatch for nothing.
- **The two machine-built tokens are exempt** — `Item ID: <n>` and
  `Repo sweep: <owner/repo>`, matched whole rather than as a prefix.
  `bin/dispatch-agent.sh` assembles them from an id or a slug, so there is no
  brief to write, and refusing one would kill every scheduled tick at its first
  dispatch.
- **A refusal is refilable, not a dead end.** Take the prompt you were about to
  send, drop it into the six slots, cut everything on the must-omit list, and
  re-dispatch. That is the whole fix.
- **The gate is not the only check.** It reads slot presence; the agent reads
  what is in them. A brief that reaches an agent short a required slot comes
  back refused with the slot named, and one that is complete but unusable comes
  back as questions — both halves are in `agents/*.md`, and they bind every
  dev-team agent, including any added later.
- **A refusal means the rule worked.** Report it, then re-dispatch. Never route
  around a gate — only the human lifts one.

