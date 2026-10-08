// hooks/register.ts with hooks/mods/dispatch.ts: a main-session Agent call to
// a dev-team agent. A Watson `Item ID: <n>` call runs the dispatcher in place
// of the spawn and answers with its first line, and every other dev-team call
// runs in the background unless it asked for the foreground.

import { describe, expect, test } from 'claude-code/testing'

import { DISPATCH_CONTEXT, dispatchOutcome, indexDispatchOf, isForcedBackground } from '../hooks/mods/dispatch'
import { BRIEF, HOME, world } from './world'

const T = (name: string) => `workbench-dev-team:${name}`
const DISPATCHER = `${HOME}/.claude-workbench/bin/dispatch-agent.sh`

const agentCall = (subagentType: string, prompt: string, extra: Record<string, unknown> = {}) =>
  ({ tool: 'Agent', tool_use_id: 'toolu_1', description: 'a task', prompt, subagent_type: subagentType, ...extra }) as never

type Answer = { deny?: string; result?: { status?: string; content?: { text: string }[] }; context?: string[] }

describe('Index-mode Watson — the dispatcher runs in place of the Agent call', () => {
  for (const [line, label] of [
    ['dispatched watson pid=4242 log=/Users/tester/.claude-workbench/dev-team-logs/watson-42-x.log', 'dispatched'],
    ['SKIP\ta run dispatched on this item is still alive (pid 7)', 'SKIP'],
    ['ESCALATE\tthe item is wedged', 'ESCALATE'],
    ['REPRIEVE\thuman re-activated a previously-escalated item', 'REPRIEVE'],
  ] as const) {
    test(`a ${label} first line is the call's answer, and nothing is spawned`, async ($, on) => {
      const w = world(on, { run: argv => (argv[1] === DISPATCHER ? { exitCode: 0, stdout: `${line}\nsecond line\n`, stderr: '' } : undefined) })
      const answer = (await $.tool.call(agentCall(T('watson'), 'Item ID: 42'))) as Answer
      expect(answer.deny).toBeUndefined()
      expect(answer.result?.status).toBe('completed')
      expect(answer.result?.content?.map(c => c.text)).toEqual([line])
      expect(answer.context).toEqual([DISPATCH_CONTEXT])
      expect(w.runs).toEqual([['bash', DISPATCHER, 'watson', '42']])
      expect(w.ran).toEqual([])
      expect(w.spawned).toEqual([])
    })
  }

  test('a mode type named directly, and blank lines around the token, dispatch too', async ($, on) => {
    const w = world(on, { run: () => ({ exitCode: 0, stdout: 'SKIP\tx\n', stderr: '' }) })
    await $.tool.call(agentCall(T('watson-index'), '\n  Item ID: 7  \n'))
    await $.tool.call(agentCall(T('watson-direct'), 'Item ID: 8'))
    expect(w.runs).toEqual([
      ['bash', DISPATCHER, 'watson', '7'],
      ['bash', DISPATCHER, 'watson', '8'],
    ])
    expect(w.ran).toEqual([])
  })

  test('a dispatcher that exits non-zero refuses the call with its reason, and spawns nothing', async ($, on) => {
    const w = world(on, { run: () => ({ exitCode: 1, stdout: '', stderr: 'dispatch-agent.sh: could not create a run folder\n' }) })
    const answer = (await $.tool.call(agentCall(T('watson'), 'Item ID: 42'))) as Answer
    expect(answer.deny).toContain('could not create a run folder')
    expect(answer.deny).toContain('Nothing was spawned')
    expect(w.ran).toEqual([])
  })

  test('a non-zero exit refuses the call even when the dispatcher printed a line', async ($, on) => {
    const w = world(on, { run: () => ({ exitCode: 2, stdout: 'usage: dispatch-agent.sh ...\n', stderr: '' }) })
    const answer = (await $.tool.call(agentCall(T('watson'), 'Item ID: 42'))) as Answer
    expect(answer.deny).toContain('usage: dispatch-agent.sh')
    expect(answer.result).toBeUndefined()
    expect(w.ran).toEqual([])
  })

  test('a dispatcher that cannot run refuses the call, never falls through to a spawn', async ($, on) => {
    const w = world(on, { run: () => new Error('ENOENT') })
    const answer = (await $.tool.call(agentCall(T('watson'), 'Item ID: 42'))) as Answer
    expect(answer.deny).toContain('the dispatcher could not run')
    expect(w.ran).toEqual([])
  })

  test('a dispatcher that prints nothing refuses the call', async ($, on) => {
    world(on, { run: () => ({ exitCode: 0, stdout: '\n', stderr: '' }) })
    const answer = (await $.tool.call(agentCall(T('watson'), 'Item ID: 42'))) as Answer
    expect(answer.deny).toContain('exit 0, no output')
  })

  test('with HOME unset the call is refused, and nothing runs', async ($, on) => {
    const w = world(on, { envFails: true })
    const answer = (await $.tool.call(agentCall(T('watson'), 'Item ID: 42'))) as Answer
    expect(answer.deny).toContain('HOME is not set')
    expect(w.runs).toEqual([])
    expect(w.ran).toEqual([])
  })

  // Direct mode, and everything that is not a main-session Watson token, is
  // left to the Agent tool exactly as before.
  for (const [label, type, prompt, extra] of [
    ['a Direct-mode brief', T('watson'), BRIEF, {}],
    ['a brief quoting the token', T('watson'), BRIEF.replace('It drops a field.', 'It drops a field, as Item ID: 9 showed.'), {}],
    ['a bare id, which the dispatch gate judges', T('watson'), '42', {}],
    ['Holmes with the token', T('holmes'), 'Item ID: 42', {}],
    ['a generic agent with the token', 'general-purpose', 'Item ID: 42', {}],
  ] as const) {
    test(`${label} reaches the Agent tool, and runs no dispatcher`, async ($, on) => {
      const w = world(on)
      const answer = (await $.tool.call(agentCall(type, prompt, extra))) as Answer
      expect(answer.deny).toBeUndefined()
      expect(w.runs.filter(argv => argv[1] === DISPATCHER)).toEqual([])
      expect(w.calls.map(c => c.prompt)).toEqual([prompt])
    })
  }

  test("a sub-agent's Watson token reaches the Agent tool, and runs no dispatcher", async ($, on) => {
    const w = world(on)
    await $.tool.call(agentCall(T('watson'), 'Item ID: 42', { agentId: 'agent-7' }))
    expect(w.runs).toEqual([])
    expect(w.ran).toEqual(['Agent: '])
  })

  for (const [label, lane] of [
    ['rejects', () => new Error('callerLane rejects before session start')],
    ['answers main', () => 'main' as const],
    ['answers sub-agent', () => 'sub-agent' as const],
  ] as const) {
    test(`a call with an agentId never runs the dispatcher when callerLane ${label}`, async ($, on) => {
      const w = world(on, { lane, run: () => ({ exitCode: 0, stdout: 'dispatched watson pid=1 log=x\n', stderr: '' }) })
      const answer = (await $.tool.call(agentCall(T('watson'), 'Item ID: 42', { agentId: 'agent-7' }))) as Answer
      expect(w.runs.filter(argv => argv[1] === DISPATCHER)).toEqual([])
      expect(answer.result?.content).toBeUndefined()
      expect(w.ran).toEqual(['Agent: '])
    })
  }

  test('a lane callerLane cannot give is read as the main session, so the dispatcher runs', async ($, on) => {
    const w = world(on, { lane: () => new Error('unknown'), run: () => ({ exitCode: 0, stdout: 'SKIP\tx\n', stderr: '' }) })
    await $.tool.call(agentCall(T('watson'), 'Item ID: 42'))
    expect(w.runs).toEqual([['bash', DISPATCHER, 'watson', '42']])
    expect(w.ran).toEqual([])
  })
})

describe('background by default — a main-session dev-team dispatch', () => {
  for (const type of ['watson', 'holmes', 'lestrade', 'holmes-local']) {
    test(`${type} with no run_in_background runs in the background`, async ($, on) => {
      const w = world(on)
      await $.tool.call(agentCall(T(type), BRIEF))
      expect(w.calls.map(c => c.run_in_background)).toEqual([true])
    })
  }

  test('a call that asked for the foreground stays in the foreground', async ($, on) => {
    const w = world(on)
    await $.tool.call(agentCall(T('watson'), BRIEF, { run_in_background: false }))
    expect(w.calls.map(c => c.run_in_background)).toEqual([false])
  })

  test('a call that asked for the background stays there', async ($, on) => {
    const w = world(on)
    await $.tool.call(agentCall(T('holmes'), BRIEF, { run_in_background: true }))
    expect(w.calls.map(c => c.run_in_background)).toEqual([true])
  })

  test('a generic agent, and holmes-lens, are left as the call set them', async ($, on) => {
    const w = world(on)
    await $.tool.call(agentCall('general-purpose', BRIEF))
    await $.tool.call(agentCall(T('holmes-lens'), BRIEF))
    expect(w.calls.map(c => c.run_in_background)).toEqual([undefined, undefined])
  })

  test("a sub-agent's dev-team dispatch is left as the call set it", async ($, on) => {
    const w = world(on)
    await $.tool.call(agentCall(T('holmes'), BRIEF, { agentId: 'agent-3' }))
    expect(w.calls.map(c => c.run_in_background)).toEqual([undefined])
  })
})

describe('dispatch — the pure rules', () => {
  test('indexDispatchOf takes only a whole `Item ID: <n>` to a Watson type', () => {
    expect(indexDispatchOf(T('watson'), 'Item ID: 42')).toBe('42')
    expect(indexDispatchOf(T('watson'), 'Item ID: 42\nplease')).toBeUndefined()
    expect(indexDispatchOf(T('watson'), 'PVTI_abc')).toBeUndefined()
    expect(indexDispatchOf(T('holmes'), 'Item ID: 42')).toBeUndefined()
    expect(indexDispatchOf('watson', 'Item ID: 42')).toBeUndefined()
    expect(indexDispatchOf(undefined, 'Item ID: 42')).toBeUndefined()
  })

  test('dispatchOutcome takes the first non-blank line, and refuses a non-zero exit', () => {
    expect(dispatchOutcome({ exitCode: 0, stdout: '\n\nSKIP\tx\nmore\n', stderr: '' })).toEqual({ line: 'SKIP\tx' })
    expect(dispatchOutcome({ exitCode: 2, stdout: '', stderr: 'usage: x\n' })).toHaveProperty('deny')
  })

  test('isForcedBackground leaves an explicit choice alone', () => {
    expect(isForcedBackground(T('watson'), undefined)).toBe(true)
    expect(isForcedBackground(T('watson'), false)).toBe(false)
    expect(isForcedBackground(T('watson'), true)).toBe(false)
    expect(isForcedBackground('Explore', undefined)).toBe(false)
  })
})
