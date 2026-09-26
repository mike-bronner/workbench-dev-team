---
name: git-commit
description: Generate commit messages using Conventional Commits + Gitmoji format. Use this skill whenever creating, drafting, or suggesting git commit messages — including /commit commands, pre-commit hooks, bulk commits, and any context where a commit message is being composed. Always invoke this skill before writing a commit message.
---

# Git Commit Messages

## Format

```
<type>: <emoji> <description>.

<optional body>

<optional footer(s)>
```

The colon, emoji, and description each separated by exactly one space: `type: emoji description.`

## Rules

1. Description starts with the appropriate gitmoji, one space after `:`
2. Description ends with a period
3. No scopes — ever
4. Only reference real GitHub issues in footers
5. Always consult `references/gitmoji.md` to select the correct emoji for the change
6. Always consult `references/conventional-commits.md` to determine the correct type and overall format for the commit message, based on SemVer mapping and breaking change syntax

## Examples

```
feat: ✨ Add email validation endpoint.
```

```
fix: 🐛 Resolve checkout payment error.
```

```
refactor: ♻️ Extract payment processing into service class.
```

```
fix: 🐛 Resolve token expiration bug.

Fixes: #789
Fixes: #790
```

## Passing the Message to git

In a foreground session the commit approval gate prompts only for the plain
form: one line, `git [-C <path>] commit …`, every word bare or quoted, with no
`$`, backtick, or backslash inside double quotes. So:

- **A one-line message** goes in `-m`: `git commit -m 'feat: ✨ Add email validation endpoint.'`
- **A message with a body or footers** goes in a file. Write it to the session
  scratchpad, then run `git commit -F <absolute path>`. The gate reads the
  subject from the file's first line, so the prompt still names it.
- **Never use the heredoc form**, `git commit -m "$(cat <<'EOF' … EOF)"`. The
  gate refuses it, and the retry costs a round trip.

A sub-agent does not commit at all. It hands the message back in its report.

## Body & Footers

For details on body paragraphs, footer format, and breaking change indicators, read `references/conventional-commits.md`.

## Issue References

Only include for real issues being fixed. Each on its own line in the footer:

```
Fixes: #789
Fixes: #790
```
