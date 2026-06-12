# workbench-dev-team

A Claude Code plugin that runs a three-agent development pipeline against a GitHub project board. Items flow from triage → development → review without you touching them. Part of the [`claude-workbench`](https://github.com/mike-bronner/claude-workbench) marketplace.

## What it does

You work out of a GitHub project board. New issues land with no acceptance criteria. Well-refined ones sit in `Ready`. Work-in-progress has open draft PRs. PRs waiting on review pile up.

This plugin runs three agents on a local 20-minute clock to move items through the pipeline for you:

- **Inspector Lestrade** (Haiku) — triage. Reads items in the `Inbox` lane, writes acceptance criteria, scores WSJF, moves them to `Backlog` for your review. Also runs **blocker sweeps**: after a repo gets fresh triage work, he re-reads all of its open issues and marks blocked-by dependencies (native GitHub issue dependencies, additive only) so blocked items stay out of Dr. Watson's queue.
- **Dr. Watson** (Opus, $5/run cap) — development. Has two modes: **The Index mode** (Dispatch-driven, picks the top `Ready`/`In Progress` item, clones the repo, writes code and tests against AC, opens a PR, moves to `In Review`) and **Direct mode** (invocable as a sub-agent from Claude Code or Cowork for ad-hoc dev work — no The Index calls, just runs the `/develop` skill in a sub-agent context). Both modes follow the `/develop` skill for the actual coding.
- **Sherlock Holmes** (Sonnet) — code review. Reviews open PRs, approves or requests changes. Escalates to you after 3 rounds. Reviews fan out across blind, read-only lens sub-agents (AC conformance, correctness, security, test honesty), with every blocker adversarially verified before it lands; only the parent writes, so there's still exactly one App-signed verdict. Falls back to a single inline pass when the fan-out is unavailable.

A fourth component — **Dispatch** — is the local scheduled task that polls the board every 20 minutes and fires the right agent for each pending item. Dispatch is the only thing that's scheduled; the three agents run as dispatched subprocesses.

## Install

```
/plugin marketplace add mike-bronner/claude-workbench
/plugin install workbench-dev-team@claude-workbench
```

That installs the agents, the Dispatch prompt, and the bundled skills (see below). Nothing is scheduled yet.

## Bundled skills

The plugin ships three skills:

- **`develop`** and **`git-commit`** — universal development standards. They register themselves globally via `session-warmup.md`, which workbench-core picks up at session start and injects into `~/.claude/CLAUDE.md`. They apply to every Claude Code / Cowork session, not just dev-team agents. Both are also packageable as `.skill` files for Claude Chat (Mac app) where plugins aren't supported but skills are. Require workbench-core 0.2.0+ for the session-warmup discovery mechanism — install it first if you don't already have it (Claude Code does not enforce plugin install order).
- **`orchestrate`** — runs the team as background sub-agents from any interactive session (see below). A `session-warmup.md` hint makes every session aware the team is available for delegation.

Plugin configuration lives in a slash command (`/workbench-dev-team:setup`), not a skill — see the [Setup](#setup) section below.

### `develop`

Universal dev workflow + standards: orient before writing, plan before coding, atomic commits, every change gets a test, no committed secrets, lint before pushing. Triggers whenever code is being implemented, fixed, refactored, or tested — manual or agent-driven.

Includes a **decision protocol** that requires presenting three options to the human (with reasoning and a recommendation) for any meaningful fork — implementation approach, library choice, scope decisions, naming. The human decides, the agent executes. Trivial choices (mechanical translation, following existing repo conventions, one-line obvious fixes) are exempt.

Also defines the **commit approval gate** (see [Commit approval gate](#commit-approval-gate) below): no `git commit` without explicit human approval of the diff and message.

Used by Watson internally in both operating modes. Also invocable directly in any plugin-aware Claude session.

### `git-commit`

Generates commit messages using Conventional Commits + Gitmoji format. Triggers whenever a commit message is being composed — manual, scripted, or agent-driven (including Watson's PRs).

Format example:

```
feat: ✨ Add email validation endpoint.

Fixes: #789
```

Full type and emoji references at `skills/git-commit/references/`.

### `orchestrate`

Turns the current session into the team's orchestrator: dispatches Lestrade, Watson, and Holmes as **background sub-agents** (Agent tool, `run_in_background`), passing each agent's model from the shared config; maintains a roster table of who's working on what; relays verdicts and decision forks back to you; follows up on running agents via SendMessage. The main conversation stays lean — sub-agents do the heavy work in their own contexts and return summaries.

Watson supports prose-driven **Direct mode** for ad-hoc dev work with no board item. Lestrade and Holmes are Index-coupled and need a board item ID.

The skill also **routes GitHub actions to the right executor**. Two rules: (1) *agent work products* (formal reviews, AC, status moves) only ever go through The Index, signed as the dispatched agent — never `gh`; (2) *your own actions* (comments you dictate, merges you order) go through `gh` under your identity, on any repo. Whether a repo is Index-governed is answered by `check_repo_access` — a server-side tool that checks The Index GitHub App's installation list (spec in `THE_INDEX_HANDOFF_ROUTING.md`; until it ships, the skill degrades to a `list_items` scan and says so). Merges are never delegated to agents and only happen on your explicit request.

## Commit approval gate

**Every `git commit` requires explicit human approval. Non-negotiable.** Enforced twice, because prose alone drifts:

1. **Prose** — the `develop` skill instructs the agent to present the staged diff and the proposed commit message, then wait for an explicit yes before committing. One approval covers one commit.
2. **Machinery** — a plugin `PreToolUse` hook ([hooks/hooks.json](hooks/hooks.json) → [hooks/scripts/commit-approval-gate.sh](hooks/scripts/commit-approval-gate.sh)) detects `git commit` in any Bash invocation (compound commands, `-C`/`-c` flags, env prefixes included) and returns `permissionDecision: "ask"`, forcing the harness to prompt — even in auto-accept permission modes, even if the model forgot the prose.

**Pipeline carve-out.** Headless `ask` prompts auto-deny, so an ungated rule would deadlock every scheduled Watson run at its first commit. The hook therefore allows commits through when the autonomous Index pipeline is demonstrably running: a live-PID `/tmp/watson.lock` (which Watson's Index mode acquires before any work) or `WORKBENCH_DEV_TEAM_PIPELINE=1` in the environment. In the pipeline, board dispatch is the approval and Holmes review + your PR merge is the human gate. A stale lock (dead PID) does **not** bypass.

Known edge: while a scheduled Watson run is live, its lock also exempts concurrent interactive sessions on the same machine. The prose protocol still applies there; the window is the few minutes of a pipeline tick.

Tests: `hooks/scripts/test-commit-approval-gate.sh` (19 cases — detection, non-commit silence, carve-outs).

## Configuration — models, effort, budget

Per-agent model, effort, and Watson's budget cap live in a single file, written by `/workbench-dev-team:setup` with these defaults and never overwritten on re-run (your edits survive plugin updates):

```json
// ~/.claude-workbench/dev-team-config.json
{
  "agents": {
    "lestrade": { "model": "haiku" },
    "holmes": { "model": "sonnet", "effort": "high", "fanout": true, "lensModel": "sonnet" },
    "watson": { "model": "opus", "effort": "high", "maxBudgetUsd": 5.00 }
  }
}
```

Both dispatch paths read it:

- **Scheduled (Dispatch)** passes `--model`, `--effort` (only when set), and `--max-budget-usd` on each `claude -p` invocation. CLI flags override agent frontmatter (verified empirically), so a config edit takes effect on the next tick — no plugin files to touch.
- **Interactive (`orchestrate`)** passes the config's `model` as the Agent tool's per-invocation model override. The Agent tool has no per-invocation effort parameter — interactive sub-agents inherit the session's effort level. `maxBudgetUsd` applies to the scheduled path only.

Holmes also carries two optional review knobs: `fanout` (bool, default `true`) toggles its multi-lens review fan-out, and `lensModel` (default: Holmes's own `model`) sets the model its lens and skeptic sub-agents run on. Both default cleanly when absent.

The agent definitions carry matching frontmatter defaults (`model: haiku|sonnet|opus`), so direct Agent-tool dispatch without the skill still lands on the right model. `effort` is deliberately **not** in frontmatter: frontmatter effort would override the session level — including Dispatch's `--effort` flag — turning the config knob into a no-op. Missing file, missing key, or malformed JSON all fall back to the defaults above; dispatch never blocks on config problems.

## Setup

After `/plugin install`, run this in any Claude Code session:

```
/workbench-dev-team:setup
```

It walks you through cadence selection (20 or 30 min), Keychain seeding for any missing credentials, The Index MCP registration, log directory and agent-config creation, and Dispatch scheduled-task registration. Idempotent — re-run any time to refresh the OAuth token, re-register the MCP, or change cadence. Your `dev-team-config.json` edits are never overwritten.

Prerequisites on your machine: `gh` (authenticated), `jq`, `security` (built into macOS).

You'll be prompted in chat for any of these Keychain entries that aren't already present:

| Entry | Purpose |
|---|---|
| `the-index-mcp / client-id` | The Index OAuth client ID |
| `the-index-mcp / client-secret` | The Index OAuth client secret |
| `github-cli / token` | GitHub token for dispatched agents (auto-extracted from your existing `gh auth login` Keychain entry when present) |
| `claude-code / oauth-token` | Claude Code OAuth token for scheduled `claude -p` invocations. Get one with `claude setup-token` |

### What `/workbench-dev-team:setup` does, in order

1. **Verifies prerequisites** (`gh`, `jq`, `security`) and Keychain credentials; prompts for anything missing.
2. **Fetches an OAuth bearer token** from The Index (client_credentials grant, 1-year lifetime).
3. **Registers The Index MCP** with Claude Code at user scope, passing the bearer via `--header`. This makes `mcp__the-index__*` tools available to every future Claude Code session, including the dispatched agents.
4. **Creates the log directory** at `~/.claude-workbench/dev-team-logs/` and **writes the default agent config** to `~/.claude-workbench/dev-team-config.json` if (and only if) it doesn't already exist.
5. **Registers the scheduled Dispatch task** by calling `mcp__scheduled-tasks__create_scheduled_task` (or `update_scheduled_task` if it already exists) directly from the running session. Task ID: `workbench-dev-team-dispatch`. Cron: `*/20 * * * *` (or `*/30` if you chose 30 min).

Re-run the skill any time you need to refresh the OAuth token, re-register the MCP, or change the Dispatch cadence.

## How it works

```
GitHub webhook ──► The Index (MCP server, OAuth 2.1)
                              ▲
                              │ MCP tool calls
                              │
     scheduled Dispatch task (every 20 min, local)
                              │
                              ▼ nohup claude -p --agent ... &
            ┌─────────────────┼─────────────────┐
            ▼                 ▼                 ▼
        Lestrade            Holmes              Watson
        (Haiku)             (Sonnet)            (Opus, $5 cap)
```

Every 20 minutes, the Dispatch scheduled task wakes up and:

1. Calls `mcp__the-index__list_unrefined_items()` → fires Lestrade for each item returned, plus one blocker sweep (`Repo sweep: <owner/repo>`) per distinct repo among those items.
2. Calls `mcp__the-index__list_review_items()` → fires Holmes for each item returned.
3. Calls `mcp__the-index__list_development_items(limit=1)` → fires Watson on the top item (if any).
4. Exits.

Each dispatch is fire-and-forget via `nohup claude -p --agent workbench-dev-team:<name> ... &; disown`. Watson alone can run for hours; Dispatch never blocks.

### The Index does the filtering

All "what's pending in each lane" logic lives server-side in The Index's MCP tools. Dispatch never interprets item status, field changes, or priority — it just asks The Index "what's pending in each lane?" and fires the matching agent per returned item. Adding a new dispatch rule means editing The Index, not this plugin.

### Concurrency

- **Inspector Lestrade and Sherlock Holmes** are idempotent within a tick. Status lanes (`null` and `In Review`) act as the serialization.
- **Dr. Watson** picks from `In Progress` OR `Ready` (In Progress first — that's the resume path for crashed runs). A host-local PID mutex at `/tmp/watson.lock` prevents two Watsons from stepping on the same item. Released automatically via shell `trap` on exit.

### Token cost

| Scenario | Tokens |
|---|---|
| Idle Dispatch tick (no work in any lane) | ~1–3K on default model — three MCP calls + exit |
| Lestrade triage | 5–8K Haiku tokens |
| Lestrade blocker sweep | Haiku tokens scaling with open-issue count (reads every open title + body in the repo); fires only on ticks that triaged new items |
| Holmes review | 5–8K Sonnet tokens |
| Watson development | Full Opus session, capped at $5 per run |

Dispatch runs on your Claude Code default model (scheduled tasks don't expose a model selector). Since each tick is under 3K tokens, the default model's cost is negligible even if it's Sonnet.

## Dispatch paths

Two ways to invoke the same agents, same definitions:

1. **Unattended (default).** The scheduled Dispatch task polls The Index every 20 minutes and dispatches via `claude -p --agent`. This is what `/workbench-dev-team:setup` registers.
2. **Interactive.** Any Claude Code session can dispatch an agent directly via the Agent tool, e.g., `Agent(subagent_type: "workbench-dev-team:lestrade", ...)`. For multi-agent delegation with config-driven models, background execution, and roster tracking, use the `orchestrate` skill — it wraps this path with the full protocol. Useful for manual triage, one-off runs, ad-hoc dev work (Watson Direct mode), or debugging without waiting for the next scheduled tick.

## Monitoring

- **Agent logs.** `~/.claude-workbench/dev-team-logs/<agent>-<item>-<timestamp>.log` — full agent output per dispatch.
- **Scheduled task panel.** Claude Code's scheduled-tasks panel shows the Dispatch task's run history and next-run time.
- **Project board.** Items flow Inbox → Backlog → Ready → In Progress → In Review → Approved / Escalated. Status drift (items stuck in a column) is your canary.

## Troubleshooting

| Problem | Fix |
|---|---|
| `claude mcp list` shows the-index as Failed to connect | Your OAuth token has probably expired or been revoked. Re-run `/workbench-dev-team:setup` to fetch a fresh token and re-register. |
| Dispatch logs `the-index unreachable` | `curl https://the-index.mikebronner.dev/mcp` to check the endpoint. If 500, The Index has a middleware bug (should be 401). |
| Watson stuck (process hung, `/tmp/watson.lock` stale) | `rm /tmp/watson.lock`. Next tick will resume. |
| Agent not found | `claude agents` should list `workbench-dev-team:lestrade`, `:watson`, `:holmes`. If not, reinstall the plugin. |
| Item stuck in `In Review` with no PR | Holmes couldn't find a PR for the issue. Check `gh pr list -R <repo> --search <issue>`. |
| Scheduled task isn't firing | Check Claude Code's scheduled-tasks panel. The Mac must be awake (this is a local scheduler). |

## Risks and limitations

- **Local execution.** Dispatch runs on your Mac. If the host is off, no work moves. Fine for home/dev setups; move Dispatch to an always-on box if you need 24/7 coverage.
- **Watson budget cap.** `--max-budget-usd 5.00` limits per-run spend. Complex work may hit the ceiling and leave the item in `In Progress`; the next tick resumes.
- **The Index must be reachable.** If the MCP server is down, all three list tools fail and Dispatch logs `the-index unreachable` and exits cleanly. The next tick retries.
- **OAuth token lifetime.** The Index issues 1-year tokens via client_credentials. Re-run `/workbench-dev-team:setup` annually (or whenever you rotate the OAuth client secret).

## Manual task registration (fallback)

If `/workbench-dev-team:setup` fails at step 5 (scheduled-task registration), choose "Skip" when re-prompted to register the schedule, then register manually from any Claude Code session:

```
mcp__scheduled-tasks__create_scheduled_task with
  taskId:         "workbench-dev-team-dispatch"
  cronExpression: "*/20 * * * *"         # or */30 for 30-min cadence
  description:    "Dispatch — poll The Index every 20 min and fire workbench-dev-team agents on pending items."
  prompt:         <body of scheduled-tasks/orchestrator.md, frontmatter stripped>
```

## Why not cloud routines

An earlier iteration targeted Anthropic's cloud-hosted routines (`/fire` endpoint, configured via `/schedule` → `RemoteTrigger`) for event-driven dispatch. Two things killed it:

1. **The 15-routine-runs-per-day cap** on online routines. Dispatch every 20 minutes = 72 fires/day, seven times over.
2. **Added operational surface.** Fire-token storage, a The Index-side webhook dispatcher, per-transition idempotency — a lot of moving parts to event-drive what a 20-minute poll handles just as well.

A local 20-minute poll has higher worst-case latency but zero per-fire cost, simpler failure modes, and no token rotation burden. Given that Watson can run for hours, 20-minute dispatch latency is noise.
