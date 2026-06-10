# The Index handoff: `add_blocked_by` write tool

**Audience:** a Claude Code session running in the The Index repo
(`/Users/mike/Developer/Sites/calvinball`, server class `TheIndexServer`).
This is a ready-to-paste prompt describing one new MCP write tool the
`workbench-dev-team` plugin depends on for Inspector Lestrade's blocker-sweep
mode.

Paste everything from `---` down into The Index session. The preamble above
this line is for humans reading the plugin repo.

---

## Context

The `workbench-dev-team` plugin (github.com/mike-bronner/workbench-dev-team —
read `agents/lestrade.md`, *Sweep mode* section) is adding a blocker-sweep mode
to Inspector Lestrade. After Dispatch triages new items in a repo, it fires
Lestrade once per repo with `Repo sweep: <owner/repo>`. Lestrade reads all open
issues via `gh`, deduces which issues are blocked by which, and writes the
relationships as **native GitHub issue dependencies** (blocked-by) through a
new Index write tool. The Index signs the write with Lestrade's GitHub App,
same as every other agent write.

You already **read** these relationships: `GitHubAppService` queries `blockedBy`
via GraphQL (around line 200) to exclude blocked items from
`list_development_items`. This task adds the **write** side.

## New MCP tool: `add_blocked_by`

Class in `app/Mcp/Tools/` (follow the existing tool conventions —
`#[Name]` / `#[Description]` attributes, registered in the `$tools` array of
`app/Mcp/Servers/TheIndexServer.php`, routed behind the **write** scope
`index.mcp.write`).

### Signature

```
add_blocked_by(agent, repo, issue_number, blocked_by)
```

| Param | Type | Meaning |
|---|---|---|
| `agent` | string | Calling agent identity (`lestrade`, `watson`, `holmes`) — same declare-your-own-identity contract as the other write tools; the action is signed by that agent's GitHub App. |
| `repo` | string | `owner/repo` slug. **Note: keyed by repo + issue number, not `project_items.id`** — sweep mode operates on all open issues in a repo, and the blocked-by relationship is issue-level, not project-item-level. |
| `issue_number` | int | The **blocked** issue. |
| `blocked_by` | int[] | Issue numbers (same repo) that block it. Non-empty. |

### Semantics — additive and idempotent

- For each number in `blocked_by`, create the GitHub issue dependency
  "`issue_number` is blocked by `<n>`" **unless it already exists** — existing
  links (agent- or human-created) are silently skipped, never duplicated,
  never removed.
- **This tool never deletes a dependency.** There is deliberately no remove
  counterpart in this pass — human-set dependencies must be untouchable by
  agents.
- Self-references (`issue_number` ∈ `blocked_by`) and cross-repo numbers are
  validation errors.
- Targets that are not open issues in `repo` (closed issues, PRs, nonexistent
  numbers) fail validation for that entry; report per-entry results rather
  than failing the whole call when only some entries are bad.

### GitHub API

Use GitHub's native issue-dependencies API (the same feature the existing
`blockedBy` GraphQL read consumes — REST `…/issues/{n}/dependencies/blocked_by`
endpoints and/or the GraphQL mutation; **verify the current API surface before
implementing**, it shipped GA in 2025). The installed GitHub Apps already hold
Issues read/write (they comment and edit issue bodies today); confirm the
dependencies endpoints are covered by that permission and flag it if a new App
permission grant is required — that's an operator action, not a code change.

### Response shape

Follow the existing write-tool response convention (`ok: true/false` +
`errors`). On success include what actually happened, e.g.:

```json
{
  "ok": true,
  "repo": "owner/repo",
  "issue_number": 42,
  "added": [17, 23],
  "skipped_existing": [9],
  "failed": []
}
```

`ok: false` only when the call as a whole could not execute (auth, repo not
governed, validation of `repo`/`issue_number` themselves). Per-entry problems
go in `failed` with reasons while the valid entries still land.

### Tests (Pest, per existing per-tool convention in `tests/Feature/Mcp/`)

- Creates a dependency that doesn't exist yet.
- Skips (and reports) a dependency that already exists — no duplicate, no error.
- Never issues a delete — assert no removal call is made even when GitHub
  reports dependencies the request didn't include.
- Rejects self-reference and empty `blocked_by`.
- Per-entry failure (e.g., closed or nonexistent blocker) doesn't abort the
  valid entries.
- Requires `index.mcp.write` scope; signed as the declared `agent`.

### Contract test

Extend the existing MCP surface contract test (tool-name set) to include
`add_blocked_by` — the plugin's Lestrade agent lists this tool in its
frontmatter and calls it by exactly this name.

## Constraints

- **Follow The Index's `CLAUDE.md`** for Laravel conventions.
- **No raw DB access** — models/scopes only (this tool may not need the DB at
  all beyond repo-governance checks; follow whatever the other write tools do).
- **No regressions** — existing tools untouched; full Pest suite green.
- **Plan before code** — surface a plan for review before implementing.

## Acceptance criteria

- [ ] `add_blocked_by(agent, repo, issue_number, blocked_by)` registered on
      `TheIndexServer` behind `index.mcp.write`, signed by the declared agent's
      GitHub App.
- [ ] Additive + idempotent: existing dependencies skipped, nothing ever
      removed, per-entry results reported.
- [ ] Validation: same-repo only, no self-reference, non-empty `blocked_by`,
      blockers must be open issues.
- [ ] Tests cover create / skip-existing / never-delete / validation /
      per-entry failure / scope.
- [ ] Contract test includes the new tool name.
- [ ] README/docs updated with the new tool.
