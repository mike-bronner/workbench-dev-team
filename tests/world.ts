// The world beneath workbench-dev-team's hooks module in `claude plugin test`.
// The test's hooks stand for the engine and for workbench-core: they add a
// stand-in $.workbench noun, answer every spawn, model request and Agent call
// the module passes on, and record what reached them.
//
// The stand-in briefCheck reads the six headers and the two token shapes only. The
// real check is workbench-core's, held to its bash gate case for case in that
// repository. What these tests prove is how this module weighs the answer.

import { mock } from 'claude-code/testing'
import type { On } from 'claude-code'

export const HOME = '/Users/tester'
export const CONFIG_PATH = `${HOME}/.claude-workbench/dev-team-config.json`

export const SLOTS = [
  { header: 'Workdir:', description: 'absolute path' },
  { header: 'Goal:', description: 'one or two sentences' },
  { header: 'Context:', description: 'why the task exists' },
  { header: 'Constraints:', description: 'hard limits, or none' },
  { header: 'Acceptance:', description: 'the criteria' },
  { header: 'Done when:', description: 'observable finish line' },
]

export const BRIEF = [
  'Workdir: /tmp/repo',
  'Goal: Fix the parser.',
  'Context: It drops a field.',
  'Constraints: none',
  'Acceptance:',
  '- AC1: the field survives',
  'Done when: the test passes.',
].join('\n')

type Lane = 'main' | 'sub-agent' | 'top-level-agent'

export type World = {
  // What callerLane answers, by the agentId it is asked about. An Error rejects.
  lane: (agentId: string | undefined) => Lane | Error
  isOn: boolean | Error
  // Makes briefCheck or briefSlots reject, or throw where it is called.
  checkFails: boolean | 'throw'
  // Answers briefCheck in place of the stand-in.
  check?: (prompt: string) => { isComplete: boolean; missing: string[]; shape: 'brief' | 'item-id' | 'repo-sweep' | 'blank' }
  files: Map<string, string>
  // Each spawn that reached the engine: its type, model and prompt.
  spawned: { subagentType: string; model?: string; prompt: string }[]
  // Each model request that reached the engine: its loop and effort.
  steps: { agentId?: string; effort?: unknown }[]
  // What the engine answers to an Agent call.
  agentCall: 'ok' | 'error'
  nextAgentId: number
}

function standInCheck(prompt: string) {
  const lines = prompt.split('\n')
  if (lines.filter(line => line.trim() !== '').length === 1 && /^\s*Item ID:\s*[0-9]+\s*$/.test(prompt)) {
    return { isComplete: true, missing: [], shape: 'item-id' as const }
  }
  if (lines.filter(line => line.trim() !== '').length === 1 && /^\s*Repo sweep:\s*[^\s/]+\/[^\s/]+\s*$/.test(prompt)) {
    return { isComplete: true, missing: [], shape: 'repo-sweep' as const }
  }
  const missing = SLOTS.map(slot => slot.header).filter(header => !lines.some(line => line.trimStart().startsWith(header)))
  return { isComplete: missing.length === 0, missing, shape: 'brief' as const }
}

export function world(
  on: On,
  options: Partial<Pick<World, 'lane' | 'isOn' | 'checkFails' | 'check'>> & { config?: string; envFails?: boolean } = {},
): World {
  const w: World = {
    lane: options.lane ?? (agentId => (agentId === undefined ? 'main' : 'sub-agent')),
    isOn: options.isOn ?? true,
    checkFails: options.checkFails ?? false,
    check: options.check,
    files: new Map(options.config === undefined ? [] : [[CONFIG_PATH, options.config]]),
    spawned: [],
    steps: [],
    agentCall: 'ok',
    nextAgentId: 1,
  }
  if (options.envFails) {
    on('env.get', async () => {
      throw new Error('env unreadable')
    })
  } else {
    mock.env(on, { HOME })
  }

  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    const answer = <T>(value: T | Error): Promise<T> => (value instanceof Error ? Promise.reject(value) : Promise.resolve(value))
    return {
      ...built,
      workbench: {
        briefSlots: async () => (w.checkFails ? Promise.reject(new Error('no template')) : SLOTS),
        briefCheck: (prompt: string) => {
          if (w.checkFails === 'throw') throw new Error('briefCheck threw')
          if (w.checkFails) return Promise.reject(new Error('no template'))
          return Promise.resolve((w.check ?? standInCheck)(prompt))
        },
        scratchRoots: async () => [],
        orchestratorIsOn: async () => answer(w.isOn),
        isUnattended: async () => false,
        callerLane: async (args: { agentId?: string }) => answer(w.lane(args.agentId)),
      },
    } as never
  })

  on('fs.read', async ($, e) => {
    const text = w.files.get(e.path)
    if (text === undefined) throw new Error(`ENOENT: ${e.path}`)
    return { value: text }
  })

  on('agent.spawn', async ($, e) => {
    w.spawned.push({ subagentType: e.subagentType, model: e.model, prompt: e.prompt })
    return { model: e.model ?? 'inherit', agentId: `agent-${w.nextAgentId++}` }
  })

  on('turn.step', async function* ($, e) {
    w.steps.push({ agentId: e.agentId, effort: e.effort })
    yield { kind: 'stop' as const, stopReason: 'end_turn' as const, usage: null }
    return { turnId: e.turnId, index: e.index, answer: '', toolUses: [], stopReason: 'end_turn' as const, usage: null }
  })

  on('tool.call', async ($, e) => {
    if (w.agentCall === 'error') return { isError: true, result: 'boom', text: 'boom' } as never
    return { result: { status: 'completed' } } as never
  })

  return w
}

// The input of agent.spawn as the Agent tool's call site passes it.
export function spawnInput(subagentType: string, prompt: string, extra: Record<string, unknown> = {}) {
  return {
    tool_use_id: `toolu_${subagentType}`,
    prompt,
    description: 'a task',
    subagentType,
    provider: { plugin: 'workbench-dev-team', tier: 'user' },
    parentModel: 'claude-opus-5-5[1m]',
    background: true,
    fork: false,
    ...extra,
  } as never
}

// One model request in the loop `agentId` names (main when undefined), read to
// its end as the engine would.
export async function step($: { turn: { step: (e: never) => AsyncGenerator<unknown, unknown> } }, agentId?: string, effort?: string): Promise<void> {
  const stream = $.turn.step({ turnId: 't', index: 0, model: 'm', messageCount: 1, agentId, effort } as never)
  let read = await stream.next()
  while (!read.done) read = await stream.next()
}
