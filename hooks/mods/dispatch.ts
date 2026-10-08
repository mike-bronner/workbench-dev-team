// What a main-session Agent call to a dev-team agent turns into, before it
// reaches agent.spawn, as pure functions. hooks/register.ts holds the hook.
//
//   1. A Watson Index-mode run goes through the dispatcher. Its prompt is the
//      whole token `Item ID: <n>`, and only bin/dispatch-agent.sh can give the
//      run its pipeline flag, so the hook runs the installed dispatcher in place
//      of the Agent call and answers the call with the dispatcher's first line:
//      dispatched, SKIP, ESCALATE or REPRIEVE. agent.spawn cannot answer a call
//      with text (its result is a started agent or a refusal), so this lives on
//      the Agent tool call itself, which a hook may answer with its own record.
//   2. A dev-team dispatch runs in the background unless the call asked for the
//      foreground: `run_in_background: false` is the caller's explicit ask, and
//      anything else is set to true.

import type { ToolResultOf } from 'claude-code'

import { familyOf, itemIdOf } from './spawn'

// Where /workbench-dev-team:setup installs the dispatcher, under $HOME.
export const DISPATCHER = '.claude-workbench/bin/dispatch-agent.sh'

// The item id a Watson Index-mode dispatch names, or undefined when the call
// is anything else: another agent, a brief, or a bare id (the dispatch gate
// refuses a bare id from the main session, so it never reaches the dispatcher).
export function indexDispatchOf(subagentType: unknown, prompt: unknown): string | undefined {
  if (typeof subagentType !== 'string' || typeof prompt !== 'string') return undefined
  if (familyOf(subagentType) !== 'watson') return undefined
  return itemIdOf(prompt)
}

// The command the hook runs: bash and the installed script, no shell between.
export const dispatcherArgv = (home: string, itemId: string): string[] => ['bash', `${home}/${DISPATCHER}`, 'watson', itemId]

const firstLine = (text: string): string | undefined => text.split('\n').find(line => line.trim() !== '')?.trim()

// What the dispatcher's run means for the Agent call: its first line, or a
// refusal when it exited non-zero or printed nothing. The dispatcher exits 0
// for every verdict, SKIP and ESCALATE included, so a non-zero exit is a bad
// argument or a run folder it could not make.
export function dispatchOutcome(run: { exitCode: number; stdout: string; stderr: string }): { line: string } | { deny: string } {
  const line = firstLine(run.stdout)
  if (run.exitCode === 0 && line !== undefined) return { line }
  const why = firstLine(run.stderr) ?? line ?? `exit ${run.exitCode}, no output`
  return { deny: dispatchDeny(`the dispatcher refused the run: ${why}`) }
}

export function dispatchDeny(why: string): string {
  return [
    `🛑 Blocked: a Watson Index-mode dispatch, because ${why}.`,
    '',
    'Dispatch gate (workbench-dev-team). A Watson `Item ID: <n>` dispatch runs through ~/.claude-workbench/bin/dispatch-agent.sh, which the dev-team mod runs in place of the Agent call. ' +
      'Nothing was spawned and no board item moved. Relay this to the human, and do not retry through the Agent tool.',
  ].join('\n')
}

// What the model reads beside the line: what each first line means.
export const DISPATCH_CONTEXT =
  'The dev-team mod ran ~/.claude-workbench/bin/dispatch-agent.sh in place of this Agent call, because only the dispatcher gives a Watson Index-mode run its pipeline flag. ' +
  'No sub-agent started here, so no completion notification will come. The result is the dispatcher\'s first line. ' +
  '"dispatched watson pid=... log=..." means the run started: track it from that log, and look there for "Permission denied:" lines, one per refused call. ' +
  '"REPRIEVE" means a human re-activated an escalated item, and the run started with a raised budget. ' +
  '"SKIP" (a run on that item is still alive) and "ESCALATE" (the breaker judges the item wedged) mean nothing was spawned: relay the line to the human rather than retrying.'

// The Agent tool's own record for a call the hook answered: completed, with the
// line as its text. Core checks it against the tool's output schema.
export function dispatchResult(line: string, prompt: string): ToolResultOf<'Agent'> {
  return {
    status: 'completed',
    agentId: 'dispatch-agent.sh',
    content: [{ type: 'text', text: line }],
    totalToolUseCount: 0,
    totalDurationMs: 0,
    totalTokens: 0,
    prompt,
    usage: {
      input_tokens: 0,
      output_tokens: 0,
      cache_creation_input_tokens: null,
      cache_read_input_tokens: null,
      server_tool_use: null,
      service_tier: null,
      cache_creation: null,
    },
  }
}

// Whether a dev-team dispatch must be put in the background: every one whose
// call did not set run_in_background to false.
export const isForcedBackground = (subagentType: unknown, runInBackground: unknown): boolean =>
  typeof subagentType === 'string' && familyOf(subagentType) !== undefined && runInBackground !== false && runInBackground !== true
