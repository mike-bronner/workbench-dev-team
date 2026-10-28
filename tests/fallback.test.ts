import { describe, expect, test } from 'claude-code/testing'
import type { On, PromptComposeSection } from 'claude-code'

import { markerOf, sessionDirOf, sweepArgvsOf, waitFileOf } from '../hooks/mods/fallback'
import type { Watch } from '../hooks/mods/helper-wait'
import { inFlightOf, snapshotOf, stopBlockOf, waitStateFrom, watchesFrom, watchesText } from '../hooks/mods/helper-wait'
import { RULES } from '../hooks/mods/session-rules'
import { BRIEF, HOME, SESSION_ID, spawnInput, step, world } from './world'
import type { GuardOptions, World } from './world'

const T = (name: string) => `workbench-dev-team:${name}`
const WATSON = { id: 'agent-1', type: T('watson-direct') }
const HELPER = { id: 'agent-9', type: T('holmes-lens'), parentId: 'agent-1' }
const MOD_RAN = `${HOME}/.claude-workbench/dev-team-mod-ran/${SESSION_ID}`
const SNAPSHOT = `${HOME}/.claude-workbench/dev-team-helper-wait/${SESSION_ID}/agent-1.snapshot.json`
const COMPOSE = { model: 'claude-opus-5-5', promptModel: 'claude-opus-5-5', surfaces: ['terminal' as const], tools: [], outputStyle: null, traits: [] }
const BENEATH: PromptComposeSection[] = [{ id: 'intro', text: 'You are Claude Code.', scope: 'shared' }]

const isMarker = (path: string): boolean => path.includes('/dev-team-mod-ran/')
const sessionStart = { session_id: SESSION_ID, transcript_path: '/t', cwd: '/repo', hook_event_name: 'SessionStart', source: 'startup' } as never
const subagentStart = (agentType: string) => ({ session_id: SESSION_ID, transcript_path: '/t', cwd: '/repo', hook_event_name: 'SubagentStart', agent_id: 'agent-1', agent_type: agentType }) as never
const inFlight = (id: string, command: string) => ({ id, type: 'shell', status: 'running', description: command, command })
const subagentStop = (tasks: ReturnType<typeof inFlight>[]) =>
  ({
    hook_event_name: 'SubagentStop',
    session_id: SESSION_ID,
    transcript_path: '/t',
    cwd: '/repo',
    stop_hook_active: false,
    agent_id: 'agent-1',
    agent_transcript_path: '/t/a',
    agent_type: T('watson-direct'),
    background_tasks: tasks,
  }) as never
const background = (command: string) => ({ tool: 'Bash', tool_use_id: 'toolu_1', description: 'd', command, run_in_background: true, agentId: 'agent-1' }) as never

function engine(on: On, options: GuardOptions = {}): { w: World; seen: string[] } {
  const w = world(on, options)
  const seen: string[] = []
  const saw = (event: string) => seen.push(`${event}:${[...w.files.keys()].filter(isMarker).length}`)
  on('classic.SessionStart', () => (saw('SessionStart'), {}))
  on('classic.SubagentStart', () => (saw('SubagentStart'), { additionalContext: ['BENEATH'] }))
  on('classic.SubagentStop', () => (saw('SubagentStop'), {}))
  on('prompt.compose', () => (saw('compose'), { sections: BENEATH }))
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('command.register', ($, e) => ({ value: { command: e.name } }))
  on('ui.panes', () => ({ value: [] }) as never)
  return { w, seen }
}

async function watsonRun($: { agent: { spawn: (e: never) => Promise<unknown> } }, on: On, agents: GuardOptions['agents']) {
  const { w } = engine(on, { agents })
  await $.agent.spawn(spawnInput(T('watson'), BRIEF))
  return w
}

function fallbackOf(w: World, tasks: unknown, watches: Map<string, Watch>): string | undefined {
  const text = w.files.get(SNAPSHOT)
  const state = text === undefined ? undefined : waitStateFrom(text)
  if (state === undefined) return undefined
  return stopBlockOf('agent-1', state.agents, state.started, inFlightOf(tasks), { helper: id => state.activity.get(id), outputSize: path => w.sizes.get(path) }, watches)
}

const holds = (block: string | undefined): string => (block === undefined ? 'ends' : block.startsWith('🛑') ? 'held' : 'released')

describe('AC3: each skipped hook marks the session before the hooks beneath it run', () => {
  test('classic.SessionStart', async ($, on) => {
    const { seen } = engine(on)
    await $.classic.SessionStart(sessionStart)
    expect(seen).toEqual(['SessionStart:1'])
  })

  test('classic.SubagentStart', async ($, on) => {
    const { seen } = engine(on)
    await $.classic.SubagentStart(subagentStart('general-purpose'))
    expect(seen).toEqual(['SubagentStart:1'])
  })

  test('classic.SubagentStop', async ($, on) => {
    const { seen } = engine(on)
    await $.classic.SubagentStop(subagentStop([]))
    expect(seen).toEqual(['SubagentStop:1'])
  })

  test('prompt.compose', async ($, on) => {
    const { seen } = engine(on)
    await $.prompt.compose(COMPOSE)
    expect(seen).toEqual(['compose:1'])
  })

  test('each marker is a file in the session folder the fallbacks read', async ($, on) => {
    const { w } = engine(on)
    await $.classic.SessionStart(sessionStart)
    await $.classic.SubagentStart(subagentStart('general-purpose'))
    await $.classic.SubagentStop(subagentStop([]))
    expect([...w.files.keys()].filter(isMarker).sort()).toEqual([`${MOD_RAN}/session-start`, `${MOD_RAN}/subagent-start`, `${MOD_RAN}/subagent-stop`])
    expect(markerOf(HOME, SESSION_ID, 'session-start')?.startsWith(`${sessionDirOf(HOME, SESSION_ID)}/`)).toBe(true)
  })

  test('a rejected marker write leaves every result as it was', async ($, on) => {
    const { w } = engine(on)
    const run = async () => ({
      start: await $.classic.SessionStart(sessionStart),
      subagent: await $.classic.SubagentStart(subagentStart('general-purpose')),
      stop: await $.classic.SubagentStop(subagentStop([])),
      compose: await $.prompt.compose(COMPOSE),
    })
    const kept = await run()
    w.files.clear()
    w.writeRejects = isMarker
    expect(await run()).toEqual(kept)
    expect([...w.files.keys()].filter(isMarker)).toEqual([])
    expect(kept.subagent.additionalContext).toEqual(['BENEATH', RULES])
  })

  test('prompt.compose writes its marker once per session, and tries again after a failed write', async ($, on) => {
    const { w } = engine(on)
    const writes: string[] = []
    w.writeRejects = path => (writes.push(path), true)
    await $.prompt.compose(COMPOSE)
    w.writeRejects = path => (writes.push(path), false)
    await $.prompt.compose(COMPOSE)
    await $.prompt.compose(COMPOSE)
    expect(writes).toEqual([`${MOD_RAN}/prompt-compose`, `${MOD_RAN}/prompt-compose`])
  })
})

describe('the helper-wait record the SubagentStop fallback reads', () => {
  test('with no marker, a dev-team agent records its helpers, its commands and their progress at each step', async ($, on) => {
    const w = await watsonRun($, on, [WATSON, HELPER, { id: 'agent-5', type: 'Explore', parentId: 'agent-2' }])
    w.background.push('b1')
    await $.tool.call(background('sleep 600'))
    await step($, 'agent-9')
    await step($, 'agent-1')
    expect(JSON.parse(w.files.get(SNAPSHOT) ?? 'null')).toEqual({
      agents: [{ id: 'agent-9', type: T('holmes-lens'), status: 'running', description: 'a task', parentId: 'agent-1' }],
      started: [{ id: 'b1', output: '/tasks/b1.output' }],
      activity: [['agent-9', { ticks: 1, inFlight: 0 }]],
    })
  })

  test('once a skipped hook marked the session, no step records anything', async ($, on) => {
    const w = await watsonRun($, on, [WATSON, HELPER])
    await $.classic.SubagentStart(subagentStart(T('watson-direct')))
    await step($, 'agent-1')
    expect(w.files.has(SNAPSHOT)).toBe(false)
  })

  test('a marker write that failed does not stop the record', async ($, on) => {
    const w = await watsonRun($, on, [WATSON, HELPER])
    w.writeRejects = path => isMarker(path) && path.includes(`/${SESSION_ID}/`)
    await $.classic.SubagentStart(subagentStart(T('watson-direct')))
    await step($, 'agent-1')
    expect(w.files.has(SNAPSHOT)).toBe(true)
  })

  test('an agent outside the dev-team, and the main loop, record nothing', async ($, on) => {
    const { w } = engine(on, { agents: [{ id: 'agent-1', type: 'general-purpose' }] })
    await $.agent.spawn(spawnInput('general-purpose', BRIEF))
    await step($, 'agent-1')
    await step($)
    expect([...w.files.keys()].filter(path => path.includes('/dev-team-helper-wait/'))).toEqual([])
  })

  test('a record that cannot be written leaves the step as it was', async ($, on) => {
    const w = await watsonRun($, on, [WATSON, HELPER])
    w.writeRejects = () => true
    await step($, 'agent-1')
    expect(w.steps.map(s => s.agentId)).toEqual(['agent-1'])
  })
})

describe('AC2: from the record alone, stopBlockOf answers what the module answers', () => {
  async function rounds($: Parameters<typeof watsonRun>[0] & { classic: { SubagentStop: (e: never) => Promise<{ block?: string }> } }, w: World, tasks: ReturnType<typeof inFlight>[], between: (round: number) => Promise<void>) {
    w.writeRejects = isMarker
    const watches = new Map<string, Watch>()
    const seen: string[] = []
    for (let round = 0; round < 4; round++) {
      await between(round)
      await step($ as never, 'agent-1')
      const fallback = fallbackOf(w, tasks, watches)
      const result = await $.classic.SubagentStop(subagentStop(tasks))
      expect(fallback).toBe(result.block)
      seen.push(holds(fallback))
    }
    return seen
  }

  test('a helper that makes no progress: held twice, released and named, then the turn ends', async ($, on) => {
    const w = await watsonRun($, on, [WATSON, HELPER])
    expect(await rounds($, w, [], async () => undefined)).toEqual(['held', 'held', 'released', 'ends'])
  })

  test('a helper that keeps stepping holds every round', async ($, on) => {
    const w = await watsonRun($, on, [WATSON, HELPER])
    expect(await rounds($, w, [], () => step($, 'agent-9'))).toEqual(['held', 'held', 'held', 'held'])
  })

  test('a background command whose output grows holds every round', async ($, on) => {
    const w = await watsonRun($, on, [WATSON])
    w.background.push('b1')
    await $.tool.call(background('sleep 600'))
    expect(await rounds($, w, [inFlight('b1', 'sleep 600')], async round => void w.sizes.set('/tasks/b1.output', round + 1))).toEqual(['held', 'held', 'held', 'held'])
  })

  test('a background command whose output stays the same is released after two holds', async ($, on) => {
    const w = await watsonRun($, on, [WATSON])
    w.background.push('b1')
    await $.tool.call(background('sleep 600'))
    w.sizes.set('/tasks/b1.output', 5)
    expect(await rounds($, w, [inFlight('b1', 'sleep 600')], async () => undefined)).toEqual(['held', 'held', 'released', 'ends'])
  })

  test('with nothing outstanding, both let the turn end', async ($, on) => {
    const w = await watsonRun($, on, [WATSON, { ...HELPER, status: 'completed' }])
    expect(await rounds($, w, [], async () => undefined)).toEqual(['ends', 'ends', 'ends', 'ends'])
  })
})

describe('the sweep', () => {
  test('the session start runs it on both folders, files first', async ($, on) => {
    const { w } = engine(on)
    await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
    for (let i = 0; i < 20; i++) await Promise.resolve()
    expect(w.runs.filter(argv => argv[0] === 'find')).toEqual(sweepArgvsOf(HOME))
  })

  test('it names both folders, 7 days, and nothing with a home that is not absolute', () => {
    const wb = `${HOME}/.claude-workbench`
    expect(sweepArgvsOf(HOME)).toEqual([
      ['find', `${wb}/dev-team-mod-ran`, `${wb}/dev-team-helper-wait`, '-mindepth', '2', '-type', 'f', '-mtime', '+7', '-delete'],
      ['find', `${wb}/dev-team-mod-ran`, `${wb}/dev-team-helper-wait`, '-mindepth', '1', '-type', 'd', '-empty', '-delete'],
    ])
    expect(sweepArgvsOf('relative')).toEqual([])
    expect(sweepArgvsOf(undefined)).toEqual([])
  })
})

describe('the readers', () => {
  test('paths stay under HOME, and refuse an id that could name another folder', () => {
    expect(sessionDirOf(HOME, SESSION_ID)).toBe(MOD_RAN)
    expect(waitFileOf(HOME, SESSION_ID, 'agent-1', 'snapshot')).toBe(SNAPSHOT)
    expect(sessionDirOf(HOME, '../x')).toBeUndefined()
    expect(waitFileOf(HOME, SESSION_ID, 'x/../agent-1', 'watches')).toBeUndefined()
    expect(waitFileOf(HOME, '.', 'agent-1', 'watches')).toBeUndefined()
    expect(markerOf('relative', SESSION_ID, 'session-start')).toBeUndefined()
  })

  test('a record reads back as it was written, and a malformed one reads as none', () => {
    const snapshot = snapshotOf('a1', [{ id: 'h1', type: 'Explore', status: 'running', parentId: 'a1', description: 'd', name: 'n' }], [{ id: 'b1' }], () => ({ ticks: 2, inFlight: 1 }))
    expect(waitStateFrom(JSON.stringify(snapshot))).toEqual({ agents: snapshot.agents, started: snapshot.started, activity: new Map([['h1', { ticks: 2, inFlight: 1 }]]) })
    expect(waitStateFrom('not json')).toBeUndefined()
    expect(waitStateFrom('[]')).toBeUndefined()
    expect(waitStateFrom(JSON.stringify({ ...snapshot, agents: [{ id: 'h1' }] }))).toBeUndefined()
    expect(waitStateFrom(JSON.stringify({ ...snapshot, started: [{ id: 1 }] }))).toBeUndefined()
    expect(waitStateFrom(JSON.stringify({ ...snapshot, activity: [['h1', { ticks: 'x', inFlight: 0 }]] }))).toBeUndefined()
  })

  test('watches read back, and unreadable ones start over', () => {
    const watches = new Map<string, Watch>([['a1\u0000helper:h1', { mark: '3', unchanged: 1, isReleased: false }]])
    expect(watchesFrom(watchesText(watches))).toEqual(watches)
    expect(watchesFrom('not json')).toEqual(new Map())
    expect(watchesFrom(undefined)).toEqual(new Map())
    expect(watchesFrom('[["k",{"mark":"1"}]]')).toEqual(new Map())
  })

  test('in-flight tasks keep the well-formed entries only', () => {
    expect(inFlightOf([inFlight('b1', 'sleep 1'), { id: 2 }, null, { id: 'b2', description: 'd' }])).toEqual([
      { id: 'b1', description: 'sleep 1', command: 'sleep 1' },
      { id: 'b2', description: 'd' },
    ])
    expect(inFlightOf(undefined)).toEqual([])
  })
})
