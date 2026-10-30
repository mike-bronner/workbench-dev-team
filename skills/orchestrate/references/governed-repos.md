# Is the repo governed by The Index?

On-demand detail for `skills/orchestrate/SKILL.md`, "Action routing", question 2.
Read it when a GitHub action request needs the governed-or-not answer, or an
item ID.

A repo is governed when The Index's GitHub App is installed on it. Check, in
order:

1. `mcp__the-index__check_repo_access(repo)` — the authoritative answer,
   straight from the App's installation list.
2. Fallback, only when that call fails or errors:
   `mcp__the-index__list_items(limit: 100)` and scan for the repo
   among item `repo` fields. A hit proves governed; a miss is **inconclusive**
   — say so, and ask the user through `AskUserQuestion` rather than silently
   treating the repo as ungoverned.

Cache the answer per repo for the rest of the session.

To dispatch Lestrade, or Holmes in Index mode, you also need the **item ID** for
the issue/PR (Holmes's Local mode needs none — it reads no board):
`mcp__the-index__find_item(repo, issue_number)`. If that call fails or errors,
fall back to the `list_items` scan. If the repo is governed but the item can't
be resolved (webhook lag, item not on the board), **stop and report** — never
fall back to `gh` for agent work products.
