# The Index handoff: native issue Type + issue-level Priority

> **⏳ PENDING.** Extends `update_fields` so a triage write also lands two
> **GitHub-native** issue attributes the project board can't hold: the issue
> **Type** (auto-stamped `PBI`, overridable) and an issue-level **Priority**
> single-select (`Urgent/High/Medium/Low`) **derived from the WSJF** the agent
> already writes to the project `Priority` NUMBER field. Lestrade's prompt does
> **not** change for Priority — the server fans the existing WSJF write out to
> the issue. Both writes are org-only and best-effort.

**Audience:** a Claude Code session running in `/Users/mike/Developer/Sites/the-index`.
Paste everything from `---` down into The Index session. The preamble above
this line is for humans reading the plugin repo.

---

## Context

The `workbench-dev-team` plugin (github.com/mike-bronner/workbench-dev-team)
triages project items through Inspector Lestrade. Today Lestrade scores WSJF and
calls `update_fields(id, agent, { Size, "Business Value", "Risk Reduction",
"Time Sensitive", Estimate, Priority })` — all **ProjectV2** board fields. The
board's `Priority` is a NUMBER holding the raw WSJF.

GitHub now hangs two attributes off the **issue itself** that the board can't
represent, and the human wants both populated during triage:

1. **Native issue Type** — owner-level (`Bug/Feature/Task`-style). On this
   account the configured types are `PBI`, `Acceptance Criteria`, `Product
   Goal`. The sidebar's "Type" control.
2. **Issue-level `Priority`** — a repo-level *issue field* (the sidebar's
   "Fields → Priority"), options `Urgent / High / Medium / Low`. Distinct from
   the project `Priority` NUMBER — same word, different subsystem, different UI.

Neither is a ProjectV2 field, so neither is reachable through the current
`update_fields` GraphQL path. This handoff adds them.

**Design decisions already made (do not relitigate):**

- The issue-level Priority is **never named by the caller.** The server
  **derives** it from the WSJF whenever `update_fields` writes the `Priority`
  NUMBER. One source of truth for the mapping; the two Priorities can't drift.
- The issue Type **auto-stamps `PBI`** when the issue has no type yet, but is
  **overridable** by passing an explicit `Type` to `update_fields`.
- Both are **org-only** (see ground truth) and **best-effort** (see semantics).

## Ground truth observed from the plugin side (2026-06-13 — verify before trusting)

- **Issue types are an Organization feature.** `mike-bronner` is an
  **Organization** → its repos (`zed-laravel`, `zed-phpmd-lsp`,
  `workbench-dev-team`, …) expose `repository.issueTypes` and
  `repository.issueFields`. `mikebronner` (no hyphen) is a **User** →
  `laravel-messenger` returns `issueTypes: null` **and** `issueFields: null`.
  The feature must degrade silently on user-owned repos.
- **Issue types resolve at the owner level** — every `mike-bronner` repo
  returns the same three type node IDs (shared `IT_kwDOEA1bdM4…` prefix). Cache
  per owner, not per repo.
- **Issue fields resolve at the repo level** — `repository.issueFields`. On the
  org repos observed, the single-selects are:
  - `Priority`: `Urgent / High / Medium / Low` (field id `IFSS_kgDOAmguKg` on
    `zed-laravel`; **resolve by name, don't hardcode** — it differs per repo).
  - `Effort`: `High / Medium / Low` (not used by this change).
- **`get_item` already returns `content_node_id`** — the issue's node ID
  (`I_kwDO…`). That is exactly the `issueId` both mutations need. No extra fetch.
- PR-type project items carry a PR node id and `issue_number: null`. The
  derivation must run **only for issues**, never PRs.

## GraphQL surface (confirmed against the live schema)

Resolve catalogs the same way `GitHubAppService::getProjectFields` already does
for board fields — live query, Redis-cached:

```graphql
# Owner-level type catalog (cache by owner). Null for User owners.
{ repository(owner:$o, name:$r) { issueTypes(first:20){ nodes { id name } } } }

# Repo-level issue-field catalog (cache by repo). Null for User owners.
{ repository(owner:$o, name:$r) { issueFields(first:20) { nodes {
    __typename
    ... on IssueFieldSingleSelect { id name options { id name } }
} } } }
```

Writes (both confirmed present in the schema; inputs introspected):

```graphql
# Set / override the native issue Type.
mutation($issue:ID!, $type:ID!) {
  updateIssueIssueType(input:{ issueId:$issue, issueTypeId:$type }) {
    issue { id issueType { name } }
  }
}

# Set the issue-level Priority single-select value.
mutation($issue:ID!, $field:ID!, $opt:ID!) {
  updateIssueFieldValue(input:{
    issueId:$issue,
    issueField:{ fieldId:$field, singleSelectOptionId:$opt }
  }) { issue { id } }
}
```

`IssueFieldCreateOrUpdateInput` also carries `textValue / numberValue /
dateValue / multiSelectOptionIds / delete` — only `singleSelectOptionId` is
needed here.

## Task 1 — `get_item`: surface the issue-level catalogs

Add two keys to the `GetItemTool` payload (merge in the tool, **not** in the
shared `ProjectItemFormatter` — same perf reasoning as `project_fields`):

- **`issue_types`** — owner-level type catalog `[{ id, name }]`, or `null` when
  the owner is a User / types are unavailable.
- **`issue_fields`** — repo-level issue-field catalog (single-selects with
  ordered `options`), or `null` when unavailable.

These are for auditing/debuggability and to let a future caller resolve an
explicit `Type`. They are not load-bearing for the derived Priority (the server
resolves that internally), but `get_item` is the agent's single fetch and should
expose what the board write will touch.

## Task 2 — `update_fields`: derive issue Priority from WSJF

When the `update_fields` payload includes `Priority` (the NUMBER), **and** the
item is an issue **and** the repo exposes an `issue_fields` `Priority`
single-select, map the WSJF number to a bucket and write it via
`updateIssueFieldValue`:

| WSJF (project `Priority` NUMBER) | Issue `Priority` option |
|---|---|
| ≥ 13 | `Urgent` |
| 6 ≤ x < 13 | `High` |
| 3 ≤ x < 6 | `Medium` |
| < 3 | `Low` |

- Thresholds belong in one named constant/config — the human will tune them.
- Resolve the option **by name** (case-insensitive) against the repo's
  `issueFields` catalog, mirroring the board's option-name resolution. If the
  repo's Priority options differ from the four above, map the bucket to the
  nearest available option by rank rather than erroring.
- **Always overwrite** the issue Priority on a `Priority` write — it is derived,
  so it must always reflect the current WSJF (unlike Type, below).
- If the payload omits `Priority`, do not touch the issue field.

## Task 3 — `update_fields`: Type (auto-`PBI`, overridable)

On any `update_fields` write to an **issue** in an org repo with `issueTypes`:

- If the payload includes an explicit **`Type`** key → resolve it by name
  against `issueTypes` and set it via `updateIssueIssueType` (manual override;
  this **may** replace an existing type — the caller asked for it).
- Else, if the issue currently has **no** native type → auto-stamp `PBI`.
  **Guard:** only when `issue.issueType` is null. **Never** clobber a
  human-set `Product Goal` / `Acceptance Criteria` with the auto-default.
- `Type` is the **only** new accepted key on `update_fields`. The issue
  Priority is never accepted as input — passing it should be ignored/rejected,
  not written, to keep the single-source-of-truth invariant.

## Semantics that bind all three tasks

- **Org-only, silent degrade.** User-owned repos (`issueTypes`/`issueFields`
  null) get **none** of this — the project-field writes still succeed exactly as
  today. No error, no warning that fails the call.
- **Best-effort, non-fatal.** A failed `updateIssueIssueType` /
  `updateIssueFieldValue` (permission, feature-off, transient) must **not** roll
  back or fail the ProjectV2 field writes — the board `Priority` drives Watson's
  queue and is the critical write. Surface issue-side failures in the response
  payload (e.g. `issue_writes: { type: "...", priority: "skipped: ..." }`) so a
  caller can see what happened, but return `ok: true` for the board write.
- **Issues only.** Skip the entire issue-side path for PR-type items.

## ⚠️ Validate first — GitHub App permissions

`updateIssueIssueType` needs the App's `issues: write` permission on the
installation. `updateIssueFieldValue` is newer — confirm the installed
Lestrade/Index Apps can call it (a live test write against one `mike-bronner`
issue is the fastest proof). If the App lacks permission, **this is the blocker
to clear before anything else** — the mutations exist in the schema, but a
permission gap would make every issue-side write a best-effort skip and silently
defeat the feature. Report the App-permission status as the first finding.

## Acceptance criteria

- [ ] `get_item` returns `issue_types` (owner catalog) and `issue_fields` (repo
      catalog) for org repos; both `null` for user repos.
- [ ] `update_fields` with `Priority: <n>` writes the mapped issue-level
      `Priority` single-select on an org-repo issue; verified for all four
      buckets at the boundary values (2.9/3/6/13).
- [ ] `update_fields` auto-stamps `PBI` when an org-repo issue has no type;
      does **not** overwrite an existing `Product Goal`/`Acceptance Criteria`.
- [ ] `update_fields` with an explicit `Type` overrides the native type.
- [ ] User-owned repo (`mikebronner/laravel-messenger`): `update_fields` writes
      board fields and silently skips both issue-side writes; `ok: true`.
- [ ] Issue-side write failure does not fail or roll back the board-field write;
      the skip/failure is reported in the response.
- [ ] PR-type items take no issue-side path.
- [ ] App-permission status for `updateIssueIssueType` + `updateIssueFieldValue`
      confirmed and documented.
- [ ] Full Pest suite green; all access via the GitHub App, scopes intact.

## Constraints

- **Follow The Index's `CLAUDE.md`** for Laravel conventions (Pest, layout,
  naming). No raw DB access — models/scopes only.
- **No regressions.** `update_fields` must keep writing board fields exactly as
  today; the issue-side behavior is purely additive.
- **Resolve IDs by name, live + cached.** No hardcoded type/field/option node
  IDs — they differ per owner/repo and across accounts.
- **Plan before code.** Surface a plan for the `update_fields` change (where the
  derivation hooks in, how catalogs are cached) before implementing.
