## Development workflow

For code implementation, bug fixes, refactors, and tests, use the `/workbench-dev-team:develop` skill.

## Git commits

For any git commit message — manual, scripted, or agent-driven — use the `/workbench-dev-team:git-commit` skill. It enforces Conventional Commits + Gitmoji format with full type/emoji references. This applies universally, not just to dev-team automation.

**Commit approval.** A sub-agent does not commit, merge, or push, and never asks to. It leaves the tree uncommitted and hands back the diff and the proposed commit message. The foreground session commits only after a "Commit it" pick in `AskUserQuestion`, once the human says their review is done. A typed "commit it" in chat does not count. The orchestrator asks the commit question alone, and recommends "Not yet" until the review is done. After the pick, it attempts the commit and the push itself as plain `git` lines. Claude Code's permission prompt is the mechanical backstop, not the approval. Index-mode development commits and pushes unattended, and never asks about committing or pushing.

## Dev-team delegation

Development goes to Dr. Watson, triage to Inspector Lestrade, and review to Sherlock Holmes. Anything that ends in a changed file goes to one of them, never to a generic agent. Invoke `/workbench-dev-team:orchestrate` before you dispatch one, and before you act on a request to review, comment, merge, or triage on GitHub.
