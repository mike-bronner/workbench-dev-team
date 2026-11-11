# Is a background agent still alive?

Judge a background agent's liveness by the task list and by whether its
transcript still grows. Never judge it by `ListAgents`.

`ListAgents` can report an agent as `completed` while the task list still
counts it as a running background agent. On 2026-11-10 a Holmes Local run
sat idle for about 8 hours in that state. `ListAgents` said `completed`, while
the status bar and the background task list showed it as running. It ended
only when the orchestrator stopped it with `TaskStop`.

- **The task list says whether the harness counts it as running.** Read the
  status bar, the background task list, and the agent's last task
  notification. An agent that any of them still shows as running is not
  finished, whatever `ListAgents` says.
- **Transcript growth says whether it still works.** Its transcript is
  `subagents/agent-<agent id>.jsonl` under the session's folder in the
  projects folder of the config. Read the file's size or the timestamp of its
  last entry twice, a few minutes apart.
- **Running, with no growth across those minutes, is stuck.** Read its last
  few entries. If its hand-back already reached you, stop it with `TaskStop`.
  If not, report it to the human as stuck, with its last entry, and ask before
  you stop it.
