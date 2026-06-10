---
name: Session 2026-04-25 — Cross-Surface Skill Installation
description: Built /workbench-core:install-chat-skills feature enabling slash-command-driven skill packaging and installation into Claude Chat
type: project
---

## Outcome
✅ Shipped `/workbench-core:install-chat-skills` — a new slash-command skill that packages workbench-plugin skills as `.skill` bundles and installs them into Claude Chat on macOS.

## What was built

**install-chat-skills.sh** (workbench-core script)
- Parses plugin metadata from plugin SKILL.md files
- Bundles skills into `.skill` files (macOS executable format)
- Uses `open` command to trigger Claude Chat installation via file association
- Handles errors gracefully (checks SDK availability, validates input)

**`/workbench-core:install-chat-skills` skill** 
- Slash-command wrapper around the script
- Discovers available plugins + skills
- Lets user select which skill to install to Chat
- Integrates into SessionStart detection for auto-bootstrap
- Added to workbench-core README with usage examples

## Design decisions

**Slash-command-as-button approach confirmed** — User approved using a slash command (not a button/menu) as the UX to trigger installation. This fits Claude Code's skill paradigm and is discoverable via `/` autocomplete.

**Packaging format: `.skill` (ZIP + Gitmoji executable)** — Each skill exports as a macOS-recognizable file type that double-click installs into Claude Chat. Requires `name:` field in SKILL.md frontmatter for proper packaging (despite being optional in the plugin convention).

**SessionStart auto-detection** — The skill is hooked into session-warmup.sh so users are prompted to install on their first use of a plugin, reducing friction.

## Technical notes

- Only works on macOS (uses `open` command and `.skill` file association)
- Requires jq and appropriate SDK tooling
- Error handling prioritizes clarity — guides user to specific next steps if something fails
- `.skill` file structure: ZIP archive with gitmoji + metadata header for file-type magic bytes

## Promoted to memory
The design decision around slash-command-as-button UX was confirmed and will inform future workbench plugin surface interactions. Packaging requirements (name field, .skill format) documented.

## Version bump
workbench-core v0.13.0 → v0.14.0 (feature addition for cross-surface installation)
