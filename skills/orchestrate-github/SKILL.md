---
name: orchestrate-github
description: The dev team's GitHub action routing, a topic skill of orchestrate. Holds whose voice an action carries, the routing table, passing a gh body, issue creation, and opening a PR. Load it with orchestrate before any GitHub action.
when_to_use: The user asks to review a PR, comment on an issue or PR, create or open an issue, merge a PR, triage an item, or check where things stand, or the session is about to open a PR or make a gh call that carries prose. Triggers on "review this PR", "comment on", "open an issue", "merge", "triage", "where do things stand", "open a PR".
---

# Orchestrate — GitHub actions

A topic skill of `/workbench-dev-team:orchestrate`, which holds the team, the
brief, and the dispatch protocol. Paths below are in this plugin.

## Action routing — Index MCP or gh CLI?

Two questions, in order, decide the path for a GitHub action the user asks for.

### 1. Whose voice does the action carry?

- **Agent work products** — formal PR reviews, acceptance criteria, status
  moves, agent comments — exist only inside The Index pipeline, signed by that
  agent's GitHub App. They go through a dispatched agent and its MCP write
  tools. Never produce them with `gh`. Why:
  `skills/orchestrate/references/brief-rationale.md`.
- **The user's own actions** — comments they dictate, merges they order — are
  theirs, executed directly with `gh` under their identity, on any repo.
- **Neither, when nothing reaches GitHub.** A Holmes Local-mode verdict is prose
  returned to this conversation, so it carries no GitHub voice. Posting one
  anywhere is the user's own action, and only after they have seen the exact
  content and said so.

### 2. Is the repo governed by The Index?

A repo is governed when The Index's GitHub App is installed on it. How to check,
and how to resolve the item ID that Lestrade and Holmes's Index mode need:
`skills/orchestrate/references/governed-repos.md`. A miss on the fallback scan
is inconclusive, so ask rather than treat the repo as ungoverned. If the repo is
governed but the item can't be resolved, **stop and report** — never fall back
to `gh` for agent work products. A PR with no board item at all is not that
case: the routing table sends it to Holmes Local mode.

### Routing table

| Request | Governed repo | Ungoverned repo |
|---|---|---|
| "review this PR" | Resolve item → dispatch **Holmes** (`Item ID: <n>`) — formal signed review. No board item → as ungoverned | **Holmes** Local mode on the PR branch's committed range, `Workdir: <path> (branch: <head>, range: origin/<base>...HEAD, pr: <n>)`. First check out the PR at its current head, as `gh pr checkout <n>` does, and bring `origin/<base>` up to date, asking the user as the gates require: Holmes moves no ref, checks the head against PR `<n>`, and stops on a stale base or head. The verdict comes back as prose. Never unwind commits to fake an uncommitted tree |
| "review what I've changed" / "review this working tree" | **Holmes** Local mode (the six-slot brief, via the Agent tool); the verdict comes back as prose | same |
| "comment on issue/PR" (user's words) | `gh issue comment` / `gh pr comment` — the user's voice | same |
| "create / open an issue" (user's words) | `gh issue create` — **the user's voice**, authored by you (the human); confirm repo + title first | same |
| "implement / fix / build X" | Item exists → **Watson** Index mode, through the dispatcher (`/workbench-dev-team:orchestrate-modes`, "Watson's Index-mode dispatch"), never the Agent tool. No item → ask: file it on the board, or Watson Direct mode off-board | **Watson** Direct mode (the six-slot brief, via the Agent tool; the diff comes back uncommitted) |
| "triage / write AC" | Resolve item → **Lestrade** (`Item ID: <n>`) | Draft AC inline — no agent |
| "merge this PR" | `gh pr merge` — **only on explicit request**, confirm repo + PR first. Never delegated: the MCP has no merge tool, and workbench-core's commit guard refuses a sub-agent's or the pipeline's `gh pr merge`. Board status follows via webhook | same |
| "where do things stand?" | Index read tools (`list_items`, `list_review_items`, …) + the running agents | `gh pr list` / `gh issue list` + the running agents |

**Every "ask" and "confirm" in this table goes through `AskUserQuestion`,**
with the recommended choice first and any warning in its description.

### Passing a gh body

Before any `gh` call that carries prose (a comment, an issue, a PR body, or
release notes), read "Passing a gh body" in `/workbench-dev-team:git-commit`.
Pass the body in a quoted heredoc or a file: write
`--body-file - <<'EOF'` (or `--notes-file -`), or name a file. Never write a
multi-line body in double quotes: the shell runs its backticks.

## Issue creation, two identities

When *you* ask for an issue in conversation, it's opened with `gh issue create`
so **you** (the human) are the author — the user's voice, same as comments.
Agent-authored follow-ups are the other case, and only Holmes opens them. On
either verdict, unrelated systemic debt that clears his materiality gate gets
one, when no related open issue exists to expand. A bug, security, or integrity
finding the PR's repo can fix never gets one: it blocks, with changes requested
in the same PR, even when it predates the PR or sits outside its scope. One only
another repo can fix goes to that repo as an issue, and does not hold the PR. Watson never opens one. He
folds unit-belonging findings into the same PR. Holmes
opens his via `mcp__the-index__create_issue(agent: …)`, so the issue carries the
**agent's** GitHub App identity, lands on The Casebook, and gets the native `PBI`
type. That path is internal to Holmes — not an orchestration call you make; it
only works on governed repos (App-signed), and degrades to no Type on user-owned
ones.

## Opening a PR

**You open the pull request for Direct-mode work.** Watson's Direct mode hands
back an uncommitted tree and opens no PR, so the session that commits the work
opens its PR too. Ask how the branch lands first, and push it and open the PR
only on a pull-request pick.

**Before you draft the body, read `skills/develop/references/pull-requests.md`
in this plugin, and the repo's PR template.** The reference names where a
template can live and how to fill it. The body follows the template's headings,
in the template's order. Show the human the filled template, never a free-form
body.
