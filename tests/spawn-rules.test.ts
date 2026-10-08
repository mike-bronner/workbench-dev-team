// hooks/register.ts with hooks/mods/spawn.ts: the rules agent.spawn adds after
// the dispatch gate. Holmes's helpers run on holmes-lens, a Watson Direct brief
// with a bare Workdir on a default branch is refused, and the config's
// fan-out knobs reach the agents that read them.

import { describe, expect, test } from 'claude-code/testing'
import type { Plugin } from 'claude-code/testing'

import { configLineOf, configTextOf, isHolmesMode, knobsOf, lensSpawnOf, withConfigLine, workdirOf } from '../hooks/mods/spawn'
import type { RunAnswer } from './world'
import { BRIEF, spawnInput, world } from './world'

const T = (name: string) => `workbench-dev-team:${name}`

type Spawned = { deny?: string; agentId?: string }

describe('holmes-lens — every helper Holmes spawns runs on it', () => {
  for (const type of ['general-purpose', 'Explore', 'Plan', T('watson'), T('holmes-lens')]) {
    test(`a ${type} spawn by Holmes Local runs as holmes-lens`, async ($, on) => {
      const w = world(on)
      await $.agent.spawn(spawnInput(T('holmes'), BRIEF)) // agent-1, holmes-local
      const result = (await $.agent.spawn(spawnInput(type, 'lens prompt', { parentAgentId: 'agent-1', model: 'sonnet' }))) as Spawned
      expect(result.deny).toBeUndefined()
      expect(w.spawned.slice(1)).toEqual([{ subagentType: T('holmes-lens'), model: 'sonnet', prompt: 'lens prompt' }])
    })
  }

  test('a top-level Holmes Index run is held too, by its --agent type', async ($, on) => {
    const w = world(on, { lane: () => 'top-level-agent', env: { CLAUDE_CODE_AGENT: T('holmes-index') } })
    await $.agent.spawn(spawnInput('general-purpose', 'lens prompt'))
    expect(w.spawned.map(s => s.subagentType)).toEqual([T('holmes-lens')])
  })

  test('a Holmes the mod did not start is found through $.agent.list()', async ($, on) => {
    const w = world(on, { agents: [{ id: 'agent-h', type: T('holmes-index') }] })
    await $.agent.spawn(spawnInput('general-purpose', 'lens prompt', { parentAgentId: 'agent-h' }))
    expect(w.spawned.map(s => s.subagentType)).toEqual([T('holmes-lens')])
  })

  for (const [label, extra] of [
    ['a fork', { fork: true, subagentType: 'fork' }],
    ['a teammate', { isTeammate: true }],
  ] as const) {
    test(`${label} of Holmes is refused, and nothing starts`, async ($, on) => {
      const w = world(on)
      await $.agent.spawn(spawnInput(T('holmes'), BRIEF))
      const result = (await $.agent.spawn({ ...(spawnInput('general-purpose', 'x', { parentAgentId: 'agent-1' }) as object), ...extra } as never)) as Spawned
      expect(result.deny).toContain(`Holmes spawned ${label}`)
      expect(w.spawned.length).toBe(1)
    })
  }

  test("Watson's helpers, and the main session's, keep the type they named", async ($, on) => {
    const w = world(on)
    await $.agent.spawn(spawnInput(T('watson'), BRIEF)) // agent-1
    await $.agent.spawn(spawnInput('Explore', 'map it', { parentAgentId: 'agent-1' }))
    await $.agent.spawn(spawnInput('Explore', BRIEF))
    expect(w.spawned.map(s => s.subagentType)).toEqual([T('watson-direct'), 'Explore', 'Explore'])
  })

  test('a spawner the mod cannot name keeps the type it named, and the review guard still holds its writes', async ($, on) => {
    const w = world(on, { agents: new Error('list failed') })
    await $.agent.spawn(spawnInput('general-purpose', 'x', { parentAgentId: 'agent-9' })) // agent-1
    expect(w.spawned.map(s => s.subagentType)).toEqual(['general-purpose'])
    // Its write outside scratch: the guard cannot tell who made it, so it holds
    // the call to the reviewer's rule.
    const answer = (await $.tool.call({ tool: 'Write', tool_use_id: 'toolu_w', file_path: '/repo/src/x.ts', content: 'x', agentId: 'agent-1' } as never)) as { deny?: string }
    expect(answer.deny).toContain('could not tell which agent made this call')
    expect(w.ran).toEqual([])
  })

  const SPAWNER: Plugin = {
    name: 'spawner',
    register: on => {
      on('prompt.submit', async ($, e, next) => {
        await $.agent.spawn({ subagentType: 'general-purpose', prompt: 'own helper' })
        return next(e)
      })
    },
  }
  test("a plugin's own spawn under a Holmes run is not retyped", { plugins: [SPAWNER] }, async ($, on) => {
    const w = world(on, { env: { CLAUDE_CODE_AGENT: T('holmes-index') } })
    on('prompt.submit', async () => ({ text: '' }) as never)
    await $.prompt.submit({ text: 'go', wait: false, origin: { kind: 'composer' } } as never)
    expect(w.spawned.map(s => s.prompt)).toEqual(['own helper'])
    expect(w.spawned.map(s => s.subagentType)).not.toContain(T('holmes-lens'))
  })
})

describe('the workspace check — a bare Workdir on a default branch asks for a branch', () => {
  const onBranch =
    (branch: string) =>
    (argv: readonly string[]): RunAnswer | undefined =>
      argv[0] === 'git' ? { exitCode: 0, stdout: `${branch}\n`, stderr: '' } : undefined

  for (const branch of ['main', 'master', 'trunk']) {
    test(`a Watson brief on ${branch} with a bare Workdir is refused, and nothing starts`, async ($, on) => {
      const w = world(on, { run: onBranch(branch) })
      const result = (await $.agent.spawn(spawnInput(T('watson'), BRIEF))) as Spawned
      expect(result.deny).toContain(`onto ${branch}, with no branch recorded`)
      expect(result.deny).toContain('Ask the human which branch the work goes on')
      expect(w.runs).toEqual([['git', '-C', '/tmp/repo', 'symbolic-ref', '--quiet', '--short', 'HEAD']])
      expect(w.spawned).toEqual([])
    })
  }

  for (const workdir of [
    'Workdir: /tmp/repo (branch: main, Mike chose to work on main)',
    'Workdir: /tmp/repo (branch: fix/x)',
    'Workdir: /tmp/repo (worktree: /tmp/repo-wt)',
  ]) {
    test(`${JSON.stringify(workdir)} passes, and git is not asked`, async ($, on) => {
      const w = world(on, { run: onBranch('main') })
      const result = (await $.agent.spawn(spawnInput(T('watson'), BRIEF.replace('Workdir: /tmp/repo', workdir)))) as Spawned
      expect(result.deny).toBeUndefined()
      expect(w.runs).toEqual([])
      expect(w.spawned.length).toBe(1)
    })
  }

  test('a feature branch passes', async ($, on) => {
    const w = world(on, { run: onBranch('fix/retry') })
    expect(((await $.agent.spawn(spawnInput(T('watson'), BRIEF))) as Spawned).deny).toBeUndefined()
    expect(w.spawned.length).toBe(1)
  })

  test('a path git finds no branch at (no repository, a detached HEAD) passes', async ($, on) => {
    const w = world(on)
    expect(((await $.agent.spawn(spawnInput(T('watson'), BRIEF))) as Spawned).deny).toBeUndefined()
    expect(w.runs).toEqual([['git', '-C', '/tmp/repo', 'symbolic-ref', '--quiet', '--short', 'HEAD']])
  })

  test('git that cannot run refuses, since the branch is unknown', async ($, on) => {
    const w = world(on, { run: argv => (argv[0] === 'git' ? new Error('spawn failed') : undefined) })
    const result = (await $.agent.spawn(spawnInput(T('watson'), BRIEF))) as Spawned
    expect(result.deny).toContain('whose branch could not be read')
    expect(w.spawned).toEqual([])
  })

  for (const [label, type, prompt, extra, isOn] of [
    ['Holmes Local', T('holmes'), BRIEF, {}, true],
    ['a Watson Index token', T('watson'), 'Item ID: 4', {}, true],
    ["a sub-agent's Watson", T('watson'), BRIEF, { parentAgentId: 'agent-x' }, true],
    ['a Watson brief with orchestrator mode off', T('watson'), BRIEF, {}, false],
    ['a relative Workdir', T('watson'), BRIEF.replace('/tmp/repo', 'repo'), {}, true],
  ] as const) {
    test(`${label} is not checked`, async ($, on) => {
      const w = world(on, { run: onBranch('main'), isOn })
      expect(((await $.agent.spawn(spawnInput(type, prompt, extra))) as Spawned).deny).toBeUndefined()
      expect(w.runs).toEqual([])
    })
  }
})

describe('config knobs — fanout and lensModel reach the agents that read them', () => {
  // The plugin's /config rows, as the engine hands them to register().
  const OPTIONS = { options: { holmesFanout: true, holmesLensModel: 'sonnet', lestradeFanout: false, lestradeLensModel: 'bad model;' } }

  test('Holmes Local and Holmes Index get the line at the end of the prompt', OPTIONS, async ($, on) => {
    const w = world(on)
    await $.agent.spawn(spawnInput(T('holmes'), BRIEF))
    await $.agent.spawn(spawnInput(T('holmes'), 'Item ID: 5', { parentAgentId: 'agent-x' }))
    expect(w.spawned.map(s => s.prompt)).toEqual([
      `${BRIEF}\n\nDev-team config: fanout on; lensModel sonnet.`,
      'Item ID: 5\n\nDev-team config: fanout on; lensModel sonnet.',
    ])
  })

  test('Lestrade Item mode gets its own knobs, and a bad lensModel reads as unset', OPTIONS, async ($, on) => {
    const w = world(on)
    await $.agent.spawn(spawnInput(T('lestrade'), 'Item ID: 6'))
    expect(w.spawned.map(s => s.prompt)).toEqual(['Item ID: 6\n\nDev-team config: fanout off; lensModel unset.'])
  })

  test('Watson, Lestrade Sweep and a generic agent get no line', OPTIONS, async ($, on) => {
    const w = world(on)
    await $.agent.spawn(spawnInput(T('watson'), BRIEF))
    await $.agent.spawn(spawnInput(T('lestrade'), 'Repo sweep: o/r'))
    await $.agent.spawn(spawnInput('general-purpose', BRIEF))
    expect(w.spawned.map(s => s.prompt)).toEqual([BRIEF, 'Repo sweep: o/r', BRIEF])
  })

  test('with no row set, the line carries the rows\' defaults, so the agent never reads a file', async ($, on) => {
    const w = world(on)
    await $.agent.spawn(spawnInput(T('holmes'), BRIEF))
    await $.agent.spawn(spawnInput(T('lestrade'), 'Item ID: 7'))
    expect(w.spawned.map(s => s.prompt)).toEqual([`${BRIEF}\n\nDev-team config: fanout on; lensModel sonnet.`, 'Item ID: 7\n\nDev-team config: fanout on; lensModel sonnet.'])
  })

  test('the old config file is never read', async ($, on) => {
    const w = world(on, { config: JSON.stringify({ agents: { holmes: { fanout: false, lensModel: 'haiku' } } }) })
    await $.agent.spawn(spawnInput(T('holmes'), BRIEF))
    expect(w.spawned[0]?.prompt).toBe(`${BRIEF}\n\nDev-team config: fanout on; lensModel sonnet.`)
  })

  for (const [mode, line] of [
    ['holmes-index', 'Dev-team config: fanout on; lensModel sonnet.'],
    ['lestrade-item', 'Dev-team config: fanout off; lensModel unset.'],
  ] as const) {
    test(`a top-level ${mode} run gets its own line as context on its prompt`, OPTIONS, async ($, on) => {
      world(on, { lane: () => 'top-level-agent', env: { CLAUDE_CODE_AGENT: T(mode) } })
      const seen: unknown[] = []
      on('prompt.submit', async ($, e) => {
        seen.push(e)
        return { text: '' } as never
      })
      await $.prompt.submit({ text: 'Item ID: 5', wait: false, origin: { kind: 'composer' } } as never)
      expect(seen).toMatchObject([{ text: 'Item ID: 5', context: [line] }])
    })
  }

  for (const [label, lane, agent] of [
    ['a top-level Watson Index run', 'top-level-agent', T('watson-index')],
    ['the main session', 'main', undefined],
  ] as const) {
    test(`${label} gets no context`, OPTIONS, async ($, on) => {
      world(on, { lane: () => lane, env: agent === undefined ? {} : { CLAUDE_CODE_AGENT: agent } })
      const seen: { context?: unknown }[] = []
      on('prompt.submit', async ($, e) => {
        seen.push(e)
        return { text: '' } as never
      })
      await $.prompt.submit({ text: 'Item ID: 5', wait: false, origin: { kind: 'composer' } } as never)
      expect(seen[0]?.context).toBeUndefined()
    })
  }
})

describe('spawn rules — the pure parts', () => {
  test('workdirOf reads the path and whether a branch or worktree is recorded', () => {
    expect(workdirOf('Workdir: /a/b\nGoal: x')).toEqual({ path: '/a/b', isRecorded: false })
    expect(workdirOf('Workdir: /a/b (branch: main)')).toEqual({ path: '/a/b', isRecorded: true })
    expect(workdirOf('Workdir: /a/b (Mike decided)')).toEqual({ path: '/a/b', isRecorded: false })
    expect(workdirOf('Goal: no workdir')).toBeUndefined()
  })

  test('isHolmesMode names Holmes and his modes, never his helper', () => {
    expect([T('holmes'), T('holmes-local'), T('holmes-index'), 'holmes'].map(isHolmesMode)).toEqual([true, true, true, true])
    expect([T('holmes-lens'), T('watson'), undefined].map(isHolmesMode)).toEqual([false, false, false])
  })

  test('lensSpawnOf retypes a plain spawn and refuses a fork', () => {
    expect(lensSpawnOf({ subagentType: 'Explore', fork: false })).toEqual({ subagentType: T('holmes-lens') })
    expect(lensSpawnOf({ subagentType: 'fork', fork: true })).toHaveProperty('deny')
  })

  test('configTextOf keys each row under its agent, as the old file did, and leaves an unset row out', () => {
    expect(JSON.parse(configTextOf({ watsonModel: 'opus', watsonEffort: 'high', holmesFanout: false, holmesLensModel: 'haiku', reprieveBudgetMultiplier: 3 }))).toEqual({
      agents: { watson: { model: 'opus', effort: 'high' }, holmes: { fanout: false, lensModel: 'haiku' }, lestrade: {} },
    })
    expect(JSON.parse(configTextOf(undefined))).toEqual({ agents: { watson: {}, holmes: {}, lestrade: {} } })
    expect(knobsOf(configTextOf({ watsonModel: 'bad model; rm', watsonEffort: 'turbo' }), 'watson')).toEqual({})
    expect(knobsOf(configTextOf({ watsonModel: 'sonnet', watsonEffort: 'High' }), 'watson')).toEqual({ model: 'sonnet', effort: 'high' })
    expect(configLineOf(configTextOf({ lestradeFanout: false, lestradeLensModel: 'haiku' }), 'lestrade')).toBe('Dev-team config: fanout off; lensModel haiku.')
  })

  test('configLineOf turns the fan-out off only for false, and withConfigLine adds the line once', () => {
    expect(configLineOf(JSON.stringify({ agents: { holmes: { fanout: 'no' } } }), 'holmes')).toBe('Dev-team config: fanout on; lensModel unset.')
    expect(configLineOf('not json', 'holmes')).toBe('Dev-team config: fanout on; lensModel unset.')
    const once = withConfigLine('Item ID: 1\n', 'Dev-team config: fanout on; lensModel unset.')
    expect(withConfigLine(once, 'Dev-team config: fanout off; lensModel unset.')).toBe(once)
  })
})
