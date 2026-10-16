import { describe, expect, test } from 'claude-code/testing'

import { STUCK_AFTER, outputOf, stopBlockOf } from '../hooks/mods/helper-wait'
import type { GuardOptions } from './world'
import { BRIEF, spawnInput, step, world } from './world'

const T = (name: string) => `workbench-dev-team:${name}`

const WATSON = { id: 'agent-1', type: T('watson-direct') }

const background = (command: string, agentId?: string) =>
  ({ tool: 'Bash', tool_use_id: 'toolu_1', description: 'd', command, run_in_background: true, ...(agentId === undefined ? {} : { agentId }) }) as never

const inFlight = (id: string, command: string) => ({ id, type: 'shell', status: 'running', description: command, command })

const subagentStop = (agentId: string, tasks: ReturnType<typeof inFlight>[]) =>
  ({
    hook_event_name: 'SubagentStop',
    session_id: 's-1',
    transcript_path: '/t',
    cwd: '/tmp/repo',
    stop_hook_active: false,
    agent_id: agentId,
    agent_transcript_path: '/t/a',
    agent_type: T('watson-direct'),
    background_tasks: tasks,
  }) as never

async function withWatson($: { agent: { spawn: (e: never) => Promise<unknown> } }, on: Parameters<typeof world>[0], options: GuardOptions = {}) {
  const w = world(on, { agents: [WATSON], ...options })
  on('classic.SubagentStop', () => ({}))
  on('classic.Stop', () => ({}))
  await $.agent.spawn(spawnInput(T('watson'), BRIEF))
  return w
}

describe('helper wait — a dev-team sub-agent cannot end its turn while work it started is outstanding', () => {
  for (const status of ['running', 'pending', 'waiting']) {
    test(`a ${status} helper refuses the turn end and says to keep polling`, async ($, on) => {
      await withWatson($, on, { agents: [WATSON, { id: 'agent-9', type: T('holmes-lens'), parentId: 'agent-1', status }] })
      const result = await $.classic.SubagentStop(subagentStop('agent-1', []))
      expect(result.block).toContain('🛑 Blocked: you cannot end your turn')
      expect(result.block).toContain(`- helper agent-9 (holmes-lens, ${status}): a task`)
      expect(result.block).toContain('Keep making short tool calls, such as `sleep 20`, until each one reports.')
    })
  }

  test('a background command it started and still in flight refuses the turn end', async ($, on) => {
    const w = await withWatson($, on)
    w.background.push('b1')
    await $.tool.call(background('sleep 600', 'agent-1'))
    const result = await $.classic.SubagentStop(subagentStop('agent-1', [inFlight('b1', 'sleep 600')]))
    expect(result.block).toContain('- background command b1: sleep 600')
  })

  test('two background commands it started are both named', async ($, on) => {
    const w = await withWatson($, on)
    w.background.push('b1', 'b2')
    await $.tool.call(background('sleep 600', 'agent-1'))
    await $.tool.call(background('sleep 700', 'agent-1'))
    const result = await $.classic.SubagentStop(subagentStop('agent-1', [inFlight('b1', 'sleep 600'), inFlight('b2', 'sleep 700')]))
    expect(result.block).toContain('- background command b1: sleep 600')
    expect(result.block).toContain('- background command b2: sleep 700')
  })

  test('with nothing outstanding the turn ends normally', async ($, on) => {
    await withWatson($, on)
    expect(await $.classic.SubagentStop(subagentStop('agent-1', []))).toEqual({})
  })

  test('a background command that finished no longer holds the turn', async ($, on) => {
    const w = await withWatson($, on)
    w.background.push('b1')
    await $.tool.call(background('sleep 600', 'agent-1'))
    expect(await $.classic.SubagentStop(subagentStop('agent-1', []))).toEqual({})
  })

  test("another loop's background command does not hold this agent's turn", async ($, on) => {
    const w = await withWatson($, on)
    w.background.push('b1')
    await $.tool.call(background('sleep 600'))
    expect(await $.classic.SubagentStop(subagentStop('agent-1', [inFlight('b1', 'sleep 600')]))).toEqual({})
  })

  test("a finished helper, and another agent's live helper, do not hold the turn", async ($, on) => {
    await withWatson($, on, {
      agents: [WATSON, { id: 'agent-8', type: T('holmes-lens'), parentId: 'agent-1', status: 'completed' }, { id: 'agent-7', type: 'Explore', parentId: 'agent-5' }],
    })
    expect(await $.classic.SubagentStop(subagentStop('agent-1', []))).toEqual({})
  })

  test('a sub-agent outside the dev-team ends normally with a live helper', async ($, on) => {
    world(on, { agents: [{ id: 'agent-3', type: 'general-purpose' }, { id: 'agent-4', type: 'Explore', parentId: 'agent-3' }] })
    on('classic.SubagentStop', () => ({}))
    expect(await $.classic.SubagentStop(subagentStop('agent-3', []))).toEqual({})
  })

  test('the main session is never blocked, and its background command is not recorded', async ($, on) => {
    const w = await withWatson($, on, { agents: [WATSON, { id: 'agent-9', type: T('holmes-lens') }] })
    w.background.push('b1')
    await $.tool.call(background('sleep 600'))
    expect(await $.classic.Stop({ hook_event_name: 'Stop', session_id: 's-1', transcript_path: '/t', cwd: '/tmp/repo', stop_hook_active: false, background_tasks: [inFlight('b1', 'sleep 600')] } as never)).toEqual({})
  })

  test('a block from beneath stands as it is', async ($, on) => {
    world(on, { agents: [WATSON, { id: 'agent-9', type: T('holmes-lens'), parentId: 'agent-1' }] })
    on('classic.SubagentStop', () => ({ block: 'BENEATH' }))
    await $.agent.spawn(spawnInput(T('watson'), BRIEF))
    expect(await $.classic.SubagentStop(subagentStop('agent-1', []))).toEqual({ block: 'BENEATH' })
  })

  test('an agent list that cannot be read still holds the turn for a background command', async ($, on) => {
    const w = world(on, { agents: new Error('no list') })
    on('classic.SubagentStop', () => ({}))
    await $.agent.spawn(spawnInput(T('watson'), BRIEF))
    w.background.push('b1')
    await $.tool.call(background('sleep 600', 'agent-1'))
    const result = await $.classic.SubagentStop(subagentStop('agent-1', [inFlight('b1', 'sleep 600')]))
    expect(result.block).toContain('- background command b1: sleep 600')
  })
})

const LENS = (status = 'running') => ({ id: 'agent-9', type: T('holmes-lens'), parentId: 'agent-1', status })

const stop = ($: { classic: { SubagentStop: (e: never) => Promise<{ block?: string }> } }, tasks: ReturnType<typeof inFlight>[] = []) => $.classic.SubagentStop(subagentStop('agent-1', tasks))

describe('helper wait — a helper that makes no progress stops holding the turn', () => {
  test('a helper with no activity across two refusals is released, named, and the next turn end is allowed', async ($, on) => {
    await withWatson($, on, { agents: [WATSON, LENS()] })
    expect((await stop($ as never)).block).toContain('🛑 Blocked')
    expect((await stop($ as never)).block).toContain('🛑 Blocked')
    const release = (await stop($ as never)).block
    expect(release).toContain('made no progress across your last two attempts to end your turn')
    expect(release).toContain('- helper agent-9 (holmes-lens, running): a task')
    expect(release).toContain('Name each one in your report as work that looked stuck')
    expect(await stop($ as never)).toEqual({})
  })

  test('a helper whose model requests keep coming keeps the hold, however many refusals', async ($, on) => {
    await withWatson($, on, { agents: [WATSON, LENS()] })
    for (let round = 0; round < 6; round++) {
      expect((await stop($ as never)).block).toContain('🛑 Blocked')
      await step($ as never, 'agent-9')
    }
  })

  test('a helper whose tool calls keep coming keeps the hold', async ($, on) => {
    await withWatson($, on, { agents: [WATSON, LENS()] })
    for (let round = 0; round < 5; round++) {
      expect((await stop($ as never)).block).toContain('🛑 Blocked')
      await $.tool.call({ tool: 'Read', tool_use_id: 'toolu_r', file_path: '/tmp/repo/x', agentId: 'agent-9' } as never)
    }
  })

  test('a helper in the middle of a model request keeps the hold', async ($, on) => {
    await withWatson($, on, { agents: [WATSON, LENS()] })
    const stream = ($ as never as { turn: { step: (e: never) => AsyncGenerator<unknown, unknown> } }).turn.step({ turnId: 't', index: 0, model: 'm', messageCount: 1, agentId: 'agent-9' } as never)
    await stream.next()
    for (let round = 0; round < 5; round++) expect((await stop($ as never)).block).toContain('🛑 Blocked')
    let read = await stream.next()
    while (!read.done) read = await stream.next()
  })

  test('a quiet helper beside a busy one keeps the hold until the busy one is quiet too', async ($, on) => {
    await withWatson($, on, { agents: [WATSON, LENS(), { id: 'agent-8', type: T('holmes-lens'), parentId: 'agent-1' }] })
    for (let round = 0; round < 4; round++) {
      expect((await stop($ as never)).block).toContain('🛑 Blocked')
      await step($ as never, 'agent-8')
    }
    expect((await stop($ as never)).block).toContain('🛑 Blocked')
    expect((await stop($ as never)).block).toContain('🛑 Blocked')
    const release = (await stop($ as never)).block
    expect(release).toContain('- helper agent-9')
    expect(release).toContain('- helper agent-8')
  })

  test('no refusal names an action the agent has no tool for', async ($, on) => {
    const w = await withWatson($, on, { agents: [WATSON, LENS()] })
    w.background.push('b1')
    await $.tool.call(background('sleep 600', 'agent-1'))
    const block = (await stop($ as never, [inFlight('b1', 'sleep 600')])).block ?? ''
    expect(block).toContain('A helper or background command that makes no progress across two of your attempts to end your turn stops holding it')
    expect(block).not.toMatch(/stop it|TaskStop|kill|timeout/i)
  })
})

const OUTPUT = '/tasks/b1.output'

describe('helper wait — a background command whose output stops growing stops holding the turn', () => {
  async function withCommand($: never, on: Parameters<typeof world>[0]) {
    const w = await withWatson($, on)
    w.background.push('b1')
    await ($ as { tool: { call: (e: never) => Promise<unknown> } }).tool.call(background('tail -f /var/log/x', 'agent-1'))
    return w
  }
  const running = [inFlight('b1', 'tail -f /var/log/x')]

  test('a command whose output does not grow across two refusals is released, named, and the next turn end is allowed', async ($, on) => {
    const w = await withCommand($ as never, on)
    w.sizes.set(OUTPUT, 120)
    expect((await stop($ as never, running)).block).toContain('🛑 Blocked')
    expect((await stop($ as never, running)).block).toContain('🛑 Blocked')
    const release = (await stop($ as never, running)).block
    expect(release).toContain('made no progress across your last two attempts to end your turn')
    expect(release).toContain('- background command b1: tail -f /var/log/x')
    expect(release).toContain('a background command wrote no new output')
    expect(await stop($ as never, running)).toEqual({})
  })

  test('a command whose output keeps growing keeps the hold', async ($, on) => {
    const w = await withCommand($ as never, on)
    for (let round = 0; round < 6; round++) {
      w.sizes.set(OUTPUT, 100 + round)
      expect((await stop($ as never, running)).block).toContain('🛑 Blocked')
    }
  })

  test('a command whose output file cannot be read is released after two refusals, like a quiet one', async ($, on) => {
    await withCommand($ as never, on)
    expect((await stop($ as never, running)).block).toContain('🛑 Blocked')
    expect((await stop($ as never, running)).block).toContain('🛑 Blocked')
    expect((await stop($ as never, running)).block).toContain('- background command b1')
    expect(await stop($ as never, running)).toEqual({})
  })

  test('a quiet helper is not released while a command beside it still writes output', async ($, on) => {
    const w = await withWatson($, on, { agents: [WATSON, LENS()] })
    w.background.push('b1')
    await $.tool.call(background('tail -f /var/log/x', 'agent-1'))
    for (let round = 0; round < 4; round++) {
      w.sizes.set(OUTPUT, round)
      expect((await stop($ as never, running)).block).toContain('🛑 Blocked')
    }
  })
})

describe('helper wait — failures let the turn end, and every dev-team mode is held', () => {
  test('a state value the hook cannot use fails the hook, and the turn ends', async ($, on) => {
    let isBroken = false
    on('state.get', async ($, e, next) => (isBroken && e.key === 'backgroundTasks' ? ({ value: 42, version: 1 } as never) : next(e)))
    const w = await withWatson($, on)
    w.background.push('b1')
    await $.tool.call(background('sleep 600', 'agent-1'))
    expect((await stop($ as never, [inFlight('b1', 'sleep 600')])).block).toContain('🛑 Blocked')
    isBroken = true
    expect(await stop($ as never, [inFlight('b1', 'sleep 600')])).toEqual({})
  })

  test('an input with no background_tasks lets the turn end on a command it started', async ($, on) => {
    const w = await withWatson($, on)
    w.background.push('b1')
    await $.tool.call(background('sleep 600', 'agent-1'))
    const { background_tasks: _, ...input } = subagentStop('agent-1', []) as unknown as Record<string, unknown>
    expect(await $.classic.SubagentStop(input as never)).toEqual({})
  })

  for (const [type, prompt, extra] of [
    ['holmes', BRIEF, {}],
    ['lestrade', 'Item ID: 42', {}],
    ['holmes-lens', 'lens prompt', { parentAgentId: 'agent-h' }],
  ] as const) {
    test(`${type} with prompt ${JSON.stringify(prompt.split('\n')[0])} is held by a live helper`, async ($, on) => {
      world(on, { agents: [{ id: 'agent-1', type: T(type) }, LENS()] })
      on('classic.SubagentStop', () => ({}))
      await $.agent.spawn(spawnInput(T(type), prompt, extra))
      expect((await stop($ as never)).block).toContain('- helper agent-9 (holmes-lens, running)')
    })
  }
})

const NONE = { helper: () => undefined, outputSize: () => undefined }

describe('helper wait — the pure functions', () => {
  test('the output path is read from the Bash text for its own task id only', () => {
    expect(outputOf('b2', 'Command running in background with ID: b2. Output is being written to: /t/tasks/b2.output. You will be notified.')).toBe('/t/tasks/b2.output')
    expect(outputOf('b2', 'Command did not complete within its 120s timeout and was moved to the background (ID: b2). Output is being written to: /t/tasks/b2.output')).toBe('/t/tasks/b2.output')
    expect(outputOf('b2', 'Output is being written to: /t/tasks/b9.output.')).toBeUndefined()
    expect(outputOf('b2', 'Command running in background with ID: b2.')).toBeUndefined()
    expect(outputOf('b2', undefined)).toBeUndefined()
  })

  test('a command with no output path is released after two refusals', () => {
    const watches = new Map()
    const args = ['a', [], [{ id: 'b1' }], [{ id: 'b1', description: 'd' }], NONE, watches] as const
    expect(stopBlockOf(...args)).toContain('🛑 Blocked')
    expect(stopBlockOf(...args)).toContain('🛑 Blocked')
    expect(stopBlockOf(...args)).toContain('made no progress')
    expect(stopBlockOf(...args)).toBeUndefined()
  })

  test('a long command is clipped to 120 characters', () => {
    const block = stopBlockOf('a', [], [{ id: 'b1' }], [{ id: 'b1', description: 'd', command: 'x'.repeat(200) }], NONE, new Map())
    expect(block).toContain(`- background command b1: ${'x'.repeat(117)}...`)
  })

  test('a helper is named by its name before its description', () => {
    const block = stopBlockOf('a', [{ id: 'c', type: T('holmes-lens'), status: 'running', parentId: 'a', name: 'lens-ac', description: 'AC lens' }], [], [], NONE, new Map())
    expect(block).toContain('- helper c (holmes-lens, running): lens-ac')
  })

  test('nothing outstanding gives no block', () => {
    expect(stopBlockOf('a', [], [], [], NONE, new Map())).toBeUndefined()
  })

  test(`the release comes after ${STUCK_AFTER} quiet refusals, not before`, () => {
    const watches = new Map()
    const helper = [{ id: 'c', type: 'x', status: 'running', parentId: 'a', description: 'd' }]
    const quiet = { helper: () => ({ ticks: 4, inFlight: 0 }), outputSize: () => undefined }
    for (let attempt = 0; attempt < STUCK_AFTER; attempt++) expect(stopBlockOf('a', helper, [], [], quiet, watches)).toContain('🛑 Blocked')
    expect(stopBlockOf('a', helper, [], [], quiet, watches)).toContain('made no progress')
    expect(stopBlockOf('a', helper, [], [], quiet, watches)).toBeUndefined()
  })
})
