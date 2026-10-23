---
name: git-commit
description: Generate commit messages using Conventional Commits + Gitmoji format. Use this skill whenever creating, drafting, or suggesting git commit messages — including /commit commands, pre-commit hooks, bulk commits, and any context where a commit message is being composed. Always invoke this skill before writing a commit message. Also carries the canonical rule for passing a body, comment, or release notes to gh.
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

workbench-core's commit subject check holds the subject of a `git commit -m` to
this format, and refuses one that breaks it with the expected shape. A message
given with `-F`, or written in an editor, is not checked.

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

## Committing and pushing

**A sub-agent does not commit or push, and never asks to.** It leaves the tree
uncommitted and hands the diff summary, the full `git status` list, and this
message back in its report. The report does not invite a commit. The
orchestrator takes the uncommitted tree from there. workbench-core's commit
guard refuses the sub-agent's commit or push, by design. The scheduled Index
pipeline (`WORKBENCH_DEV_TEAM_PIPELINE=1`, set by `bin/dispatch-agent.sh`) commits and
pushes unattended from the dispatcher's top-level run, and never asks about
committing or pushing. How Watson splits that work into commits is his own
judgment.

**The ask rules.** `/workbench-core:setup` installs the `permissions.ask` rules.
Eleven of them cover commits, pushes and merges. Six are for commits and
pushes: `git commit *`, `git push *`, `git * commit *`, `git * push *`,
`git * commit`, and `git * push`. Five are for merges: `gh pr merge:*`,
`gh * pr merge *`, `gh * pr merge`, and `gh api *pulls/*/merge*` for pull
requests, and `gh api *repos/*/merges*` for a branch merge through the REST
API. They raise the harness's permission prompt on
each commit, push, and merge, as the mechanical backstop.

**Run it as a plain git line, so the rules see it.** The rules match a command
that starts with `git`, `git -C <path>` included, anywhere in a compound line.
They do not see a commit or push behind `bash -c`, `sh -c`, `env`, `eval`, a
leading `NAME=value` such as `HUSKY=0`, or a git named by its path, and
workbench-core's commit guard refuses those forms. So:

- **A one-line message** goes in `-m`: `git commit -m 'feat: ✨ Add email validation endpoint.'`
- **A message with a body or footers** goes in a file. Write it to the session
  scratchpad, then run `git commit -F <absolute path>`.
- Use `-C <path>` rather than `cd`.
- Never commit or push through a shell alias such as `gp` or `gcmsg`, a script
  file, or an interpreter. The rules cannot see through any of them, so the
  commit or push would run with no prompt.

**What is never allowed.** A push that forces or deletes remote refs
(`--force`, `-f`, a `+` refspec, `--mirror`, `--delete`, `-d`, a `:branch`
refspec, `--prune`) is refused outright. Merge stays an explicit human request:
the ask rules prompt a foreground `gh pr merge`, and workbench-core's commit
guard refuses one from a sub-agent or from the pipeline.

**This is a mistake-catcher, not a security boundary.** It stops an honest agent
that moves too fast. It does not stop an agent that sets out to evade it, and
nothing checks that the staged diff is still the one the human saw. Never edit
the guard, and never set `WORKBENCH_DEV_TEAM_PIPELINE` yourself.

## Passing a gh body — PRs, issues, comments, and release notes

This section is the canonical rule for any `gh` call that carries prose. Other
files point here.

**The body stands on its own.** Restate what the reader needs, and never point
them at a local file, a scratchpad file, a plan file, or a vault note for it.
The scratchpad file in the second form below carries the body to gh. The body
never names it. The "Self-contained" principle in
`/workbench-dev-team:comms-style` is the canonical rule.

**Never put a multi-line body in a double-quoted string.** Inside double quotes,
bash and zsh run `$( )` and backticks, and Markdown uses backticks for code. So
``--notes "Run `make`"`` runs `make` before gh sees the text.

**Give the body in one of two forms:**

- **A heredoc with a quoted delimiter**, fed to the flag that reads standard
  input. The shell expands nothing in the body, so backticks and `$` stay text.

  ```bash
  gh pr edit 35 --body-file - <<'EOF'
  ## Summary
  Ships `phpcs.xml` again.
  EOF
  ```

  The flag is `--body-file -` for `pr create`, `pr edit`, `pr comment`,
  `pr review`, `issue create`, `issue edit`, and `issue comment`, and
  `--notes-file -` for `release create` and `release edit`. Put `<<'EOF'` last
  on the gh line, and put nothing after the closing `EOF` line.
- **A file**, written to the session scratchpad first and passed as
  `--body-file <absolute path>` or `--notes-file <absolute path>`.

**Keep the gh line itself plain:** literal words only, with no variable, no `cd`
before it, and no pipe or redirect. **Quote the delimiter.** A delimiter without
quotes (`<<EOF`) lets the shell expand the body, which is the same hazard as
double quotes. A short one-line
body with no backtick or `$` can stay in single quotes: `--body 'Fixes #12'`.

## Body & Footers

For details on body paragraphs, footer format, and breaking change indicators, read `references/conventional-commits.md`.

A commit body stands on its own, under the same rule as a gh body above.
Restate what the reader needs, and never point at a file they cannot open.

## Issue References

Only include for real issues being fixed. Each on its own line in the footer:

```
Fixes: #789
Fixes: #790
```
