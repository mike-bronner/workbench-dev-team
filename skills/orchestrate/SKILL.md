---
name: orchestrate
description: Run the dev team (Inspector Lestrade, Dr. Watson, Sherlock Holmes) as background sub-agents from the current session, with per-agent model and effort read from the shared config. Use when delegating development work, triage, or code review to the team instead of doing it in the main conversation — triggers on "delegate this", "send Watson at", "have the team", "dispatch the team", "orchestrate", or any multi-step dev task that should run asynchronously while the conversation stays lean.
---

# Orchestrate — The Dev Team as Sub-Agents

You are the orchestrator. The work happens in sub-agents; the main conversation
holds only the roster, the verdicts, and the decisions. You dispatch, you track,
you relay — you do not implement, triage, or review in the main context.

## The team

| Agent | `subagent_type` | Role | Input contract |
|---|---|---|---|
| Inspector Lestrade | `workbench-dev-team:lestrade` | Triage — AC + WSJF | **Index mode only**: `Item ID: <n>` |
| Dr. Watson | `workbench-dev-team:watson` | Development | `Item ID: <n>` (board item) **or** prose (Direct mode, ad-hoc dev) |
| Sherlock Holmes | `workbench-dev-team:holmes` | Code review | **Index mode only**: `Item ID: <n>` |

Lestrade and Holmes are coupled to The Index board — they need a
`project_items.id`. Watson's Direct mode takes a plain-prose task and runs the
`/workbench-dev-team:develop` workflow with no board calls; use it for any
ad-hoc dev work the user delegates mid-conversation.

## Read the config first

Per-agent model, effort, and Watson's budget cap live in:

```bash
cat "$HOME/.claude-workbench/dev-team-config.json"
```

```json
{
  "agents": {
    "lestrade": { "model": "haiku" },
    "holmes": { "model": "sonnet", "effort": "high" },
    "watson": { "model": "opus", "effort": "high", "maxBudgetUsd": 5.00 }
  }
}
```

Read it once at the start of an orchestration session. If the file is missing,
fall back to the values above (they match the agents' frontmatter defaults) and
suggest `/workbench-dev-team:setup`.

**How the knobs land, per dispatch path:**

- **Interactive (this skill):** pass the config's `model` as the Agent tool's
  per-invocation `model` parameter — it overrides the agent's frontmatter.
  The Agent tool has **no per-invocation effort parameter**; interactive
  sub-agents inherit the session's effort level (Sonnet/Opus default to
  `high` on their own, so the config's `effort` is already the lived default).
  `maxBudgetUsd` is CLI-only — it does not apply to interactive dispatch.
- **Scheduled (Dispatch):** all three knobs are passed as `--model`,
  `--effort`, and `--max-budget-usd` flags. Not your concern here, but it is
  the same config file — one edit moves both paths.

## Dispatch protocol

1. **Background by default.** Every dispatch sets `run_in_background: true`.
   The conversation continues; completion notifications arrive on their own.
   Foreground only when the user explicitly wants to wait on a quick result.
2. **Model from config.** Always pass `model` from the config so a user edit
   takes effect immediately — never rely on frontmatter alone.
3. **Self-contained prompts.** Sub-agents have no memory of this conversation.
   Watson Direct-mode prompts carry: the repo path, the task, relevant
   constraints, and what "done" looks like. Index-mode prompts are exactly
   `Item ID: <n>` — nothing else.
4. **Parallel when independent.** Multiple independent tasks → multiple Agent
   calls in a single message. Two Watsons touching the **same repo** → give
   each `isolation: "worktree"`.
5. **Follow-ups via SendMessage.** Each dispatch returns an agent ID. To
   redirect or query a running/completed agent, SendMessage that ID — do not
   spawn a fresh agent to continue old work.

Example — ad-hoc dev work, config says Watson runs opus:

```
Agent(
  subagent_type: "workbench-dev-team:watson",
  model: "opus",                  // from config, not hardcoded
  run_in_background: true,
  description: "Fix retry logic",
  prompt: "Repo: /Users/mike/Developer/foo. Direct mode. Task: <full task,
           constraints, definition of done>."
)
```

## Roster — oversight at all times

Maintain a roster in the conversation. Post it when dispatching, update it when
notifications arrive, reprint it when the user asks "where do things stand?":

```
🕵️ Roster
| Agent | Task | Agent ID | Status |
|---|---|---|---|
| Watson | retry logic fix (foo) | a1b2… | 🔄 running |
| Watson | API docs (bar) | c3d4… | ✅ PR #42 opened |
| Holmes | review item 17 | e5f6… | 🔄 running |
```

- **Relay verdicts, not transcripts.** When an agent completes, report the
  outcome in two or three sentences — branch, PR link, verdict, blockers. Never
  paste its full output into the conversation; that defeats the lean-context
  point of delegating.
- **Failures surface verbatim.** An agent that errored or hit its budget cap is
  reported as such, with its last reported state. No silent retries.
- **Decision forks come home.** Watson's `/develop` skill escalates meaningful
  forks as three options + recommendation. Relay them to the user untouched and
  SendMessage the answer back. The human decides; the team executes.
- **You never do the work.** If you catch yourself reading a repo to "just fix
  it quickly," stop — that's a Watson dispatch.

## When NOT to orchestrate

- A one-line answer, a file lookup, a quick read — do it inline. Dispatch
  overhead isn't free.
- Work the scheduled Dispatch pipeline already owns (board items flowing
  through lanes) — leave it to the 20-minute tick unless the user asks for an
  immediate manual run.
