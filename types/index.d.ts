// The type contract of workbench-dev-team's hooks module: the values it keeps
// in $.state for the session. `claude plugin validate` holds every $.state key
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
    }
  }
}
