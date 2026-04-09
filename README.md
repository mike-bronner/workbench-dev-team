# dev-pipeline

Calvinball-driven development pipeline as Claude Code subagents. Part of the [`claude-workbench`](https://github.com/mike-bronner/claude-workbench) marketplace.

## What this is

Three specialized subagents that move work through a development pipeline:

- **Miss Wormwood** — triage agent. Polls Calvinball for unrefined items, scores them (WSJF), and moves them to `Ready`.
- **Moe** — dev agent. Picks up `Ready` items and ships them as draft PRs.
- **Tracer Bullet** — code review agent. Reviews PRs in `In Review` and approves or requests changes.

Each agent has its own system prompt, scope, tool allowlist, and isolated context. They share workflow skills from this plugin (`skills/workflows/`) and can optionally call meta skills from the `core` plugin.

## Dispatch paths

Two ways to invoke the same agent definitions:

1. **Interactive** — Hobbes (or any parent agent) dispatches a subagent via the `Agent` tool when orchestrating work.
2. **Unattended** — scheduled tasks invoke an agent on a cron to poll Calvinball continuously.

Same `agents/*.md` definitions drive both paths. Scheduling is orthogonal to the agent itself.

## Status

🚧 **Pre-release (v0.1.0)** — scaffold only. The three subagents will be migrated from the old `~/.claude/scheduled-tasks/` location in Phase D, with Keychain-backed credentials replacing the plaintext secrets that currently exist in the old SKILL.md files.

## Installation

```
/plugin marketplace add mike-bronner/claude-workbench
/plugin install dev-pipeline@claude-workbench
```

## Requirements

- **Calvinball MCP** — the dev-pipeline agents poll Calvinball via MCP.
- **macOS Keychain** — credentials (Calvinball client id/secret, etc.) are read at runtime via `security find-generic-password`. No secrets in any file.
- **`gh` CLI** — required for PR creation and review.
