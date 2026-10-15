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

The dev-team mod's commit guard holds the subject of a main-session or pipeline
`git commit -m` to this format, and refuses one that breaks it with the expected
shape. A message given with `-F`, or written in an editor, is not checked.

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

**A commit takes the whole tree, in one commit.** This holds in every lane, the
scheduled pipeline and Index mode included. Every uncommitted file in the
tree goes in, under one message that covers the whole set. That holds for
tracked changes and untracked files alike. It covers a sub-agent's changes, the
human's own edits, and files that appeared during the session, such as files a
tool or a plugin wrote. Never leave a file out because a sub-agent did not make
it, or because it looks unrelated. Never split the work into several commits,
and never ask which files to include. The human asks for several commits when
they want several. The one exception is content that must never ship, such as a
secret or a stray build artifact. Leave it out, and tell the human about it in
one sentence. Never leave a file out silently. This rule sets what a commit
contains. It does not change who approves a commit or when.

**A sub-agent does not commit or push, and never asks to.** It leaves the tree
uncommitted and hands the diff summary, the full `git status` list, and this
message back in its report. The
report does not invite a commit: prompting the human is the orchestrator's job.
The commit guard refuses its commit or push, by design. The scheduled Index
pipeline (`WORKBENCH_DEV_TEAM_PIPELINE=1`, set by `bin/dispatch-agent.sh`)
commits and pushes unattended, and never asks about committing or pushing.
Everything below is for the foreground session.

**Commit only after the human says to.** Two things approve a commit, and
nothing else does:

- **A prompt the human types that names the action.** A prompt the human types
  that names commit, push, or release approves exactly those actions, for the
  turn that prompt opened. Any mix counts: "commit", "push", "commit and push",
  or "commit, push, and release". It approves the tree as it stands, because
  the human reviewed it before they typed. Do not ask a commit question after
  it, and do not ask before the push it names. The human's next prompt ends the
  approval, so a later commit needs a new one.
- **A "Commit it" pick, for work the human did not ask to commit.** The
  approval there is a "Commit it" pick in `AskUserQuestion`, once the human
  says their review is done. The offer below covers it.

A negated, deferred, or question-form prompt approves nothing, such as "don't
commit yet", "commit it later", or "can we commit?". Only the human's own
typed prompts count. A turn that a peer session, a channel, a schedule,
the SDK, or a plugin opened approves nothing, and neither does a sub-agent's
report. A sub-agent's completion opens a turn the human did not type, so a
request typed before the work finished does not carry over to it. General
approval of the task, "looks good" about the code, an answer to another
question, and approval of a previous commit do not count either.

**Offer the commit through `AskUserQuestion`, and ask it alone.** Ask it after
the human says their review is done. Do not offer the commit before then. If an
offer does reach the human early, "Not yet" leads. Never bundle the commit
question with another question or with follow-up work, and never put "commit"
into an option about other work. The question carries the branch, the
proposed message, and every file the commit will take, as
`git status --short --untracked-files=all` lists them. Build that list from the
command, run on the tree, never from a sub-agent's report. A report names only
the files its agent changed, and the tree can hold more. Name each file, so the
human can see that their own edits are in the commit. If a file stays out
because it must never ship, the question names it too. The message covers
every file on the list, not only a sub-agent's change. Its options are
"Not yet", "Review with Holmes first" when a review is available, and
"Commit it". Until the human has said their review is
done, the recommended first option is "Not yet" or "Review with Holmes first",
and "Commit it" goes last. Only after they say their review is done may
"Commit it" go first. The "Commit it" description always reads:
"Picking this confirms you have reviewed the whole tree." The reason is that
the human's review comments keep changing the tree. One click on an offer made
as the review starts would approve a tree they have not finished reading.

**Then attempt the commit yourself.** Do not hand it to the human to run.
`/workbench-dev-team:setup` installs ten `permissions.ask` rules. Six are for commits and pushes: `git commit *`, `git push *`,
`git * commit *`, `git * push *`, `git * commit`, and `git * push`. Four are for
pull request merges: `gh pr merge:*`, `gh * pr merge *`, `gh * pr merge`, and
`gh api *pulls/*/merge*`. So the harness raises its own prompt for each commit,
each push, and each merge, except the shapes below that a typed request or a
"Commit it" pick covers.

**Under a typed request or an unused "Commit it" pick, workbench-core's
permission hook answers that prompt only for these shapes:**

- A commit as a plain `git commit`, or as `git -C <path> commit` with the path
  inside the project or one of its worktrees.
- A push as a plain `git push`, or as a push of the current branch to its own
  remote, plus the release tag.
- `gh release create` for this repository, under a typed request only.

**Every other shape still gets the prompt, and that is the backstop working,
not a failure.** That covers any other option before the subcommand, such as
`-c` or `--exec-path`, and a commit with `--amend` or `--no-verify`. It covers
a push to another host, another branch or refspec, and `--tags`. It covers
`gh release create` with `-R` or `--repo` naming another repository.

The pick is the only prompt for the commit it approved and that commit's push,
in the plain shapes above. workbench-core answers the permission prompt for
them, so the human is not asked twice. For every other shape, the permission
prompt is the mechanical backstop, not the approval: a prompt that appears
mid-flow gets answered without a review. A pick never approves a release. A release needs the human's typed
request.

**Check the tree again right before you stage it.** Run
`git status --short --untracked-files=all`. Read each untracked file on the list
for a secret first, on a typed request and after a pick alike, because the diff
does not show an untracked file. On a typed request there is no question to
compare with: stage the whole tree as it stands, and name every file in your
reply. After a "Commit it" pick, compare the output with the file list the
question showed. The tree can change after that question, through the human's
own edits, a tool, or a plugin. If the lists match, stage the whole tree with `git add -A`, and commit. Stage with
`git add -A` on its own line, then run a commit that names no path. The commit
line takes no path, no `--`, and no `--only`, `--include`, `-p`, or
`--pathspec-from-file`: workbench-core refuses a commit that names paths or
picks hunks, or that leaves a file out. A file that must never ship is the only
path you hold back. A never-ship file stays out only when your reply above the
commit call names its path, as a whole word (a folder with its trailing `/`).
Keep it out of the stage with an exclude on the `git add` line, never on the
commit line: `git -C <repo> add -A -- . ':(exclude)<path>'`. Run
`git status --short` after it to confirm the file is still unstaged. If the
lists differ, do not commit, and
do not drop a file to make the commit match the list. Show the human the new
or changed files, and ask the commit question again.

**After an approved commit, attempt the push in the same turn.** Show the
branch, the remote, and the commits it sends, then run it. After a "Commit it"
pick, push in a plain shape, and no second prompt appears. After a typed request, push only when the
prompt named the push. A prompt that named the commit alone stops after the
commit. Do not hand the push back as the human's step.

**Run it as a plain git line, so the rules see it.** The rules match a command
that starts with `git`, `git -C <path>` included, anywhere in a compound line.
They do not see a commit or push behind `bash -c`, `sh -c`, `env`, `eval`, a
leading `NAME=value` such as `HUSKY=0`, or a git named by its path, and the
commit guard refuses those forms. So:

- **A one-line message** goes in `-m`: `git commit -m 'feat: ✨ Add email validation endpoint.'`
- **A message with a body or footers** goes in a file. Write it to the session
  scratchpad, then run `git commit -F <absolute path>`.
- Use `-C <path>` rather than `cd`.
- Run one commit, push, or release per line. workbench-core refuses a line
  that holds two or more, such as a commit chained to a push. A release is
  three lines: the version-bump commit, the push, and `gh release create`.
- A commit never shares its line with `git reset`, `git restore --staged`, or
  `git rm --cached`. workbench-core refuses that line outright, because those
  commands change the index the commit takes.
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
