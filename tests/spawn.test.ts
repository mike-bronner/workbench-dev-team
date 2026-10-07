// hooks/register.ts and hooks/mods/spawn.ts: what a dispatch of a dev-team
// agent turns into. Routing to the mode agent, model and effort from the
// config, and the dispatch gate with its advisory hint.

import { describe, expect, test } from 'claude-code/testing'
import type { Plugin } from 'claude-code/testing'

import { BRIEF, CONFIG_PATH, SLOTS, spawnInput, step, world } from './world'

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
    // Dispatched from a sub-agent, so the gate stands aside and the routing is
    // all that is tested: a bare id from the main session is refused by the
    // gate, which exempts only the two machine-built shapes.
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

describe('model and effort — from dev-team-config.json at spawn', () => {
  const CONFIG = JSON.stringify({
    agents: {
      watson: { model: 'claude-opus-5-5[1m]', effort: 'Medium' },
      holmes: { model: 'sonnet', effort: 'high' },
      lestrade: { model: 'bad model; rm', effort: 'turbo' },
    },
  })

  test('the config model is set when the caller names none', async ($, on) => {
    const w = world(on, { config: CONFIG })
    await $.agent.spawn(spawnInput(T('watson'), BRIEF))
    await $.agent.spawn(spawnInput(T('holmes'), BRIEF))
    expect(w.spawned.map(s => s.model)).toEqual(['claude-opus-5-5[1m]', 'sonnet'])
  })

  test('a model the caller named stands', async ($, on) => {
    const w = world(on, { config: CONFIG })
    await $.agent.spawn(spawnInput(T('watson'), BRIEF, { model: 'haiku' }))
    expect(w.spawned[0]?.model).toBe('haiku')
  })

  test("the config effort reaches every request of that agent's loop, and no other", async ($, on) => {
    const w = world(on, { config: CONFIG })
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

  test('a numeric effort is ignored, since a hook may set only a level', async ($, on) => {
    const w = world(on, { config: JSON.stringify({ agents: { watson: { effort: 8000 } } }) })
    await $.agent.spawn(spawnInput(T('watson'), BRIEF))
    await step($ as never, 'agent-1', 'low')
    expect(w.steps).toEqual([{ agentId: 'agent-1', effort: 'low' }])
  })

  test('a token from the main session runs the mode it names, past the gate', async ($, on) => {
    const w = world(on)
    await $.agent.spawn(spawnInput(T('lestrade'), 'Repo sweep: mike-bronner/phpcs-rules'))
    await $.agent.spawn(spawnInput(T('holmes'), 'Item ID: 5'))
    expect(w.spawned.map(s => s.subagentType)).toEqual([T('lestrade-sweep'), T('holmes-index')])
  })

  test('a malformed model or effort is ignored, so the agent file applies', async ($, on) => {
    const w = world(on, { config: CONFIG })
    await $.agent.spawn(spawnInput(T('lestrade'), 'Item ID: 3'))
    await step($ as never, 'agent-1', 'low')
    expect(w.spawned[0]?.model).toBeUndefined()
    expect(w.steps).toEqual([{ agentId: 'agent-1', effort: 'low' }])
  })

  for (const [label, config] of [
    ['a missing config', undefined],
    ['a config that is not JSON', '{not json'],
    ['a config whose agents entry is not an object', JSON.stringify({ agents: { watson: 'opus' } })],
    ['a config that is null', 'null'],
  ] as const) {
    test(`${label} changes nothing and blocks nothing`, async ($, on) => {
      const w = world(on, { config })
      const result = await $.agent.spawn(spawnInput(T('watson'), BRIEF))
      await step($ as never, 'agent-1', 'low')
      expect(result).toMatchObject({ agentId: 'agent-1' })
      expect(w.spawned).toEqual([{ subagentType: T('watson-direct'), model: undefined, prompt: BRIEF }])
      expect(w.steps).toEqual([{ agentId: 'agent-1', effort: 'low' }])
    })
  }

  test('a failure after the gate passes the dispatch on unchanged, never refused', async ($, on) => {
    const w = world(on, { envFails: true })
    const result = await $.agent.spawn(spawnInput(T('watson'), BRIEF))
    expect(result).toMatchObject({ agentId: 'agent-1' })
    expect(w.spawned).toEqual([{ subagentType: T('watson'), model: undefined, prompt: BRIEF }])
  })

  test('the config is read from the home directory', async ($, on) => {
    const w = world(on)
    w.files.set(CONFIG_PATH.replace('dev-team-config', 'other'), JSON.stringify({ agents: { watson: { model: 'opus' } } }))
    await $.agent.spawn(spawnInput(T('watson'), BRIEF))
    expect(w.spawned[0]?.model).toBeUndefined()
  })
})

describe('the dispatch gate — a main-session brief missing a slot is refused', () => {
  const PARTIAL = 'Workdir: /tmp/repo\nGoal: Fix it.'

  test('a main-session dispatch missing slots is denied, and nothing spawns', async ($, on) => {
    const w = world(on)
    const result = await $.agent.spawn(spawnInput('general-purpose', PARTIAL))
    expect(w.spawned).toEqual([])
    const deny = (result as { deny?: string }).deny ?? ''
    expect(deny.split('\n')[0]).toBe(
      '🛑 Blocked: an Agent dispatch without a complete brief. Missing: Context:, Constraints:, Acceptance:, Done when:.',
    )
    expect(deny).toContain('Dispatch gate (workbench-dev-team).')
    expect(deny).toContain('six-slot brief, research included')
    for (const slot of SLOTS) expect(deny).toContain(`${slot.header} (${slot.description})`)
    expect(deny).toContain('/workbench-dev-team:orchestrate')
    expect(deny).toContain('the human can run /orchestrator off')
    expect(deny.split('\n')[0]).not.toContain('**')
  })

  test('the gate refuses before routing, for a dev-team type too', async ($, on) => {
    const w = world(on)
    const result = await $.agent.spawn(spawnInput(T('watson'), 'fix the parser'))
    expect(result).toHaveProperty('deny')
    expect(w.spawned).toEqual([])
  })

  test('a complete brief passes', async ($, on) => {
    const w = world(on)
    await $.agent.spawn(spawnInput('general-purpose', BRIEF))
    expect(w.spawned).toHaveLength(1)
  })

  test('a machine-built token needs no brief', async ($, on) => {
    const w = world(on)
    await $.agent.spawn(spawnInput(T('watson'), 'Item ID: 9'))
    expect(w.spawned.map(s => s.subagentType)).toEqual([T('watson-index')])
  })

  test("a sub-agent's dispatch is not judged", async ($, on) => {
    const w = world(on)
    await $.agent.spawn(spawnInput('general-purpose', 'lens prompt', { parentAgentId: 'agent-holmes' }))
    expect(w.spawned).toHaveLength(1)
  })

  test("a top-level --agent run's dispatch is not judged", async ($, on) => {
    const w = world(on, { lane: () => 'top-level-agent' })
    await $.agent.spawn(spawnInput('general-purpose', 'lens prompt'))
    expect(w.spawned).toHaveLength(1)
  })

  test('an unknown lane is read as the main session, so the brief is still checked', async ($, on) => {
    const w = world(on, { lane: () => new Error('workbench: the lane is unknown') })
    const result = await $.agent.spawn(spawnInput('general-purpose', 'fix it', { parentAgentId: 'agent-x' }))
    expect(result).toHaveProperty('deny')
    expect(w.spawned).toEqual([])
  })

  test('orchestrator mode off stands the gate down', async ($, on) => {
    const w = world(on, { isOn: false })
    await $.agent.spawn(spawnInput('general-purpose', 'fix it'))
    expect(w.spawned).toHaveLength(1)
  })

  test('an orchestrator mode that cannot be read is on', async ($, on) => {
    const w = world(on, { isOn: new Error('no state') })
    const result = await $.agent.spawn(spawnInput('general-purpose', 'fix it'))
    expect(result).toHaveProperty('deny')
    expect(w.spawned).toEqual([])
  })

  // workbench-core is a declared dependency, so a check that fails is a fault,
  // and the gate fails closed. /orchestrator off is the way past it.
  for (const [label, checkFails] of [
    ['rejects', true],
    ['throws', 'throw'],
  ] as const) {
    test(`a gated dispatch whose brief check ${label} is refused, naming /orchestrator off`, async ($, on) => {
      const w = world(on, { checkFails })
      const result = await $.agent.spawn(spawnInput(T('watson'), BRIEF))
      expect(w.spawned).toEqual([])
      const deny = (result as { deny?: string }).deny ?? ''
      expect(deny.split('\n')[0]).toBe('🛑 Blocked: an Agent dispatch whose brief could not be checked.')
      expect(deny).toContain('the human can run /orchestrator off')
    })
  }

  // A malformed answer from core throws inside the gate, before next is
  // called, which only the hook's own .catch can answer. It refuses.
  for (const [label, answer] of [
    ['no verdict at all', null],
    ['a verdict whose missing slots are not a list', { isComplete: false, missing: 'Goal:', shape: 'brief' }],
  ] as const) {
    test(`a brief check that answers ${label} is refused by the hook's .catch`, async ($, on) => {
      const w = world(on, { check: () => answer as never })
      const result = await $.agent.spawn(spawnInput(T('watson'), BRIEF))
      expect(w.spawned).toEqual([])
      const deny = (result as { deny?: string }).deny ?? ''
      expect(deny.split('\n')[0]).toBe('🛑 Blocked: an Agent dispatch whose brief could not be checked.')
      expect(deny).toContain('the human can run /orchestrator off')
    })
  }

  test('a brief check that fails does not touch a dispatch the gate stands aside for', async ($, on) => {
    const w = world(on, { checkFails: true })
    await $.agent.spawn(spawnInput('general-purpose', 'lens prompt', { parentAgentId: 'agent-holmes' }))
    expect(w.spawned).toHaveLength(1)
  })

  test('with orchestrator mode off, a failing brief check refuses nothing', async ($, on) => {
    const w = world(on, { checkFails: true, isOn: false })
    await $.agent.spawn(spawnInput('general-purpose', 'fix it'))
    expect(w.spawned).toHaveLength(1)
  })

  // A plugin's own $.agent.spawn is its implementation, not a handoff, and the
  // bash gate never saw one.
  const SPAWNER: Plugin = {
    name: 'spawner',
    register: on => {
      on('prompt.submit', async ($, e, next) => {
        await $.agent.spawn({ subagentType: 'general-purpose', prompt: 'no brief here' })
        return next(e)
      })
    },
  }
  test("a plugin's own spawn is not judged", { plugins: [SPAWNER] }, async ($, on) => {
    const w = world(on)
    on('prompt.submit', async () => ({ text: '' }) as never)
    await $.prompt.submit({ text: 'go', wait: false, origin: { kind: 'composer' } } as never)
    expect(w.spawned.map(s => s.prompt)).toEqual(['no brief here'])
  })
})

describe('the advisory hint — a complete brief that dictates method', () => {
  const agentCall = (prompt: string, agentId?: string) =>
    ({ tool: 'Agent', tool_use_id: 'toolu_1', description: 'a task', prompt, subagent_type: 'general-purpose', agentId }) as never

  const FENCED = `${BRIEF}\n\`\`\`bash\nmake test\n\`\`\``
  const SHELL = `${BRIEF}\ngit log --oneline -5`
  const STEPS = `${BRIEF}\n1. read\n2. edit\n3. test`

  for (const [label, prompt, marker] of [
    ['a fenced block', FENCED, 'a fenced code block'],
    ['a shell command on its own line', SHELL, 'a shell command on its own line'],
    ['three numbered steps', STEPS, '3 numbered steps'],
  ] as const) {
    test(`${label} adds the hint, and blocks nothing`, async ($, on) => {
      world(on)
      const result = await $.tool.call(agentCall(prompt))
      expect(result).not.toHaveProperty('deny')
      const context = (result as { context?: string[] }).context ?? []
      expect(context).toHaveLength(1)
      expect(context[0]).toContain('nothing was blocked')
      expect(context[0]).toContain(marker)
    })
  }

  for (const [label, prompt] of [
    ['two numbered steps', `${BRIEF}\n1. read\n2. edit`],
    ['an inline mention of git', `${BRIEF}\nThe bug shows in git log output.`],
    ["'make sure' as a sentence", `${BRIEF}\nmake sure the suite is green`],
  ] as const) {
    test(`${label} adds no hint`, async ($, on) => {
      world(on)
      const result = await $.tool.call(agentCall(prompt))
      expect((result as { context?: string[] }).context).toBeUndefined()
    })
  }

  test("a sub-agent's call gets no hint", async ($, on) => {
    world(on)
    const result = await $.tool.call(agentCall(FENCED, 'agent-holmes'))
    expect((result as { context?: string[] }).context).toBeUndefined()
  })

  test('an Agent call that errored gets no hint', async ($, on) => {
    const w = world(on)
    w.agentCall = 'error'
    const result = await $.tool.call(agentCall(FENCED))
    expect((result as { context?: string[] }).context).toBeUndefined()
  })
})
