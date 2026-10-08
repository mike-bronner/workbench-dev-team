// The type contract of workbench-dev-team's hooks module: the values it keeps
// in $.state for the session, each one per agent. `claude plugin validate` holds every $.state key
// the module names to this file.
//
// The module adds no noun to $. It builds on workbench-core's $.workbench, which
// the engine types on $ because .claude-plugin/plugin.json lists workbench-core
// under "dependencies".

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
    }
  }
}
