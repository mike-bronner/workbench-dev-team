# The Index handoff: repo-governance routing tools

> **⏳ PENDING.** Two new read-scope MCP tools that let the plugin's
> `orchestrate` skill route GitHub actions correctly: Index pipeline for
> governed repos, `gh` CLI for everything else. The skill already calls both
> tools optimistically and degrades to a `list_items` scan when they're
> missing — shipping this removes the degraded path.

**Audience:** a Claude Code session running in `/Users/mike/Developer/Sites/the-index`.
Paste everything from `---` down into The Index session. The preamble above
this line is for humans reading the plugin repo.

---

## Context

The `workbench-dev-team` plugin (github.com/mike-bronner/workbench-dev-team)
now routes interactive requests — "review this PR", "fix this", "triage this" —
to either a dispatched agent (Holmes/Watson/Lestrade via your MCP, signed by
their GitHub Apps) or the plain `gh` CLI. The discriminator is **whether The
Index's GitHub App is installed on the repo in question**. The plugin needs to
ask you that, plus resolve an issue number to a `project_items.id` without
scanning `list_items` (which has no repo filter).

Two new tools, both read-scope (`index.mcp.read`), no `agent` param (reads
carry no identity):

## Tool 1 — `check_repo_access`

```
check_repo_access(repo: string)  // "owner/name"
```

**Behavior:** authenticated as The Index GitHub App (App JWT, not an
installation token), call `GET /repos/{owner}/{repo}/installation`. HTTP 200 →
the App is installed on that repo; 404 → it is not. Anything else (rate limit,
5xx) is an error — return it as one, never coerce to `governed: false` (a
false negative routes signed agent work to `gh`, which is the failure mode
this tool exists to prevent).

**Returns:**

```json
{ "repo": "owner/name", "governed": true }
```

**Constraints:**

- Validate the `repo` shape (`^[\w.-]+/[\w.-]+$`) before calling GitHub;
  reject malformed input with a clear error.
- Cache positive AND negative results for ~5 minutes (per repo) — the
  orchestrator may check several times in one session, and installations
  change rarely.

## Tool 2 — `find_item`

```
find_item(repo: string, issue_number: int)
```

**Behavior:** look up `project_items` by repo + issue/PR number — the same
matching you already do when ingesting webhooks. No GitHub round-trip needed.

**Returns** (found):

```json
{ "found": true, "item": { "id": 42, "repo": "owner/name", "issue_number": 7, "title": "…", "status": "In Review" } }
```

**Returns** (no match — e.g., webhook lag or the issue isn't on the board):

```json
{ "found": false }
```

`found: false` is a normal result, not an error. The plugin treats it as
"governed repo, item not resolvable — stop and report", so the distinction
between *error* and *not found* matters.

## Definition of done

- Both tools appear in the MCP tool list under `index.mcp.read` scope.
- `check_repo_access` verified live against one governed repo (200 path) and
  one ungoverned repo (404 path).
- `find_item` verified against an existing board item and a nonexistent
  issue number.
- Feature tests cover: governed/ungoverned/malformed-repo/GitHub-error for
  Tool 1; found/not-found for Tool 2.
