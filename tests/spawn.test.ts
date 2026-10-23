import { describe, expect, test } from 'claude-code/testing'
import type { Plugin } from 'claude-code/testing'

import { BRIEF, spawnInput, step, world } from './world'

const T = (name: string) => `workbench-dev-team:${name}`

describe('routing — a public type runs the mode its token picks', () => {
  const cases: [string, string, string][] = [
    ['watson', BRIEF, 'watson-direct'],
    ['watson', 'Item ID: 42', 'watson-index'],
    ['watson', '12', 'watson-index'],
    ['watson', '3f2b1c4d-1a2b-4c3d-9e8f-001122334455', 'watson-index'],
    ['watson', 'PVTI_lADOABC123', 'watson-index'],
    ['holmes', BRIEF, 'holmes-local'],
    ['holmes', 'Item ID: 42', 'holmes-index'],
    ['lestrade', 'Item ID: 42', 'lestrade-item'],
    ['lestrade', '42', 'lestrade-item'],
    ['lestrade', 'Repo sweep: mike-bronner/phpcs-rules', 'lestrade-sweep'],
    // Lestrade has no prose mode: a brief stays on the public type.
    ['lestrade', BRIEF, 'lestrade'],
    // A mode type named directly still runs the mode its prompt calls for.
    ['watson-index', BRIEF, 'watson-direct'],
    ['holmes-local', 'Item ID: 7', 'holmes-index'],
  ]
  for (const [from, prompt, to] of cases) {
    test(`${from} with ${JSON.stringify(prompt.slice(0, 24))} runs ${to}`, async ($, on) => {
      const w = world(on)
      const result = await $.agent.spawn(spawnInput(T(from), prompt, { parentAgentId: 'agent-parent' }))
      expect(result).toMatchObject({ agentId: 'agent-1' })
      expect(w.spawned.map(s => s.subagentType)).toEqual([T(to)])
    })
  }

  // A token picks a mode only as the whole prompt. A complete brief that quotes
  // one is still a brief, from the main session too, so its real task runs.
  for (const [from, quote, to] of [
    ['watson', 'Item ID: 9', 'watson-direct'],
    ['holmes', 'Item ID: 9', 'holmes-local'],
    ['watson', '42', 'watson-direct'],
    ['lestrade', 'Item ID: 9', 'lestrade'],
    ['lestrade', 'Repo sweep: mike-bronner/phpcs-rules', 'lestrade'],
    ['holmes', 'Repo sweep: mike-bronner/phpcs-rules', 'holmes-local'],
  ] as const) {
    test(`${from} with a complete brief quoting ${JSON.stringify(quote)} runs ${to}`, async ($, on) => {
      const w = world(on)
      const prompt = BRIEF.replace('Context: It drops a field.', `Context: It drops a field, as ${quote} showed.`)
      expect(prompt).toContain(quote)
      const result = await $.agent.spawn(spawnInput(T(from), prompt))
      expect(result).toMatchObject({ agentId: 'agent-1' })
      expect(w.spawned.map(s => s.subagentType)).toEqual([T(to)])
    })
  }

  for (const [prompt, to] of [
    ['Item ID: 9\nand then review the parser', 'holmes-local'],
    ['Item ID: 9 please', 'holmes-local'],
    ['\n  Item ID: 9  \n', 'holmes-index'],
  ] as const) {
    test(`holmes with ${JSON.stringify(prompt)} runs ${to}`, async ($, on) => {
      const w = world(on)
      await $.agent.spawn(spawnInput(T('holmes'), prompt, { parentAgentId: 'agent-parent' }))
      expect(w.spawned.map(s => s.subagentType)).toEqual([T(to)])
    })
  }

  test('a generic agent is never rerouted, from the main session or a sub-agent', async ($, on) => {
    const w = world(on)
    await $.agent.spawn(spawnInput('general-purpose', BRIEF))
    await $.agent.spawn(spawnInput('Explore', 'map the parser', { parentAgentId: 'agent-holmes' }))
    await $.agent.spawn(spawnInput(T('holmes-lens'), 'lens prompt', { parentAgentId: 'agent-holmes' }))
    expect(w.spawned.map(s => s.subagentType)).toEqual(['general-purpose', 'Explore', T('holmes-lens')])
    expect(w.spawned.map(s => s.model)).toEqual([undefined, undefined, undefined])
  })
})

describe('model and effort — from the /config rows at spawn', () => {
  // The plugin's /config rows, as the engine hands them to register(). An
  // effort outside the row's options never arrives: the engine reads it as
  // unset and hands over the default, so only the model can be malformed here.
  const OPTIONS = { options: { holmesModel: 'sonnet', holmesEffort: 'high', lestradeModel: 'bad model; rm' } }

  test('the row model is set when the caller names none', OPTIONS, async ($, on) => {
    const w = world(on)
    await $.agent.spawn(spawnInput(T('watson'), BRIEF))
    await $.agent.spawn(spawnInput(T('holmes'), BRIEF))
    expect(w.spawned.map(s => s.model)).toEqual(['claude-opus-5-5[1m]', 'sonnet'])
  })

  test('a model the caller named stands', OPTIONS, async ($, on) => {
    const w = world(on)
    await $.agent.spawn(spawnInput(T('watson'), BRIEF, { model: 'haiku' }))
    expect(w.spawned[0]?.model).toBe('haiku')
  })

  test("the row effort reaches every request of that agent's loop, and no other", OPTIONS, async ($, on) => {
    const w = world(on)
    await $.agent.spawn(spawnInput(T('watson'), BRIEF)) // agent-1, medium
    await $.agent.spawn(spawnInput(T('holmes'), BRIEF)) // agent-2, high
    await $.agent.spawn(spawnInput('general-purpose', BRIEF)) // agent-3, untouched
    await step($ as never, 'agent-1', 'low')
    await step($ as never, 'agent-1', 'low')
    await step($ as never, 'agent-2')
    await step($ as never, 'agent-3', 'low')
    await step($ as never, undefined, 'xhigh')
    expect(w.steps).toEqual([
      { agentId: 'agent-1', effort: 'medium' },
      { agentId: 'agent-1', effort: 'medium' },
      { agentId: 'agent-2', effort: 'high' },
      { agentId: 'agent-3', effort: 'low' },
      { agentId: undefined, effort: 'xhigh' },
    ])
  })

  test('a token from the main session runs the mode it names, past the gate', async ($, on) => {
    const w = world(on)
    await $.agent.spawn(spawnInput(T('lestrade'), 'Repo sweep: mike-bronner/phpcs-rules'))
    await $.agent.spawn(spawnInput(T('holmes'), 'Item ID: 5'))
    expect(w.spawned.map(s => s.subagentType)).toEqual([T('lestrade-sweep'), T('holmes-index')])
  })

  test('a malformed model is ignored, so the agent file applies, and the effort still does', OPTIONS, async ($, on) => {
    const w = world(on)
    await $.agent.spawn(spawnInput(T('lestrade'), 'Item ID: 3'))
    await step($ as never, 'agent-1', 'low')
    expect(w.spawned[0]?.model).toBeUndefined()
    expect(w.steps).toEqual([{ agentId: 'agent-1', effort: 'medium' }])
  })

  test('with no row set, the rows\' defaults apply: the pin every agent file carries', async ($, on) => {
    const w = world(on)
    await $.agent.spawn(spawnInput(T('watson'), BRIEF))
    await $.agent.spawn(spawnInput(T('holmes'), 'Item ID: 4'))
    await $.agent.spawn(spawnInput(T('lestrade'), 'Item ID: 5'))
    await step($ as never, 'agent-1', 'low')
    expect(w.spawned.map(s => s.model)).toEqual(['claude-opus-5-5[1m]', 'claude-opus-5-5[1m]', 'claude-opus-5-5[1m]'])
    expect(w.steps).toEqual([{ agentId: 'agent-1', effort: 'medium' }])
  })

  test('the old config file is never read', async ($, on) => {
    const w = world(on, { config: JSON.stringify({ agents: { watson: { model: 'opus', effort: 'low' } } }) })
    await $.agent.spawn(spawnInput(T('watson'), BRIEF))
    await step($ as never, 'agent-1', 'high')
    expect(w.spawned[0]?.model).toBe('claude-opus-5-5[1m]')
    expect(w.steps).toEqual([{ agentId: 'agent-1', effort: 'medium' }])
  })

  test('an environment that cannot be read stops neither the routing nor the rows', async ($, on) => {
    const w = world(on, { envFails: true })
    const result = await $.agent.spawn(spawnInput(T('watson'), BRIEF))
    expect(result).toMatchObject({ agentId: 'agent-1' })
    expect(w.spawned).toEqual([{ subagentType: T('watson-direct'), model: 'claude-opus-5-5[1m]', prompt: BRIEF }])
  })
})

describe('no brief check of its own — workbench-core holds the six-slot gate', () => {
  const PARTIAL = 'Workdir: /tmp/repo\nGoal: Fix it.'

  test('a main-session dispatch missing slots reaches the engine', async ($, on) => {
    const w = world(on)
    const result = await $.agent.spawn(spawnInput('general-purpose', PARTIAL))
    expect(result).not.toHaveProperty('deny')
    expect(w.spawned.map(s => s.prompt)).toEqual([PARTIAL])
  })

  test('a main-session Watson prompt that is no brief runs Direct mode', async ($, on) => {
    const w = world(on)
    await $.agent.spawn(spawnInput(T('watson'), 'fix the parser'))
    expect(w.spawned.map(s => s.subagentType)).toEqual([T('watson-direct')])
  })

  test('a complete brief that dictates method gets no hint from this module', async ($, on) => {
    const w = world(on)
    const fenced = `${BRIEF}\n\`\`\`bash\nmake test\n\`\`\``
    const result = await $.tool.call({ tool: 'Agent', tool_use_id: 'toolu_1', description: 'a task', prompt: fenced, subagent_type: 'general-purpose' } as never)
    expect((result as { context?: string[] }).context).toBeUndefined()
    expect(w.calls).toHaveLength(1)
  })

  test("a Watson dispatch whose prompt is no text throws in the workspace check, and the hook's .catch refuses it", async ($, on) => {
    const w = world(on)
    const result = await $.agent.spawn(spawnInput(T('watson'), 42 as never))
    expect(w.spawned).toEqual([])
    const deny = (result as { deny?: string }).deny ?? ''
    expect(deny.split('\n')[0]).toBe('🛑 Blocked: an Agent dispatch the dev-team spawn rules could not judge.')
    expect(deny).toContain('Spawn rules (workbench-dev-team).')
  })
})

describe("the workspace check on workbench-core 469497a's orchestrator check (C3n)", () => {
  const CORE: Plugin = {
    name: 'workbench-core',
    register: on => {
      let mode: boolean | undefined
      on('command.run', async ($, e, next) => {
        if (e.command !== 'orchestrator') return next(e)
        mode = e.args.trim() !== 'off'
        return { text: '' }
      })
      on('workbench.orchestratorIsOn', async $ => {
        if ((await $.env.get('WORKBENCH_ORCHESTRATOR')) === '0') return { value: false }
        if (mode !== undefined) return { value: mode }
        const id = await $.session.id()
        const home = await $.env.get('HOME')
        const dir = (await $.env.get('WORKBENCH_ORCHESTRATOR_STATE_DIR')) || (home ? `${home}/.claude-workbench/orchestrator-mode` : undefined)
        const file = dir && /^[A-Za-z0-9_-][A-Za-z0-9._-]*$/.test(id) ? `${dir}/${id}` : undefined
        return { value: !(file !== undefined && (await $.fs.exists(file))) }
      })
    },
  }
  const off = { command: 'orchestrator', args: 'off', origin: { kind: 'composer' }, presentation: { isFullscreen: false, columns: 80 } } as never
  const onMain = (argv: readonly string[]) => (argv[0] === 'git' ? { exitCode: 0, stdout: 'main\n', stderr: '' } : undefined)

  const SETUPS: [string, string, Parameters<typeof world>[1]][] = [
    ['the session id cannot name a file', '../escape', {}],
    ['HOME is unset and there is no state dir', 's-1', { isHomeUnset: true }],
  ]
  for (const [name, id, options] of SETUPS) {
    test(`${name}: a Watson brief on main is refused, and /orchestrator off stands the check down`, { plugins: [CORE] }, async ($, on) => {
      const w = world(on, { ...options, run: onMain })
      on('session.id', () => ({ value: id }))
      const refused = await $.agent.spawn(spawnInput(T('watson'), BRIEF))
      expect((refused as { deny?: string }).deny).toContain('onto main, with no branch recorded')
      expect(w.spawned).toEqual([])
      await $.command.run(off)
      await $.agent.spawn(spawnInput(T('watson'), BRIEF))
      expect(w.spawned.map(s => s.subagentType)).toEqual([T('watson-direct')])
    })
  }

  test('a legacy file the session id names stands the check down', { plugins: [CORE] }, async ($, on) => {
    const w = world(on, { run: onMain, disk: { '/Users/tester/.claude-workbench/orchestrator-mode/s-1': 'file' } })
    on('session.id', () => ({ value: 's-1' }))
    await $.agent.spawn(spawnInput(T('watson'), BRIEF))
    expect(w.spawned).toHaveLength(1)
    expect(w.runs).toEqual([])
  })
})
