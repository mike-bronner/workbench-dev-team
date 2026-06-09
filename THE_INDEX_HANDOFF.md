# The Index handoff: Dispatch integration

> **✅ COMPLETED — 2026-06-07.** All four tasks shipped to The Index `main`
> (contract fixes in `756f925`; lint hygiene in PR #3 / `4224477`) and verified
> live: `list_unrefined_items` → `Inbox`, `get_item` → `project_fields` +
> `field_changes`, `list_development_items` → In-Progress-first. The sections
> below are retained as the historical spec.
>
> **⚠️ One assumption in this spec was wrong.** The board's WSJF single-selects
> (`Size`, `Business Value`, `Risk Reduction`, `Time Sensitive`) use **word**
> options (`XXS…XXL`, `minimal…great`) — **not** the numeric Fibonacci labels
> assumed under Task 3. Lestrade was corrected to select options by rank
> from `project_fields` and write the option *name*; The Index's `update_fields`
> already matches single-selects by option name, so no server change was needed.

**Audience:** a Claude Code session running in `/Users/mike/Developer/Sites/the-index`.
This is a ready-to-paste prompt describing the MCP contract the `workbench-dev-team`
plugin depends on, and the corrective changes The Index still needs.

Paste everything from `---` down into The Index session. The preamble above
this line is for humans reading the plugin repo.

---

## Context

You implement The Index side of the `workbench-dev-team` dev pipeline. The
plugin repo lives at `github.com/mike-bronner/workbench-dev-team` — read its
`README.md` and `agents/*.md` for the agent design. Your job is the Laravel /
Passport side.

The architecture: a local scheduled Claude Code task called **Dispatch** runs
every 20–30 minutes on the user's machine. It polls The Index through three MCP
tools for pending work in each of three lanes, then fires the matching subagent
(Lestrade, Watson, Holmes) as a detached subprocess. **All filter / sort
logic lives on The Index's side** — Dispatch is a thin router. There is no
`/fire` endpoint, no trigger registration, no webhook-driven dispatcher (we moved
off cloud routines because of the 15-runs/day online cap).

**The server already exists and works.** This handoff is a *corrective pass*: the
tool contract below is the source of truth, and four behaviors currently diverge
from it (Tasks 1–4). It is a tightening pass, not a rewrite.

## MCP tool surface (the contract — target behavior)

This is the typed interface the plugin relies on. Tool names must match exactly.

### Dispatch-facing (read, scope `index.mcp.read`)

| Tool | Behavior |
|---|---|
| `list_unrefined_items(limit?)` | Items in the triage intake lane: `status = 'Inbox'`. Sort by creation order (oldest first). **(Task 1 — ✅ shipped.)** |
| `list_review_items(limit?)` | Items where `status = 'In Review'`. Sort by creation order. |
| `list_development_items(limit=1)` | Items where `status IN ('In Progress', 'Ready')`, **In Progress first**, then Ready, then priority/WSJF desc. Excludes PR-type items and items with open `blockedByIssues`; live-enriches priority + blockers via GraphQL. Honors `limit` (Dispatch calls `limit=1`). **(Task 2 — ✅ shipped.)** |

### Agent-facing (read, scope `index.mcp.read`)

| Tool | Behavior |
|---|---|
| `get_item(id)` | Full item state: `id`, `repo`, `issue_number`, `title`, `status`, `content_node_id`, **`project_fields`** (field catalog with option IDs for each triage single-select), **`field_changes`** (audit trail). **(Task 3 — ✅ shipped.)** |

### Agent-facing (write, scope `index.mcp.write`)

| Tool | Behavior |
|---|---|
| `move(id, column)` | Transition project-board status. Valid targets: `Inbox`, `Backlog`, `Ready`, `In Progress`, `In Review`, `Approved`, `Escalated`, `Done`. Maps to GH GraphQL. |
| `add_comment(id, body)` | Comment on the underlying GitHub issue. Used by Holmes for escalation pings. |
| `update_fields(id, { size?, bv?, rr?, ts?, estimate?, priority?, acceptance_criteria? })` | Bulk-update project-board fields. Numeric values map back to option IDs per single-select. |

### Generic (debug / future callers, scope `index.mcp.read`)

| Tool | Behavior |
|---|---|
| `list_items(status?, labels?, limit?)` | Generic filter. Not used by Dispatch; handy for debugging. |

## Ground truth observed from the plugin side (2026-06-07)

So you don't have to rediscover it:

- The board's **Status** single-select, in order:
  `Inbox (cbd7979f) → Backlog (f75ad846) → Ready (61e4505c) → In Progress (47fc9ee4) → In Review (df73e18b) → Approved (a2a5a03d) → Escalated (63246415) → Done (98236657)`.
- **`Inbox` is the triage intake lane.** The board's "Item added to project"
  workflow sets new items to `Inbox`. There are currently items in `Inbox` and
  **0 items with `status IS NULL`** — nothing sits at null anymore.
- `list_unrefined_items()` returned **0** at the time of writing because it
  filtered on `status IS NULL` (Task 1). ✅ Now filters `Inbox`.
- `get_item(id)` returned **neither `project_fields` nor `field_changes`** at the
  time of writing — blocking Lestrade's WSJF scoring (Task 3). ✅ Now returns
  both.

## Codebase map (observed 2026-06-07 — verify before trusting)

A read-only pass found the relevant code here:

- **MCP framework:** `laravel/mcp` v0. Tools are classes in `app/Mcp/Tools/` with
  `#[Name(...)]` / `#[Description(...)]` attributes, registered in the `$tools`
  array of `app/Mcp/Servers/TheIndexServer.php`, routed in `routes/ai.php`
  behind `EnsureMcpAccess:index.mcp.read`.
- **The three tools to change:** `ListUnrefinedItemsTool.php`,
  `ListDevelopmentItemsTool.php`, `GetItemTool.php` — all in `app/Mcp/Tools/`.
- **Shared query builder:** `app/Actions/BuildProjectItemQueryAction.php`
  (`applyStatusFilter`, `applyIssuesOnlyFilter`).
- **Shared payload builder:** `app/Mcp/Support/ProjectItemFormatter.php::format()`
  — used by **all** list tools *and* `get_item`. ⚠️ See the Task 3 caveat.
- **Model:** `app/Models/ProjectItem.php`. `meta` is cast to `array` and holds
  `field_changes` (there is **no** `FieldChange` model/table — the audit trail
  lives in `meta['field_changes']`).
- **Field/option catalog:** `app/Services/GitHubAppService.php::getProjectFields($projectNodeId)`
  already exists — live GraphQL, Redis-cached 15 min, returns
  `{ id, name, options: [{ id, name }] }`. `UpdateFieldsTool` already uses it for
  reverse option-ID mapping. This is the source for Task 3's `project_fields`.
- **Tests:** Pest v4, `LazilyRefreshDatabase`. Per-tool tests exist under
  `tests/Feature/Mcp/`. `database/factories/ProjectItemFactory.php` has `issue()`,
  `pullRequest()`, `withStatus()` states.

## Task 1 — Re-point the triage lane to `Inbox`

`list_unrefined_items()` must select `status = 'Inbox'` instead of `status IS NULL`.

The audit predicate the early design mentioned ("only Status field_changes") was
never implemented — `ListUnrefinedItemsTool` filters on status alone (it passes
`["status" => "null"]` to `BuildProjectItemQueryAction`). So this is purely a
status-value change:

- In `ListUnrefinedItemsTool::handle()`, change the status filter from `"null"`
  to `"Inbox"`.
- Update the MCP tool `#[Description]` — it currently says "status is null"; it
  must say it returns items in `Inbox` awaiting triage. Agents and Dispatch read
  these descriptions; drift here is a silent breakage.
- No data migration needed (0 null-status rows exist), but confirm.
- Tests: update `ListUnrefinedItemsToolTest` to assert `Inbox` items are returned
  and every other status (including null) is excluded.

## Task 2 — `list_development_items`: restore the resume path

Currently returns `status = 'Ready'` only. Watson's crash-recovery path depends on
`In Progress` items coming back first — when Watson hits its budget cap or a test
failure mid-run it leaves the item `In Progress`, and the next Dispatch tick never
sees it again.

**The PR filter is already correct — don't touch it.** The `issues_only` filter is
`whereNotNull('issue_number')`, which excludes PR-*type* project items (e.g.
Dependabot PRs) while keeping any issue — including an in-flight `In Progress`
issue that has Watson's draft PR (issues always have `issue_number`). The resume bug
is **only** the status filter.

Changes:

- In `ListDevelopmentItemsTool::handle()`, widen the status filter from `"Ready"`
  to `["In Progress", "Ready"]` (the model's `withStatus` scope already accepts an
  array).
- In the post-enrichment sort, add a **primary** key so `In Progress` orders
  before `Ready`, priority desc **within** each group. (Today the sort is
  priority-only.)
- Keep the blocker exclusion, GraphQL enrichment, and `limit` exactly as they are.
- Update the `#[Description]`.
- Tests: extend `ListDevelopmentItemsToolTest` for (a) In-Progress returned before
  Ready, (b) an In-Progress issue with a draft PR is still returned, (c) the
  existing PR-type-exclusion / blocker / `limit` tests still pass.

## Task 3 — `get_item` must return `project_fields` and `field_changes` (blocking)

`get_item` returns neither today. Without `project_fields`, Lestrade's scoring
step has no option catalog to size its Fibonacci sequence against and no option IDs
to write back through `update_fields`.

⚠️ **Add these in `GetItemTool`, NOT in the shared `ProjectItemFormatter`.** The
formatter feeds every `list_*` tool too — adding `project_fields` there would fire
a GraphQL call per item on every list call (a real perf regression), and the list
tools don't need it. Format the item as today, then **merge** the two extra keys
into the payload inside `GetItemTool::handle()`.

- **`project_fields`** — sourced from
  `GitHubAppService::getProjectFields($item->project_node_id)` (already exists,
  Redis-cached). For every triage single-select (`Status`, `Size`,
  `Business Value`, `Risk Reduction`, `Time Sensitive`, `Estimate`, `Priority`) it
  returns the field's id/name and its ordered options as `{ id, name }`. Where an
  option `name` is a numeric label (the WSJF Fibonacci values), that's what
  Lestrade counts and selects and what `update_fields` maps a numeric back to.
  Inject `GitHubAppService` (constructor property promotion).
- **`field_changes`** — read from `$item->meta['field_changes'] ?? []`. Not
  load-bearing, but `get_item` is the agent's single fetch and the contract
  promises it.

Confirm the `update_fields` ↔ `get_item` option-ID round-trip (a numeric Lestrade
derives → option id written → reads back as the same option) and add a test for it.

- Tests: assert `get_item` includes `project_fields` (options for every triage
  single-select) and `field_changes`; assert the round-trip on at least one
  single-select.

## Task 4 — Lock the contract with a test

Add (or extend) an integration test asserting the MCP server exposes exactly the
tool names in the surface table above — and the **shapes** the plugin depends on:

- Tool-name set is exactly as documented (no drift, no extras).
- `get_item` returns `project_fields` (with options) and `field_changes`.
- `list_unrefined_items` filters on `Inbox`.
- `list_development_items` returns In-Progress-first.

Treat this as the typed interface between The Index and the plugin. If it's red,
the plugin breaks silently in production.

## Acceptance criteria

- [x] `list_unrefined_items` returns `status = 'Inbox'` items; description updated.
- [x] `list_development_items` returns `In Progress` first then `Ready`; in-progress issues with Watson draft PRs are returned; PR-type items excluded; blockers excluded; `limit` honored.
- [x] `get_item` returns `project_fields` (options for every triage single-select) and `field_changes`.
- [x] `update_fields` ↔ `get_item` option-ID round-trip verified by test.
- [x] Contract test asserts the exact tool names **and** the shapes above.
- [x] All access through Eloquent models; OAuth scopes (`index.mcp.read` / `index.mcp.write`) intact; full Pest suite green.
- [x] The Index README / docs reflect the `Inbox` lane and the corrected `list_development_items` semantics.

## Constraints

- **Follow The Index's `CLAUDE.md`** for all Laravel conventions (test framework, layout, naming).
- **No raw DB access.** Models / scopes only — every query goes through the model.
- **No regressions.** The existing tools must keep working; this tightens four behaviors.
- **Plan before code.** Produce a plan — particularly for Tasks 2 and 3, where current semantics must be read out of the existing tools first — and surface it for review before implementing.

## Optional, deferred — dispatch audit table

Not required for this pass. If you later want a clean "what happened to item #N"
query surface (the per-dispatch agent logs are currently the only record), add a
`dispatch_invocations` table + model (`agent`, `item_id`, `invoked_at`,
`completed_at`, `outcome`, `notes`) and a `record_dispatch(agent, item_id, event, notes?)`
write tool the agents call at start/completion/failure. Ship model + migration +
tests together if you do. Track it as a separate issue, not part of the corrective pass.
