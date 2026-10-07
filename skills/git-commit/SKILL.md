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

## Committing and pushing — the permission prompt

This section is the canonical statement of the foreground mechanics. Other
files state the lane rule and point here.

**A sub-agent does not commit or push, and never asks to.** It leaves the tree
uncommitted and hands the diff summary and this message back in its report. The
report does not invite a commit: prompting the human is the orchestrator's job.
The commit guard refuses its commit or push, by design. The scheduled Index
pipeline (`WORKBENCH_DEV_TEAM_PIPELINE=1`, set by `bin/dispatch-agent.sh`)
commits and pushes unattended, and never asks about committing or pushing.
Everything below is for the foreground session.

**Commit only after the human says to.** The approval is a "Commit it" pick in
`AskUserQuestion`, once the human says their review is done. Nothing else
counts: not a typed "commit it" in chat, not general approval of the task, not
"looks good" about the code, not an answer about how to split the commits, and
not approval of a previous commit.

**Offer the commit through `AskUserQuestion`, and ask it alone.** Ask it after
the human says their review is done. Do not offer the commit before then. If an
offer does reach the human early, "Not yet" leads. Never bundle the commit
question with another question or with follow-up work, and never put "commit"
into an option about other work. The question carries the branch and the
proposed message. Its options are "Not yet", "Review with Holmes first" when a
review is available, and "Commit it". Until the human has said their review is
done, the recommended first option is "Not yet" or "Review with Holmes first",
and "Commit it" goes last. Only after they say their review is done may
"Commit it" go first. The "Commit it" description always reads:
"Picking this confirms you have reviewed the whole tree." The reason is that
the human's review comments keep changing the tree. One click on an offer made
as the review starts would approve a tree they have not finished reading.

**Then attempt the commit yourself, and let Claude Code ask.** Do not hand it to
the human to run. `/workbench-dev-team:setup` installs ten `permissions.ask`
rules. Six are for commits and pushes: `git commit *`, `git push *`,
`git * commit *`, `git * push *`, `git * commit`, and `git * push`. Four are for
pull request merges: `gh pr merge:*`, `gh * pr merge *`, `gh * pr merge`, and
`gh api *pulls/*/merge*`. So the harness raises its own prompt for each commit,
each push, and each merge. That prompt is the mechanical backstop, not the
approval: a prompt that appears mid-flow gets answered without a review. Before you run the commit, re-read the staged diff
and confirm it is the tree the human approved.

**After an approved commit, attempt the push in the same turn.** Show the
branch, the remote, and the commits it sends, then run it and let the prompt
ask. Do not hand the push back as the human's step.

**Run it as a plain git line, so the rules see it.** The rules match a command
that starts with `git`, `git -C <path>` included, anywhere in a compound line.
They do not see a commit or push behind `bash -c`, `sh -c`, `env`, `eval`, a
leading `NAME=value` such as `HUSKY=0`, or a git named by its path, and the
commit guard refuses those forms. So:

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
the ask rules prompt a foreground `gh pr merge`, and the commit guard refuses
one from a sub-agent or from the pipeline.

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
