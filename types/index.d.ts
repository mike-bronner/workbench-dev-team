// The type contract of workbench-dev-team's hooks module: the values it keeps
// in $.state for the session, each one per agent. `claude plugin validate` holds every $.state key
// the module names to this file.
//
// The module adds no noun to $. It builds on workbench-core's $.workbench, which
// the engine types on $ because .claude-plugin/plugin.json lists workbench-core
// under "dependencies".

// ── The runs pane (hooks/mods/runs.ts) ──────────────────────────────────────

export type DevTeamAgent = 'lestrade' | 'holmes' | 'watson'

//   running        the dispatcher's process for the run is alive
//   done           the run ended with no error line
//   failed         the run ended on an API, execution or other error line
//   refused        the API refused the run's output (the content filter)
//   budget-killed  the run hit its USD budget cap
//   escalated      the breaker escalated the item after this run, its last
export type RunState = 'running' | 'done' | 'failed' | 'refused' | 'budget-killed' | 'escalated'

// One run. `target` is "item <id>" or "sweep <owner>-<repo>", `startedAt` the
// stamp in its log's name, and `refusals` the log's "Permission denied:"
// lines, one per tool call a rule, hook or prompt refused.
export type RunRow = { agent: DevTeamAgent; target: string; startedAt: string; state: RunState; refusals: number; log: string }

// What the runs pane draws: the rows, newest first, or why there are none.
export type RunsView = { rows: RunRow[]; error?: string }

// ── The board pane (hooks/mods/board.ts) ────────────────────────────────────

export type BoardItem = { id: number; number: number | null; isPr: boolean; repo: string | null; title: string | null; claimedAt: string | null }

// A lane: its items, at most `limit` of them, or the list tool's own error.
export type BoardLane = { limit: number; items: BoardItem[] } | { error: string }

export type Board = { unrefined: BoardLane; review: BoardLane; development: BoardLane }

// What the board pane draws:
//   attemptedAt  when the last fetch started (0: never); the cadence counts from it
//   board        the last board fetched, and boardAt, when that fetch started
//   error        why the last fetch failed, when it did
//   escalated    the items the breaker escalated, read from the log folder
export type BoardView = { attemptedAt: number; board?: Board; boardAt?: number; error?: string; escalated: string[] }

// An effort the config may give an agent: a level, as a hook may set a model
// request's `effort`.
export type DevTeamEffort = 'low' | 'medium' | 'high' | 'xhigh' | 'max'

declare module 'claude-code' {
  interface PluginState {
    'workbench-dev-team': {
      // The effort each dev-team sub-agent runs at, keyed by its agentId: set
      // when agent.spawn starts it, read by every turn.step of its loop.
      effort: StateFamily<DevTeamEffort>
      // The type each dev-team sub-agent runs as, holmes-lens included, keyed
      // by its agentId: set when agent.spawn starts it. The scratch folder, the
      // context budget and the holmes-lens rule read it.
      agentType: StateFamily<string>
      // Each dev-team agent's scratch folder, keyed by its agentId, or `run`
      // for the top-level loop of a `claude -p --agent` run: made at its first
      // bare mktemp, deleted and set to "" when its run completes.
      scratch: StateFamily<string>
      // Every scratch folder the mod made and has not deleted yet. A family
      // cannot be listed, so session.end reads this to delete what each run's
      // end left behind for a child that was still live.
      scratchFolders: string[]
      // Whether the human was told this run passed its context budget, keyed
      // as scratch is, so the notice comes once per run.
      overBudget: StateFamily<boolean>
      // What the runs pane draws: the newest dispatched runs, read from the
      // dispatch logs while the pane is open.
      runs: RunsView
      // What the board pane draws: The Index's three lanes as last fetched,
      // when the last fetch started, and the items the breaker escalated.
      board: BoardView
    }
  }
}
