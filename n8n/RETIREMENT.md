# n8n retirement runbook

Use this once the Dispatch-based pipeline has run end-to-end: the scheduled **Dispatch** Haiku task has polled Calvinball at least once, each of the three agents has been dispatched at least once and completed its status transition (Wormwood → Backlog, Moe → In Review, Tracer → Approved / Escalated / back to In Progress), and Moe's `/tmp/moe.lock` mutex has been exercised by a crashed-and-resumed item.

## Pre-flight checks

Only run the retirement steps below **after** these all pass:

1. `/workbench-dev-team:setup` has been run successfully in a Claude Code session. Calvinball MCP is registered with Claude Code at user scope (`claude mcp list` shows `calvinball → https://calvinball.mikebronner.dev/mcp`). All four Keychain entries exist: `calvinball-mcp/client-id`, `calvinball-mcp/client-secret`, `github-cli/token`, `claude-code/oauth-token`.
2. The scheduled **Dispatch** task is registered via `mcp__scheduled-tasks__create_scheduled_task` with the contents of `scheduled-tasks/orchestrator.md` as its prompt, cron `*/20 * * * *` (or `*/30 * * * *`), model `haiku`. Visible in Claude Code's scheduled-tasks panel.
3. Dispatch has fired at least one full tick that produced work in each lane:
   - An unrefined item was picked up and `workbench-dev-team:miss-wormwood` was dispatched → item ended up in `Backlog` with AC + WSJF populated.
   - An `In Review` item was picked up and `workbench-dev-team:tracer-bullet` was dispatched → item ended up in `Approved`, back in `In Progress`, or `Escalated`.
   - A `Ready` or `In Progress` item was picked up and `workbench-dev-team:moe` was dispatched → item ended up in `In Review` with an open PR.
4. Moe's host-local mutex has been exercised: a second Moe dispatched while another was running hit `/tmp/moe.lock`, logged `Moe busy (pid …) — exiting`, and exited cleanly.
5. Agent logs in `~/.claude-workbench/dev-team-logs/` show clean exits (no panics, no `calvinball unreachable` during a known-good window).
6. There are no executions pending in the n8n UI for the Agent Orchestrator workflow.

If any of the above fail, **do not** proceed. Fix forward first.

## Retirement steps

Execute in order. Each is reversible up to step 6.

### 1. Disable the n8n launchd service

```bash
launchctl unload ~/Library/LaunchAgents/com.mikebronner.n8n.plist
```

Verify: `launchctl list | grep com.mikebronner.n8n` returns nothing.

### 2. Remove the launchd plist

```bash
rm ~/Library/LaunchAgents/com.mikebronner.n8n.plist
```

### 3. Remove the n8n MCP registration

```bash
claude mcp remove n8n
```

This clears the `http://localhost:5679/mcp-server/http` registration left by the old n8n setup script.

### 4. Delete the n8n MCP Keychain entry

```bash
security delete-generic-password -s "n8n-mcp" -a "api-token"
```

**Keep** these Keychain entries — all still required by Dispatch and the three agents:

- `calvinball-mcp / client-id` — Calvinball MCP OAuth client.
- `calvinball-mcp / client-secret` — Calvinball MCP OAuth client.
- `github-cli / token` — dispatched agents use `gh` against GitHub.
- `claude-code / oauth-token` — the scheduled Dispatch task uses `claude -p` headlessly.

### 5. (Optional) Uninstall n8n globally

Safe to leave installed if you use n8n for other projects. If not:

```bash
npm uninstall -g n8n
```

### 6. Remove the `n8n/` directory from the repo

```bash
cd /Users/mike/Developer/workbench-dev-team
rm -rf n8n/
```

Commit the deletion:

```bash
git add -A
git commit -m "Retire n8n orchestrator"
```

### 7. (Optional) Clean up `~/.n8n`

If you're not using n8n at all anymore:

```bash
rm -rf ~/.n8n
```

Contains n8n's database, workflow history, and logs. Irreversible — only do this after you're confident nothing else depends on it.

## Rollback

Steps 1–5 are easily reversible:

- Reinstall the plist, `launchctl load` it, reinstall n8n if removed.
- Re-add the `n8n-mcp / api-token` Keychain entry from the original generation flow.
- Re-register the MCP with `claude mcp add n8n ...` pointing at `http://localhost:5679/mcp-server/http`.

Step 6 (git delete) is reversible via `git revert` as long as the commit hasn't been force-rewritten.

Step 7 (`~/.n8n` deletion) is **not** reversible — backup first if you care about workflow history.

## What replaced n8n

The Dispatch architecture replaces n8n's Agent Orchestrator workflow with a single **local scheduled Claude Code task** (Haiku, every 20–30 min) that polls Calvinball via three narrow MCP tools and dispatches `claude -p --agent workbench-dev-team:<name>` as a detached subprocess per item.

Key differences vs n8n:

- **No Node runtime, no launchd job, no local HTTP server.** The scheduler is built into Claude Code; the orchestrator prompt lives in `scheduled-tasks/orchestrator.md`.
- **No curl to Calvinball from agents.** All data access is via the Calvinball MCP (OAuth 2.1 client_credentials, scopes `calvinball.mcp.read` / `calvinball.mcp.write`).
- **Filter and sort logic lives server-side** in Calvinball's `list_unrefined_items` / `list_review_items` / `list_development_items` tools — Dispatch is a thin router.
- **Concurrency via status lanes + Moe's local mutex.** Wormwood (`status = null`) and Tracer (`status = 'In Review'`) are idempotent within a tick; Moe holds `/tmp/moe.lock` to prevent two concurrent runs on the same `In Progress` item.

Everything n8n owned is now either built into Claude Code (the scheduler), Calvinball (the filter logic), or Moe itself (the mutex). This machine still needs to be awake to dispatch work — a 20–30 min poll with zero per-fire cost is the tradeoff.
