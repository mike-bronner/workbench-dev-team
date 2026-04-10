# n8n Agent Orchestration

Zero-token polling layer for the dev-pipeline agents.

## Required Keychain entries

```bash
# Calvinball OAuth credentials
security add-generic-password -s "calvinball-mcp" -a "client-id" -w "YOUR_CLIENT_ID" -U
security add-generic-password -s "calvinball-mcp" -a "client-secret" -w "YOUR_CLIENT_SECRET" -U
```

## Workflow files

| File | Agent | Model | Trigger |
|---|---|---|---|
| `workflows/wormwood.json` | Miss Wormwood (triage) | Haiku | */15 * * * * |
| `workflows/tracer.json` | Tracer Bullet (review) | Sonnet | */15 * * * * |
| `workflows/moe.json` | Moe (develop) | Opus | */15 * * * * |

Each workflow is self-contained: inline Keychain auth, HTTP poll, status filtering, and `claude -p` dispatch.

## Setup

```bash
bash setup.sh        # first-time install
bash setup.sh --force  # regenerate launchd plist
```

## Updating workflows

After editing a workflow JSON file, re-import:

```bash
n8n import:workflow --input=workflows/wormwood.json
```

Or re-run `setup.sh` to import all three.
