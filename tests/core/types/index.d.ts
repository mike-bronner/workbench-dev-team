// The type contract hooks/mods/shell.ts imports as '../../types' in
// workbench-core. Here it is the contract the engine lays from core into
// .claude-plugin/types/ when it loads this plugin, so the copy type-checks
// unedited against the core it is held to.
export type * from '../../../.claude-plugin/types/workbench-core/index'
