## Development workflow

For any code implementation, bug fix, refactor, or test-writing — manual or agent-driven — use the `/workbench-dev-team:develop` skill. It enforces shared development standards: read repo conventions first, plan before coding, atomic commits, every change gets a test, no committed secrets. Includes a decision protocol that requires presenting three options to the human (with reasoning and a recommendation) for any meaningful fork — the human decides, the agent executes. Applies universally, not just to dev-team automation.

## Git commits

For any git commit message — manual, scripted, or agent-driven — use the `/workbench-dev-team:git-commit` skill. It enforces Conventional Commits + Gitmoji format with full type/emoji references. This applies universally, not just to dev-team automation.

**Commit approval gate — non-negotiable.** Never run `git commit` without explicit human approval of that specific commit: present the diff and the proposed message, then wait for an explicit yes. One approval covers one commit. A plugin `PreToolUse` hook enforces this at the harness level (forced permission prompt on every `git commit`); the only exemption is the autonomous Index pipeline, where board dispatch is the approval and Holmes review + human PR merge is the gate. Never set `WORKBENCH_DEV_TEAM_PIPELINE=1` or create `/tmp/watson.lock` to skip approval in interactive work.

## Dev-team delegation

A three-agent dev team is installed as sub-agents: Inspector Lestrade (triage), Dr. Watson (development — supports ad-hoc Direct mode), Sherlock Holmes (code review). For multi-step dev work, delegate to them as background sub-agents instead of doing the work in the main conversation — invoke the `/workbench-dev-team:orchestrate` skill for the dispatch protocol, per-agent model/effort config, and roster tracking. The skill also routes GitHub action requests (review, comment, merge, triage) to the correct executor — The Index MCP for repos its GitHub App governs, `gh` CLI for the user's own actions and ungoverned repos — so invoke it for those requests too.
