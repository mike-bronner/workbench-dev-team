# dev-pipeline

Calvinball-driven development pipeline as Claude Code subagents. Part of the [`claude-workbench`](https://github.com/mike-bronner/claude-workbench) marketplace.

## What this is

Three specialized subagents that move work through a GitHub project board:

- **Miss Wormwood** (Haiku) — triage. Polls Calvinball for unrefined items, generates acceptance criteria, scores WSJF, moves to Backlog.
- **Moe** (Opus) — development. Picks up Ready/In Progress items, clones repos, writes code + tests, creates PRs, moves to In Review.
- **Tracer Bullet** (Sonnet) — code review. Reviews PRs in In Review, approves or requests changes, escalates after 3 rounds.

## How it works

**n8n** polls Calvinball every 15 minutes via HTTP (zero Claude tokens on idle). When work exists, n8n dispatches the appropriate agent via `claude -p --agent dev-pipeline:{name}`.

```
GitHub webhook → Calvinball (filter + queue)
                      ↓
n8n polls every 15 min (HTTP, zero tokens)
                      ↓ work found
      ┌───────────────┼───────────────┐
      ↓               ↓               ↓
  Wormwood          Tracer           Moe
  (Haiku)           (Sonnet)         (Opus)
```

Each agent uses the right-sized model for its task. Token overhead per dispatch: ~5-8K (lean agent definition + minimal tools) vs ~25-30K for a full Claude Code session.

### Token efficiency

| Scenario | Cost |
|---|---|
| Idle poll (no work) | 0 tokens — n8n handles HTTP |
| Wormwood triage | ~5-8K input + output (Haiku) |
| Tracer review | ~5-8K input + output (Sonnet) |
| Moe development | Full session (Opus, variable) |

## Prerequisites

- **n8n** — workflow automation (`npm install -g n8n`)
- **Claude Code** — `claude` CLI on PATH (provides agent dispatch + OAuth auth)
- **gh CLI** — authenticated for GitHub operations
- **jq** — JSON processing
- **macOS Keychain** entries:
  - Service `calvinball-mcp`, account `client-id` — Calvinball OAuth client ID
  - Service `calvinball-mcp`, account `client-secret` — Calvinball OAuth client secret

## Setup

```bash
# From the plugin directory:
bash n8n/setup.sh
```

The setup script:
1. Installs n8n if missing
2. Verifies Keychain credentials
3. Creates a launchd service (auto-starts n8n at login on port 5679)
4. Imports the three workflow templates
5. Tests Keychain access from launchd context

After setup, activate the workflows in the n8n UI at `http://localhost:5679`, or they'll start on their next scheduled trigger.

### Re-running after a plugin update

When the plugin version bumps, re-run `bash n8n/setup.sh` to re-import updated workflow templates. The launchd plist is preserved unless `--force` is passed.

## Dispatch paths

Two ways to invoke the same agent definitions:

1. **Unattended (default)** — n8n polls Calvinball on cron, dispatches via `claude -p --agent`.
2. **Interactive** — Hobbes or any parent agent dispatches a subagent via the Agent tool.

Same `agents/*.md` definitions drive both paths.

## Risks and limitations

- **Mac must be on.** n8n and Claude Code both run locally. No server-side autonomy yet.
- **Moe concurrency.** A lock file at `/tmp/moe.lock` prevents concurrent Moe runs. If Moe hangs, the lock file must be manually deleted.
- **Moe budget cap.** `--max-budget-usd 5.00` limits per-run spend. Complex implementations may hit this ceiling.
- **launchd Keychain access.** The plist sets `SessionCreate: true` for Keychain access. If auth fails in n8n, verify with `launchctl print gui/$(id -u)/com.mikebronner.n8n`.
- **Calvinball must be running.** The OAuth token endpoint and project-items API must be reachable at `https://calvinball.mikebronner.dev`.

## Monitoring

- **n8n UI:** `http://localhost:5679` — execution history, per-node data flow, failed runs with errors.
- **Agent logs:** `~/.n8n/logs/wormwood-*.log`, `tracer-*.log`, `moe-*.log` — full agent output per dispatch.
- **n8n process logs:** `~/.n8n/logs/n8n-stdout.log`, `n8n-stderr.log`.

## Troubleshooting

| Problem | Fix |
|---|---|
| n8n not starting | Check `~/.n8n/logs/n8n-stderr.log`. Common: wrong Node.js version (needs >=22.16). |
| Auth fails in workflow | Verify Keychain: `security find-generic-password -s calvinball-mcp -a client-id -w` |
| Moe stuck (lock file) | `rm /tmp/moe.lock` |
| Agent not found | Verify plugin installed: `claude agents` should list `dev-pipeline:miss-wormwood` etc. |
| Calvinball unreachable | Check Herd/Valet: `curl https://calvinball.mikebronner.dev/api/project-items` |

## Installation

```
/plugin marketplace add mike-bronner/claude-workbench
/plugin install dev-pipeline@claude-workbench
```
