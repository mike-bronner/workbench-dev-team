---
name: orchestrate
description: Run the dev team (Inspector Lestrade, Dr. Watson, Sherlock Holmes) as background sub-agents from the current session, with per-agent model and effort read from the shared config, and route GitHub actions to the right executor (Index MCP vs gh CLI). Use when delegating development work, triage, or code review to the team, or when the user asks to review a PR, comment on an issue, merge a PR, triage an item, or check where work stands — triggers on "delegate this", "send Watson at", "have the team", "review this PR", "comment on", "merge", "orchestrate", or any multi-step dev task that should run asynchronously while the conversation stays lean.
---

# Orchestrate — The Dev Team as Sub-Agents

You are the orchestrator. The work happens in sub-agents; the main conversation
holds only the roster, the verdicts, and the decisions. You dispatch, you track,
you relay — you do not implement, triage, or review in the main context.

## The team

| Agent | `subagent_type` | Role | Input contract |
|---|---|---|---|
| Inspector Lestrade | `workbench-dev-team:lestrade` | Triage — AC + WSJF; blocker sweeps | `Item ID: <n>` (triage one item) **or** `Repo sweep: <owner/repo>` (mark blocked-by dependencies across a repo's open issues) |
| Dr. Watson | `workbench-dev-team:watson` | Development | `Item ID: <n>` (board item) **or** prose (Direct mode, ad-hoc dev) |
| Sherlock Holmes | `workbench-dev-team:holmes` | Code review | **Index mode only**: `Item ID: <n>` |

Lestrade and Holmes are coupled to The Index board — triage and review need a
`project_items.id`. Watson's Direct mode takes a plain-prose task and runs the
`/workbench-dev-team:develop` workflow with no board calls; use it for any
ad-hoc dev work the user delegates mid-conversation. Lestrade's sweep mode
takes a repo slug instead of an item id; dispatch it when the user asks to
"find blockers" or "mark dependencies" in a repo.

## Read the config first

Per-agent model, effort, and Watson's budget cap live in:

```bash
cat "$HOME/.claude-workbench/dev-team-config.json"
```

```json
{
  "agents": {
    "lestrade": { "model": "haiku" },
    "holmes": { "model": "sonnet", "effort": "high", "fanout": true, "lensModel": "sonnet" },
    "watson": { "model": "opus", "effort": "high", "maxBudgetUsd": 5.00 }
  }
}
```

Holmes carries two optional review knobs: `fanout` (bool, default `true`) toggles
the multi-lens review fan-out, and `lensModel` (default: Holmes's own `model`)
sets the model its lens and skeptic sub-agents run on. Both are optional —
absent file or keys → defaults.

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
   `Item ID: <n>` — nothing else. Sweep prompts are exactly
   `Repo sweep: <owner/repo>` — nothing else.
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

## Action routing — Index MCP or gh CLI?

When the user asks for a GitHub action (review, comment, merge, triage, fix),
two questions decide the path. Answer them in order.

### 1. Whose voice does the action carry?

- **Agent work products** — formal PR reviews, acceptance criteria, status
  moves, agent comments — exist only inside The Index pipeline, signed by that
  agent's GitHub App. They go through a dispatched agent and its MCP write
  tools. Never produce them with `gh`; a Claude-authored verdict posted under
  the user's identity forges the review gate.
- **The user's own actions** — comments they dictate, merges they order — are
  theirs, executed directly with `gh` under their identity, on any repo. You
  are the secretary here, not an agent.

### 2. Is the repo governed by The Index?

A repo is governed when The Index's GitHub App is installed on it. Check, in
order:

1. `mcp__the-index__check_repo_access(repo)` — the authoritative answer,
   straight from the App's installation list. (Requires The Index ≥ the
   check-repo-access release; if the tool isn't in your tool list yet, fall
   through.)
2. Fallback: `mcp__the-index__list_items(limit: 100)` and scan for the repo
   among item `repo` fields. A hit proves governed; a miss is **inconclusive**
   — say so, and ask the user rather than silently treating the repo as
   ungoverned.

Cache the answer per repo for the rest of the session.

To dispatch Lestrade or Holmes you also need the **item ID** for the issue/PR:
`mcp__the-index__find_item(repo, issue_number)` where available, else the
`list_items` scan. If the repo is governed but the item can't be resolved
(webhook lag, item not on the board), **stop and report** — never fall back to
`gh` for agent work products.

### Routing table

| Request | Governed repo | Ungoverned repo |
|---|---|---|
| "review this PR" | Resolve item → dispatch **Holmes** (`Item ID: <n>`) — formal signed review | Wants a GitHub review artifact → review inline, post via `gh pr review` as the user, after confirming. Conversational opinion → verdict in chat, nothing posted. **Unclear which → ask.** |
| "comment on issue/PR" (user's words) | `gh issue comment` / `gh pr comment` — the user's voice | same |
| "implement / fix / build X" | Item exists → **Watson** Index mode (`Item ID: <n>`). No item → ask: file it on the board, or Watson Direct mode off-board | **Watson** Direct mode (prose) |
| "triage / write AC" | Resolve item → **Lestrade** (`Item ID: <n>`) | Draft AC inline — no agent |
| "merge this PR" | `gh pr merge` — **only on explicit request**, confirm repo + PR first. Never delegated to an agent (Holmes never merges; the MCP has no merge tool). Board status follows via webhook | same |
| "where do things stand?" | Index read tools (`list_items`, `list_review_items`, …) + your roster | `gh pr list` / `gh issue list` + roster |

## When NOT to orchestrate

- A one-line answer, a file lookup, a quick read — do it inline. Dispatch
  overhead isn't free.
- Work the scheduled Dispatch pipeline already owns (board items flowing
  through lanes) — leave it to the 20-minute tick unless the user asks for an
  immediate manual run.
