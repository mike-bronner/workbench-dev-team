# Opening a PR — foreground and pipeline lanes

On-demand detail for `skills/develop/SKILL.md`, §6. Read it as soon as you start
work on a tracked issue. A sub-agent opens no pull request, so it never needs
this file.

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
  slot for something required below (issue link, acceptance criteria, test
  plan), append it after the template content. No template → use the
  structure in the next bullets.
- **Use `Fixes #<n>`** in the body for auto-linking.
- **Pass the body as `--body-file - <<'EOF'`, or as a file**, never as a
  multi-line double-quoted string: the shell runs the backticks in one. The
  `/workbench-dev-team:git-commit` skill's "Passing a gh body" section is the
  canonical rule.
- **Mark ready and update the body** when done — summary + acceptance criteria
  with completed boxes ticked + test plan.
- **CI green is the real "done" line.** Local-green isn't enough — CI runs checks
  your machine may skip (strict lint gates, integration suites, environment
  differences). The work isn't done until CI is green. For automated or
  unattended work especially, wait for CI to finish and fix any failures before
  handing the PR off for review — never pass a red PR downstream.
