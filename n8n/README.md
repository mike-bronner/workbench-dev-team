# n8n Agent Orchestration

Zero-token polling layer for the dev-pipeline agents. One unified workflow polls Calvinball every 15 min and dispatches Wormwood (Haiku), Tracer (Sonnet), and Moe (Opus) via SSH to localhost only when work exists.

## Setup

```bash
bash n8n/setup.sh        # first-time install (interactive)
bash n8n/setup.sh --force  # regenerate launchd plist
```

The script handles everything:
- n8n installation
- Keychain credential setup (prompts for missing values)
- SSH localhost configuration
- launchd service (auto-start, restart on crash)
- n8n credential imports (Calvinball OAuth2, Local SSH)
- Workflow import
- Claude Code MCP registration

## Required Keychain entries

Created automatically by `setup.sh` if missing:

| Service | Account | Source |
|---|---|---|
| `calvinball-mcp` | `client-id` | Laravel Passport |
| `calvinball-mcp` | `client-secret` | Laravel Passport |
| `claude-code` | `oauth-token` | `claude setup-token` |
| `github-cli` | `token` | Extracted from `gh auth` |
| `n8n-mcp` | `api-token` | n8n UI: Settings → API |

## Workflow

**File:** `workflows/orchestrator.json`

Single workflow with three parallel branches:

```
Schedule (15 min) → Poll Calvinball (OAuth2)
    ├── Gate: Wormwood → Lock Check → Dispatch (Haiku)
    ├── Gate: Tracer → Lock Check → Dispatch (Sonnet)
    └── Gate: Moe → Lock Check → Dispatch (Opus)
```

Each gate returns `[]` (empty array) if no work → downstream nodes don't execute → zero tokens.

## Updating the workflow

Edit in the n8n UI, then export and commit:

```bash
n8n export:workflow --id=qXakRzjHnp1P28X5 --output=n8n/workflows/orchestrator.json
```

Or re-import after editing the JSON:

```bash
n8n import:workflow --input=n8n/workflows/orchestrator.json
```
