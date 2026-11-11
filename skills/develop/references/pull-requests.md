# Opening a PR — foreground and pipeline lanes

On-demand detail for `skills/develop/SKILL.md`, §6. Read it as soon as you start
work on a tracked issue. A sub-agent opens no pull request, so it never needs
this file.

**Never request a reviewer on any PR, tracked issue or not.** Mike requests
every review himself. The rule covers all four routes:
- a reviewer named when the PR is created (`gh pr create --reviewer`)
- a reviewer added to an existing PR (`gh pr edit --add-reviewer`)
- the requested-reviewers API (`.../pulls/<n>/requested_reviewers`)
- a comment that asks a bot or a person to review, such as `@coderabbitai review`

When the work is for a tracked issue:

- **Create the PR as a draft early** — before implementation is complete.
  Visible work-in-progress is better than a black-box dump at the end.
- **Use the repo's PR template when one exists.** `gh pr create --body`
  silently bypasses templates, so discover and apply it yourself. Check, in
  order: `.github/PULL_REQUEST_TEMPLATE.md`, `PULL_REQUEST_TEMPLATE.md`
  (root), `docs/PULL_REQUEST_TEMPLATE.md` — any letter case — and
  `.github/PULL_REQUEST_TEMPLATE/` (multiple templates; pick the one that
  fits the change, or the default). Fill its sections honestly — never leave
  boilerplate placeholders or HTML comments behind. If the template has no
  slot for something required below (issue link, test plan), append it after
  the template content. No template → use the structure in the next bullets.
- **Use `Fixes #<n>`** in the body for auto-linking.
- **Link the issue, and never copy its acceptance criteria into the body.**
  The criteria live only in the issue. `Fixes #<n>` links it, and review bots
  such as CodeRabbit read the linked issue directly. A copy in the body drifts
  from the issue. So never restate or append the criteria, even when the
  template has no slot for them.
- **Tick each criterion in the issue as you meet it.** Where the criteria sit
  depends on the mode:
  - Off the board, in Direct mode or on any PR worked outside The Index, they
    sit in the issue body. Tick each met criterion there.
  - On The Index board, they sit in a managed comment that Lestrade's GitHub
    App owns, with `<!-- acceptance-criteria -->` on its first line. Tick them
    there only through an Index tool, once The Index provides one. Never edit
    that comment with `gh`. Until the tool exists, leave its boxes as they are.
  - A board item triaged before the criteria moved to that comment has no such
    comment. Its criteria sit in the issue body. Leave those boxes as they
    are, and never edit the body with `gh`.
- **Pass the body as `--body-file - <<'EOF'`, or as a file**, never as a
  multi-line double-quoted string: the shell runs the backticks in one. The
  `/workbench-dev-team:git-commit` skill's "Passing a gh body" section is the
  canonical rule.
- **Write a body that stands on its own.** Restate what the reviewer needs,
  and never point at a local file, a scratchpad file, a plan file, or a vault
  note for it.
  The "Self-contained" principle in `/workbench-dev-team:comms-style` is the
  canonical rule.
- **Mark ready and update the body** when done — summary + test plan. The
  acceptance criteria stay in the issue.
- **CI green is the real "done" line.** Local-green isn't enough — CI runs checks
  your machine may skip (strict lint gates, integration suites, environment
  differences). The work isn't done until CI is green. For automated or
  unattended work especially, wait for CI to finish and fix any failures before
  handing the PR off for review — never pass a red PR downstream.
