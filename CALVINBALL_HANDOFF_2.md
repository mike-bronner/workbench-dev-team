# Calvinball handoff 2: Inbox lane + contract corrections

**Audience:** a Claude Code session running in `/Users/mike/Developer/Sites/calvinball`.
This is a ready-to-paste prompt describing a **corrective pass** on the MCP
contract the `workbench-dev-team` plugin depends on. It supersedes the relevant
rows of the original [`CALVINBALL_HANDOFF.md`](./CALVINBALL_HANDOFF.md) — read
that first for the broader architecture (Eloquent-only data access, Passport
scopes, the full tool list). This document only covers what must *change*.

Paste everything from `---` down into the Calvinball session. The preamble above
this line is for humans reading the plugin repo.

---

## Context

You implemented the Calvinball side of the `workbench-dev-team` dev pipeline per
`CALVINBALL_HANDOFF.md`. Since then, the plugin owner reconfigured the GitHub
Projects board ("The Transmogrifier", `PVT_kwDOEA1bdM4BTeiF`) and we discovered
three places where the live MCP contract diverges from what the agents need.
This is a **tightening pass, not a rewrite** — the existing tools work; three of
them behave wrong at the edges and one is missing data the agents require.

All constraints from the original handoff still apply: every table has an
Eloquent model, no `DB::table()` / raw queries in these code paths, OAuth scopes
(`calvinball.mcp.read` / `calvinball.mcp.write`) gate every tool, no regressions,
run the full suite after every change, and **produce a plan for review before
writing code**.

## Ground truth observed from the plugin side (2026-06-07)

So you don't have to rediscover it:

- The board's **Status** single-select now has, in order:
  `Inbox (cbd7979f) → Backlog (f75ad846) → Ready (61e4505c) → In Progress (47fc9ee4) → In Review (df73e18b) → Approved (a2a5a03d) → Escalated (63246415) → Done (98236657)`.
- **`Inbox` is the new triage intake lane.** The board's "Item added to project"
  workflow now sets new items to `Inbox`. There are currently **4 items in
  `Inbox`** and **0 items with `status IS NULL`** — nothing ever sits at null
  anymore.
- `mcp__calvinball__list_unrefined_items()` currently returns **0** because it
  still filters on `status IS NULL`. That's Task 1.
- `mcp__calvinball__get_item(id)` currently returns **neither `project_fields`
  nor `field_changes`** — verified against multiple items that have field data
  and history. That's Task 3, and it's blocking: Miss Wormwood cannot score WSJF
  without `project_fields`.

## Codebase map (observed 2026-06-07 — verify before trusting)

A read-only pass over your repo found the relevant code at these paths. Confirm
they're still accurate, but this should save you rediscovery:

- **MCP framework:** `laravel/mcp` v0. Tools are classes in `app/Mcp/Tools/`
  with `#[Name(...)]` / `#[Description(...)]` attributes, registered in the
  `$tools` array of `app/Mcp/Servers/CalvinballServer.php`, routed in
  `routes/ai.php` behind `EnsureMcpAccess:calvinball.mcp.read`.
- **The three tools:** `ListUnrefinedItemsTool.php`, `ListDevelopmentItemsTool.php`,
  `GetItemTool.php` — all in `app/Mcp/Tools/`.
- **Shared query builder:** `app/Actions/BuildProjectItemQueryAction.php`
  (`applyStatusFilter`, `applyIssuesOnlyFilter`).
- **Shared payload builder:** `app/Mcp/Support/ProjectItemFormatter.php::format()`
  — used by **all** the list tools *and* `get_item`. ⚠️ See the Task 3 caveat.
- **Model:** `app/Models/ProjectItem.php`. `meta` is cast to `array` and holds
  `field_changes` (there is **no** `FieldChange` model/table — the audit trail
  lives in `meta['field_changes']`).
- **Field/option catalog:** `app/Services/GitHubAppService.php::getProjectFields($projectNodeId)`
  already exists — live GraphQL, Redis-cached 15 min, returns
  `{ id, name, options: [{ id, name }] }`. `UpdateFieldsTool` already uses it for
  the reverse option-ID mapping. This is the source for Task 3's `project_fields`.
- **Tests:** Pest v4, `LazilyRefreshDatabase`. Per-tool tests already exist under
  `tests/Feature/Mcp/`. `database/factories/ProjectItemFactory.php` has
  `issue()`, `pullRequest()`, `withStatus()` states.

## Task 1 — Re-point the triage lane to `Inbox`

`list_unrefined_items()` must select the new intake lane.

| | Current | Required |
|---|---|---|
| Predicate | `status IS NULL` **AND** field_changes audit shows only Status changes | `status = 'Inbox'` |
| Sort | creation order | creation order (oldest first) — unchanged |
| `limit` | honored | honored — unchanged |

**The audit predicate from handoff 1 was never implemented** — `ListUnrefinedItemsTool`
filters on status alone (it passes `["status" => "null"]` to
`BuildProjectItemQueryAction`). There is no `->unrefined()` scope and no
`field_changes` inspection to remove. So this is purely a status-value change:

- In `ListUnrefinedItemsTool::handle()`, change the status filter passed to the
  query action from `"null"` to `"Inbox"`.
- Update the **MCP tool `#[Description]`** — it currently says "status is null".
  It must say it returns items in `Inbox` awaiting triage. The agents and
  Dispatch read these descriptions; drift here is a silent breakage.
- No data migration needed (0 null-status rows exist), but confirm.
- Tests: update `ListUnrefinedItemsToolTest` so it asserts `Inbox` items are
  returned and every other status (including null) is excluded.

## Task 2 — `list_development_items`: restore the resume path (Fork C1)

This tool currently returns `status = 'Ready'` only. Moe's documented
crash-recovery path depends on `In Progress` items coming back first, and that
path is dead today: when Moe hits its budget cap or a test failure mid-run, it
leaves the item in `In Progress`, and the next Dispatch tick never sees it again.

| | Current | Required |
|---|---|---|
| Status filter | `Ready` only | `status IN ('In Progress', 'Ready')` |
| Order | priority desc | **`In Progress` first**, then `Ready`; within each, priority/WSJF desc |
| Blocker filter | excludes open `blockedByIssues` | unchanged — keep it |
| GraphQL enrich | live priority + blocker | unchanged — keep it |
| `limit` | honored (Dispatch calls `limit=1`) | unchanged |

**The PR filter is already correct — don't touch it.** The current `issues_only`
filter is `whereNotNull('issue_number')`, which excludes PR-*type* project items
(e.g. Dependabot PRs) while keeping any issue — including an in-flight
`In Progress` issue that has Moe's draft PR (issues always have `issue_number`).
That's exactly right; the resume bug is **only** the status filter. Moe opens a
draft PR on the first commit of every fresh run, so an in-flight issue always has
an associated PR — but since the filter keys on `issue_number`, not PR
association, that issue is still returned. Leave `issues_only` as is.

The actual changes:

- In `ListDevelopmentItemsTool::handle()`, widen the status filter from `"Ready"`
  to `["In Progress", "Ready"]` (the model's `withStatus` scope already accepts
  an array).
- In the post-enrichment sort, add a **primary** key so `In Progress` orders
  before `Ready`, with priority descending **within** each status group. (Today
  the sort is priority-only.)
- Keep the blocker exclusion, the GraphQL enrichment, and `limit` exactly as they
  are.
- Update the `#[Description]`.
- Tests: extend `ListDevelopmentItemsToolTest` for (a) In-Progress returned before
  Ready, (b) an In-Progress issue with a draft PR is still returned, (c) the
  existing PR-type-exclusion / blocker / `limit` tests still pass.

## Task 3 — `get_item` must return `project_fields` and `field_changes` (blocking)

The original handoff promised `get_item(id)` returns full item state including
`project_fields` (the field catalog with option IDs for each single-select) and
`field_changes`. **It returns neither today.** Without `project_fields`, Miss
Wormwood's scoring step has no option catalog to size its Fibonacci sequence
against and no option IDs to write back through `update_fields`.

⚠️ **Add these in `GetItemTool`, NOT in the shared `ProjectItemFormatter`.** The
formatter feeds every `list_*` tool too — adding `project_fields` there would
fire a GraphQL call per item on every list call (a real perf regression), and
the list tools don't need it. Format the item as today, then **merge** the two
extra keys into the payload inside `GetItemTool::handle()`.

`get_item(id)` must return, in addition to the fields it returns today
(`id`, `repo`, `issue_number`, `title`, `status`, `content_node_id`, etc.):

- **`project_fields`** — the field catalog, sourced from
  `GitHubAppService::getProjectFields($item->project_node_id)` (already exists,
  Redis-cached). For every single-select used in triage (`Status`, `Size`,
  `Business Value`, `Risk Reduction`, `Time Sensitive`, `Estimate`, `Priority`),
  it returns the field's id/name and its full ordered list of options as
  `{ id, name }`. Where an option's `name` is a numeric label (the WSJF Fibonacci
  values), that's what Wormwood counts and selects, and what `update_fields` maps
  a numeric back to. This is the load-bearing addition. Inject `GitHubAppService`
  into the tool (constructor property promotion).
- **`field_changes`** — the audit trail, read from `$item->meta['field_changes']
  ?? []` (there's no `FieldChange` model — it lives in the `meta` JSON). Not
  load-bearing now, but `get_item` is the agent's single fetch and the contract
  promised it. Include it.

Confirm `update_fields(id, {...})` and `get_item` agree on the option-ID mapping
(round-trip: a numeric Wormwood derives → option id written → reads back as the
same option). Add a test for that round-trip.

- Tests: assert `get_item` payload includes `project_fields` with options for
  every triage single-select, and `field_changes`. Assert the `update_fields` ↔
  `get_item` round-trip on at least one single-select.

## Task 4 — Lock the contract with a test

Extend (or add) the integration test that asserts the MCP server exposes exactly
the expected tool names — and now also asserts the **shape** the plugin depends
on:

- The tool-name set is exactly as documented (no drift, no extras).
- `get_item` returns `project_fields` (with options) and `field_changes`.
- `list_unrefined_items` filters on `Inbox`.
- `list_development_items` returns In-Progress-first.

Treat this as the typed interface between Calvinball and the plugin. If it's
red, the plugin breaks silently in production.

## Acceptance criteria (self-check before marking done)

- [ ] `list_unrefined_items` returns `status = 'Inbox'` items; audit predicate removed; description string updated.
- [ ] `list_development_items` returns `In Progress` first then `Ready`; in-progress issues with Moe draft PRs are returned; PR-type items excluded; blockers excluded; `limit` honored.
- [ ] `get_item` returns `project_fields` (options for every triage single-select) and `field_changes`.
- [ ] `update_fields` ↔ `get_item` option-ID round-trip verified by test.
- [ ] Contract/integration test asserts tool names **and** the shapes above.
- [ ] All access through Eloquent models; OAuth scopes intact; full suite green.
- [ ] Calvinball README / docs updated to reflect the `Inbox` lane and the corrected `list_development_items` semantics.

## Constraints

- **Follow Calvinball's `CLAUDE.md`** for all Laravel conventions.
- **No raw DB access.** Models / scopes only, as in the original handoff.
- **No regressions.** The existing tools must keep working — this tightens four
  behaviors, it doesn't rewrite the server.
- **Plan before code.** Produce a plan — particularly for Tasks 2 and 3, where
  current semantics need to be read out of the existing controllers first — and
  surface it for review before implementing.
