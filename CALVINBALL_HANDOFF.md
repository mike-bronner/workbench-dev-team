# Calvinball handoff: Dispatch integration

**Audience:** a Claude Code session running in `/Users/mike/Developer/Sites/calvinball`. This document is a ready-to-paste prompt describing what Calvinball needs to serve as the work queue for the `workbench-dev-team` plugin's local orchestrator (Dispatch).

Paste everything from `---` down into the Claude Code session. The preamble above this line is for humans reading the plugin repo.

---

## Context

You are implementing the Calvinball side of the `workbench-dev-team` dev pipeline. The plugin repo lives at `github.com/mike-bronner/workbench-dev-team` — read `README.md` and `agents/*.md` in that repo for the agent design. Your job here is the Laravel / Passport side.

The architecture: a local scheduled Claude Code task called **Dispatch** runs every 20–30 minutes on the user's machine. It polls Calvinball through three MCP tools for pending work in each of three lanes, then fires the matching subagent (Miss Wormwood, Moe, Tracer Bullet) as a detached subprocess. All filter / sort logic lives on Calvinball's side — Dispatch is a thin router.

Calvinball needs to:

1. Serve the six MCP tools the agents and Dispatch use (most already exist — verify and tighten).
2. Represent every table with an Eloquent model; all data access goes through models, never `DB::table(...)`.
3. Use Laravel's Passport client-credentials grant for MCP auth with scopes `calvinball.mcp.read` and `calvinball.mcp.write`.

There is **no `/fire` endpoint, no trigger registration, no fire-token storage, no webhook-driven dispatcher** — the earlier design called for those but we moved away from cloud routines because of the 15-runs/day online cap.

## MCP tool surface (the complete list)

### Dispatch-facing (read, scoped: `calvinball.mcp.read`)

| Tool | Behavior |
|---|---|
| `list_unrefined_items()` | Returns items where `status IS NULL` AND the project-item's `field_changes` audit shows only Status changes (i.e., never been triaged). Sort by creation order. |
| `list_review_items()` | Returns items where `status = 'In Review'`. Sort by creation order. |
| `list_development_items(limit=1)` | Returns at most `limit` items where `status IN ('In Progress', 'Ready')`. **In Progress first**, then Ready, then priority/WSJF descending. The orchestrator calls with `limit=1` (single-track Moe) — server must honor it. |

### Agent-facing (read, scoped: `calvinball.mcp.read`)

| Tool | Behavior |
|---|---|
| `get_item(id)` | Returns full item state: `id`, `repo`, `issue_number`, `title`, `status`, `content_node_id`, `field_changes`, `project_fields` (field catalog with option IDs for single-selects like Size, BV, RR, TS, Estimate, Priority). |

### Agent-facing (write, scoped: `calvinball.mcp.write`)

| Tool | Behavior |
|---|---|
| `move(id, column)` | Transition the project-board status. Valid targets: `Backlog`, `Ready`, `In Progress`, `In Review`, `Approved`, `Escalated`. Server maps to GH GraphQL. |
| `add_comment(id, body)` | Add a comment to the underlying GitHub issue. Used by Tracer Bullet for escalation pings. |
| `update_fields(id, { size?, bv?, rr?, ts?, estimate?, priority?, acceptance_criteria? })` | Bulk update project-board fields. Numeric values are mapped back to option IDs for each single-select. |

### Generic (debug / Hobbes / future callers, scoped: `calvinball.mcp.read`)

| Tool | Behavior |
|---|---|
| `list_items(status?, labels?, limit?)` | Generic filter — same shape as the legacy `/api/project-items`. Not used by Dispatch but handy for Hobbes queries and debugging. |

## Task 1 — Verify / shore up existing MCP tools

Most of these already exist from earlier work. For each tool above:

1. Read the current controller / action that backs it.
2. Confirm the behavior matches the table. Pay particular attention to:
   - `list_unrefined_items` — the "only Status field changes" predicate. This is the subtle one: an item that got triaged once and had its Status reset to null should NOT return here (it already has AC written, so a second triage would clobber them).
   - `list_development_items` — the sort order (In Progress first, then Ready, then priority). If that's wrong, Moe resume won't work.
3. Confirm every tool goes through an Eloquent model. If any use `DB::table(...)` or raw queries, refactor to models now.
4. Confirm OAuth scopes are enforced on each tool (read vs write).
5. Run the MCP test suite. Add missing tests for the three `list_*` tools if they don't exist.

## Task 2 — Eloquent models for all tables

List every table involved in the dev pipeline side of Calvinball. For each:

1. Verify an Eloquent model exists.
2. Verify services, controllers, MCP handlers, and console commands interact via the model (no `DB::table()` or `\DB::select()` shortcuts).
3. Define relationships explicitly (e.g., `ProjectItem hasMany FieldChange`, `Repo hasMany ProjectItems`).
4. Use query scopes for common filters (`->unrefined()`, `->inReview()`, `->readyOrInProgress()`).
5. Factories + seeders exist for every model (used by feature tests).

If any model is missing or thin, create / flesh it out. A table without a model is a bug in this codebase.

## Task 3 — No drift in the contract

The `workbench-dev-team` plugin expects the tools to be named exactly as in the tables above (`list_unrefined_items`, not `list-unrefined-items-tool` or similar). If any server-side names drift, the plugin breaks silently.

Write a single integration test (in Calvinball's test suite) that asserts the MCP server exposes exactly these tool names and no others. This is the contract with the plugin; treat it as a typed interface.

## Task 4 — Optional: audit table for dispatch visibility

**Optional but recommended.** Add a `dispatch_invocations` table + Eloquent model to record every time an agent was dispatched and what happened:

| column | type |
|---|---|
| `id` | bigint pk |
| `agent` | string(64), indexed — `miss-wormwood` / `moe` / `tracer-bullet` |
| `item_id` | string or int, indexed |
| `invoked_at` | timestamp |
| `completed_at` | timestamp nullable |
| `outcome` | enum: `started`, `completed`, `failed`, `skipped` |
| `notes` | text nullable |

Expose `mcp__calvinball__record_dispatch(agent, item_id, event, notes?)` as a write tool. Agents call it at key points (start, completion, failure). This gives Hobbes a clean query surface for "what happened to item #N" without scraping log files.

If you do this, model + migration + feature tests all ship together. The plugin's agent definitions can be updated in a follow-up to call the new tool — not required for initial parity.

## Task 5 — Configuration

No new env vars needed for the core architecture. If you implement Task 4, add:

```php
'dispatch' => [
    'audit_enabled' => env('DISPATCH_AUDIT_ENABLED', true),
    'retention_days' => env('DISPATCH_AUDIT_RETENTION_DAYS', 30),
],
```

Document the env vars in `.env.example`.

## Task 6 — Documentation

Update Calvinball's README / `docs/` with:

- A short "Dispatch integration" section referring to the plugin repo.
- A list of the six (or seven, with audit) MCP tools the plugin relies on.
- A note that `/api/project-items` still exists for legacy / debug queries but is not the dispatch path — Dispatch uses the MCP tools exclusively.

## Acceptance criteria (self-check before marking done)

- [ ] All six MCP tools exist, named exactly as specified, behavior matches the tables.
- [ ] Every involved database table has an Eloquent model; no raw-DB access remains in the dev-team code paths.
- [ ] OAuth scopes (`calvinball.mcp.read` / `calvinball.mcp.write`) correctly gate each tool.
- [ ] Integration test asserts the exact MCP tool-name contract.
- [ ] (Optional) `dispatch_invocations` table + model + `record_dispatch` tool shipped, with tests.
- [ ] MCP test suite green.
- [ ] README / docs section added.

## Constraints

- **Follow Calvinball's existing CLAUDE.md** for all Laravel conventions (testing framework, directory layout, naming).
- **No raw DB access.** Every table has a model; every query goes through the model or a repository built on the model.
- **No regressions.** Run the full test suite after every change. The existing MCP tools must continue to work — this is a tightening pass, not a rewrite.
- **Before writing any code, produce a plan.** I want to review the plan — particularly Tasks 1 and 2 — before implementation begins. Surface anywhere you find `DB::table()` or raw-query shortcuts so I can see the scope of the model refactor.
