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

## Committing and pushing — the approval gate

This section is the canonical statement of the foreground mechanics. Other
files state the lane rule and point here.

**A sub-agent does not commit, merge, or push.** It leaves the tree
uncommitted and hands the diff summary and this message back in its report.
The gate refuses it with no approval path, by design. The scheduled Index
pipeline (`WORKBENCH_DEV_TEAM_PIPELINE=1`, set by `bin/dispatch-agent.sh`)
commits unattended. Everything below is for the foreground session.

**Attempt the commit or the push yourself, and let the gate prompt.** Do not
hand either one to the human to run: the gate is how the human is asked. It
denies every `git commit` and every `git push` until the human approves that
exact command.

**Write the plain form, or it is refused.** The gate does not parse shell. It
prompts only for one line that is exactly `git [-C <path>] commit …`,
`git [-C <path>] push …`, or `git [-C <path>] commit … && git [-C <path>] push …`,
with every word bare or quoted. A double-quoted string may not hold `$`, a
backtick, or a backslash. There is no `cd`, pipe, redirect, comment, heredoc,
variable, wrapper, or second line, and no bare word that starts with `=`. Any
other command whose text names git and a commit or push is refused with no
approval path. So:

- Run `git add` as its own call, never chained to the commit.
- **A one-line message** goes in `-m`: `git commit -m 'feat: ✨ Add email validation endpoint.'`
- **A message with a body or footers** goes in a file. Write it to the session
  scratchpad, then run `git commit -F <absolute path>`. The gate reads the
  subject from the file's first line, so the prompt still names it.
- **Never use the heredoc form**, `git commit -m "$(cat <<'EOF' … EOF)"`. The
  gate refuses it, and the retry costs a round trip.
- Use `-C <path>` rather than `cd`.
- Never use a shell alias such as `gp` or `gcmsg`. The gate cannot see through
  one, so it would commit or push unprompted.

**Before the approval, show what it approves.** For a commit, show the diff that
will be committed and the proposed message. For a push, show the branch, the
remote, and the commits it sends. General approval of the task, "looks good"
about the code, or approval of a previous commit do not carry over: one approval
covers one command.

**Then run the command the denial prints**, exactly as printed:
`bash "$HOME/.claude-workbench/bin/approve-commit.sh" <request-id> "<commit subject>"`
for a commit, and the same command with no subject for a push. Set the Bash
call's `description` to the line the denial dictates. Permission rules cover
that command, so the harness raises a real prompt, and the human's answer is the
approval. Then run the same `git commit` or `git push` again, from the same
directory.

**What an approval binds.** One run of one command, in that session and
directory, for 15 minutes. A commit is also bound to HEAD and the staged diff,
and to the working tree when it takes files from there (`-a`, `--only`,
`--include`, or a pathspec). A push is bound to the repository's branches, tags,
HEAD, and its remote, branch, push, and url config. Any change before it runs
voids the approval and asks again.

**What is never approved.** A push that forces or deletes remote refs
(`--force`, `-f`, a `+` refspec, `--mirror`, `--delete`, `-d`, a `:branch`
refspec, `--prune`) is refused with no approval path. Merge stays an explicit
human request.

If `approve-commit.sh` refuses (missing permission rules, or an id with nothing
waiting), report that and stop: `/workbench-dev-team:setup` installs the command
and its rules. Never edit the gate, never set `WORKBENCH_DEV_TEAM_PIPELINE`, and
never write an approval record by hand.

## Passing a gh body — PRs, issues, comments, and release notes

This section is the canonical rule for any `gh` call that carries prose. Other
files point here.

**Never put a multi-line body in a double-quoted string.** Inside double quotes,
bash and zsh run `$( )` and backticks, and Markdown uses backticks for code. So
``--notes "Run `make`"`` runs `make` before gh sees the text. The gate refuses that
shape for this reason, and the retry costs a round trip.

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

**Keep the gh line itself plain.** The gate reads it by its own words: literal
words only, with no variable, no `cd` before it, and no pipe or redirect. A
delimiter without quotes (`<<EOF`) is refused, because the shell expands the
body. A short one-line body with no backtick or `$` can stay in single quotes:
`--body 'Fixes #12'`.

## Body & Footers

For details on body paragraphs, footer format, and breaking change indicators, read `references/conventional-commits.md`.

## Issue References

Only include for real issues being fixed. Each on its own line in the footer:

```
Fixes: #789
Fixes: #790
```
