import { describe, expect, test } from 'claude-code/testing'
import type { Plugin } from 'claude-code/testing'

import { resumeRefusalOf, resumedAgentOfRead } from '../hooks/mods/spawn'
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
    [`Item ID: 9\nand then review the parser\n${BRIEF}`, 'holmes-local'],
    [`Item ID: 9 please\n${BRIEF}`, 'holmes-local'],
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

  test('a main-session Watson prompt that is no brief runs Direct mode, so the no-mutation rule judges it', async ($, on) => {
    const w = world(on)
    const result = (await $.agent.spawn(spawnInput(T('watson'), 'fix the parser'))) as { deny?: string }
    expect(result.deny).toContain('🛑 Blocked: a Watson Direct-mode dispatch')
    expect(w.spawned).toEqual([])
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
      const w = world(on, { ...options, sessionId: id, run: onMain })
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
    await $.agent.spawn(spawnInput(T('watson'), BRIEF))
    expect(w.spawned).toHaveLength(1)
    expect(w.runs).toEqual([])
  })
})

describe('a Holmes Local dispatch carries the six-slot brief, from any caller (C4)', () => {
  for (const slot of ['Workdir:', 'Goal:', 'Context:', 'Constraints:', 'Acceptance:', 'Done when:']) {
    test(`a brief with no ${slot} is refused, and nothing is spawned`, async ($, on) => {
      const w = world(on)
      const prompt = BRIEF.split('\n').filter(line => !line.startsWith(slot)).join('\n')
      const result = (await $.agent.spawn(spawnInput(T('holmes'), prompt, { parentAgentId: 'agent-parent' }))) as { deny?: string }
      expect(result.deny).toContain(slot)
      expect(w.spawned).toEqual([])
    })
  }

  test('a Context: that reads "none" is refused, and a Constraints: that reads "none" passes the slot check', async ($, on) => {
    const w = world(on)
    const result = (await $.agent.spawn(spawnInput(T('holmes'), BRIEF.replace(/^Context:.*$/mu, 'Context: none'), { parentAgentId: 'agent-parent' }))) as { deny?: string }
    expect(result.deny).toContain('Context:')
    const none = (await $.agent.spawn(spawnInput(T('holmes'), BRIEF.replace('Constraints:\n- Run no mutation testing of any kind.', 'Constraints: none')))) as { deny?: string }
    expect(none.deny).not.toContain('brief lacks')
    expect(none.deny).toContain('No-mutation rule (workbench-dev-team).')
    await $.agent.spawn(spawnInput(T('holmes'), BRIEF, { parentAgentId: 'agent-parent' }))
    expect(w.spawned.map(s => s.subagentType)).toEqual([T('holmes-local')])
  })

  test('an Index-mode token needs no brief', async ($, on) => {
    const w = world(on)
    await $.agent.spawn(spawnInput(T('holmes'), 'Item ID: 9', { parentAgentId: 'agent-parent' }))
    expect(w.spawned.map(s => s.subagentType)).toEqual([T('holmes-index')])
  })
})

describe('the no-mutation gate, wired into agent.spawn', () => {
  const NO_LINE = '- Run no mutation testing of any kind.'
  const withConstraints = (lines: string) => BRIEF.replace(`Constraints:\n${NO_LINE}`, lines)
  const withAcceptance = (line: string) => BRIEF.replace('- AC1: the field survives', line)
  const denyOf = (result: unknown) => (result as { deny?: string }).deny

  for (const [family, mode] of [['watson', 'Watson Direct-mode'], ['holmes', 'Holmes Local-mode']] as const) {
    test(`a ${family} brief with no no-mutation line is refused, the refusal names the line to add, and nothing is spawned`, async ($, on) => {
      const w = world(on)
      const deny = denyOf(await $.agent.spawn(spawnInput(T(family), withConstraints('Constraints: none'))))
      expect(deny?.split('\n')[0]).toBe(`🛑 Blocked: a ${mode} dispatch whose brief does not rule out mutation testing.`)
      expect(deny).toContain('Add this exact bullet as the last item of every Constraints: block: "- Run no mutation testing of any kind."')
      expect(deny).not.toContain('Acceptance: "')
      expect(w.spawned).toEqual([])
    })

    test(`a ${family} brief with a fails-when-removed criterion is refused, and the refusal says to state what the test covers`, async ($, on) => {
      const w = world(on)
      const deny = denyOf(await $.agent.spawn(spawnInput(T(family), withAcceptance('- AC1: the test fails if the guard is removed'))))
      expect(deny).toContain('- Acceptance: "- AC1: the test fails if the guard is removed"')
      expect(deny).toContain('Rephrase it to state what the test covers instead')
      expect(deny).toContain('put them in backticks, which the gate does not read')
      expect(deny).not.toContain('Add this exact bullet as the last item of every Constraints: block:')
      expect(w.spawned).toEqual([])
    })

    test(`a ${family} brief with both faults names both fixes`, async ($, on) => {
      const w = world(on)
      const prompt = withAcceptance('- AC1: the test fails if the guard is removed').replace(`Constraints:\n${NO_LINE}`, 'Constraints: none')
      const deny = denyOf(await $.agent.spawn(spawnInput(T(family), prompt)))
      expect(deny).toContain('Add this exact bullet as the last item of every Constraints: block:')
      expect(deny).toContain('- Acceptance: "- AC1: the test fails if the guard is removed"')
      expect(w.spawned).toEqual([])
    })

    test(`a ${family} brief whose line a later "unless" bullet voids is refused, the refusal quotes that bullet and says to put the line last, and nothing is spawned`, async ($, on) => {
      const w = world(on)
      const deny = denyOf(await $.agent.spawn(spawnInput(T(family), withConstraints(`Constraints:\n${NO_LINE}\n- Do not touch the cache unless it is stale.`))))
      expect(deny?.split('\n')[0]).toBe(`🛑 Blocked: a ${mode} dispatch whose brief does not rule out mutation testing.`)
      expect(deny).toContain('- The Constraints: item "- Do not touch the cache unless it is stale." comes after the no-mutation line')
      expect(deny).toContain('Put the exact line "- Run no mutation testing of any kind." last in its Constraints: block, after every other item.')
      expect(deny).not.toContain('carries no no-mutation line')
      expect(w.spawned).toEqual([])
    })

    test(`a ${family} brief whose line carries its own exception is refused with the guidance to add the exact line`, async ($, on) => {
      const w = world(on)
      const deny = denyOf(await $.agent.spawn(spawnInput(T(family), withConstraints('Constraints:\n- Run no mutation testing of any kind unless asked.'))))
      expect(deny).toContain('Add this exact bullet as the last item of every Constraints: block: "- Run no mutation testing of any kind."')
      expect(deny).not.toContain('- The Constraints: item')
      expect(w.spawned).toEqual([])
    })

    test(`a ${family} brief with the line last, after an earlier bullet holding "unless", is spawned`, async ($, on) => {
      const w = world(on)
      const result = await $.agent.spawn(spawnInput(T(family), withConstraints(`Constraints:\n- Do not touch the cache unless it is stale.\n${NO_LINE}`)))
      expect(denyOf(result)).toBeUndefined()
      expect(w.spawned.map(s => s.subagentType)).toEqual([T(family === 'watson' ? 'watson-direct' : 'holmes-local')])
    })

    test(`a ${family} brief whose last item ends in "fails" and whose Unit: line names a delete is spawned`, async ($, on) => {
      const w = world(on)
      const prompt = withAcceptance('- AC1: the parser test fails').replace('Done when:', 'Unit: 2 of 4, delete the old layout constant. Meets AC1.\nDone when:')
      const result = await $.agent.spawn(spawnInput(T(family), prompt))
      expect(denyOf(result)).toBeUndefined()
      expect(w.spawned.map(s => s.subagentType)).toEqual([T(family === 'watson' ? 'watson-direct' : 'holmes-local')])
    })

    test(`a ${family} brief whose Unit: line holds a removal word and a failure word is refused, and the refusal quotes that line alone`, async ($, on) => {
      const w = world(on)
      const prompt = BRIEF.replace('Done when:', 'Unit: 2 of 4, the test fails if the guard is removed.\nDone when:')
      const deny = denyOf(await $.agent.spawn(spawnInput(T(family), prompt)))
      expect(deny?.split('\n')[0]).toBe(`🛑 Blocked: a ${mode} dispatch whose brief does not rule out mutation testing.`)
      expect(deny).toContain('- Unit: "2 of 4, the test fails if the guard is removed." mentions mutation')
      expect(deny).not.toContain('- Acceptance: "')
      expect(w.spawned).toEqual([])
    })

    test(`a ${family} brief whose Unit: line voids the no-mutation line with "unless" is refused, and nothing is spawned`, async ($, on) => {
      const w = world(on)
      const prompt = withConstraints(`Constraints:\n${NO_LINE}\nUnit: 1 of 2, unless the reviewer asks for a stronger check.`)
      const deny = denyOf(await $.agent.spawn(spawnInput(T(family), prompt)))
      expect(deny).toContain('- The Constraints: item "Unit: 1 of 2, unless the reviewer asks for a stronger check." comes after the no-mutation line')
      expect(w.spawned).toEqual([])
    })

    test(`a ${family} brief whose Unit: line wraps onto a line with a failure word is refused, quoting both lines as one Unit item`, async ($, on) => {
      const w = world(on)
      const prompt = withAcceptance('- AC1: the field survives\nUnit: 2 of 4, delete the old guard\n  and show the test fails')
      const deny = denyOf(await $.agent.spawn(spawnInput(T(family), prompt)))
      expect(deny).toContain('- Unit: "2 of 4, delete the old guard and show the test fails" mentions mutation')
      expect(w.spawned).toEqual([])
    })

    for (const [name, prompt, quote] of [
      [
        'a removal word in an item and a failure word wrapped from the Unit: line after it',
        withAcceptance('- Delete the assertion\nUnit: 1 of 2\n  and the suite fails'),
        '- Acceptance: "- Delete the assertion Unit: 1 of 2 and the suite fails" mentions mutation',
      ],
      [
        'a removal word on a Unit: line under an empty label and a failure word after a blank line',
        BRIEF.replace('Acceptance:\n- AC1: the field survives', 'Acceptance:\nUnit: delete x\n\nthe test fails'),
        '- Unit: "delete x the test fails" mentions mutation',
      ],
    ] as const) {
      test(`a ${family} brief with ${name} is refused, the refusal quotes the joined text, and nothing is spawned`, async ($, on) => {
        const w = world(on)
        const deny = denyOf(await $.agent.spawn(spawnInput(T(family), prompt)))
        expect(deny?.split('\n')[0]).toBe(`🛑 Blocked: a ${mode} dispatch whose brief does not rule out mutation testing.`)
        expect(deny).toContain(quote)
        expect(w.spawned).toEqual([])
      })
    }

    for (const slot of ['Acceptance:', 'Constraints:'] as const) {
      test(`a ${family} brief with no findable ${slot} slot is refused for that slot, and nothing is spawned`, async ($, on) => {
        const w = world(on)
        const deny = denyOf(await $.agent.spawn(spawnInput(T(family), BRIEF.replace(slot, `The ${slot.slice(0, -1).toLowerCase()} list`))))
        expect(deny?.split('\n')[0]).toBe(
          family === 'holmes' ? `🛑 Blocked: a Holmes Local-mode dispatch whose brief lacks ${slot}.` : `🛑 Blocked: a ${mode} dispatch whose brief does not rule out mutation testing.`,
        )
        if (family === 'watson') expect(deny).toContain(`- ${slot} could not be found.`)
        expect(deny).not.toContain('Add this exact bullet')
        expect(w.spawned).toEqual([])
      })
    }

    for (const label of ['**Acceptance**:', 'acceptance:', '**Acceptance:**'] as const) {
      test(`a ${family} brief labelled ${JSON.stringify(label)} is read and spawned`, async ($, on) => {
        const w = world(on)
        const result = await $.agent.spawn(spawnInput(T(family), BRIEF.replace('Acceptance:', label)))
        expect(denyOf(result)).toBeUndefined()
        expect(w.spawned.map(s => s.subagentType)).toEqual([T(family === 'watson' ? 'watson-direct' : 'holmes-local')])
      })
    }

    test(`a ${family} brief with the no-mutation line and a coverage criterion is spawned`, async ($, on) => {
      const w = world(on)
      const result = await $.agent.spawn(spawnInput(T(family), withAcceptance('- AC1: a test covers the dropped field')))
      expect(denyOf(result)).toBeUndefined()
      expect(w.spawned.map(s => s.subagentType)).toEqual([T(family === 'watson' ? 'watson-direct' : 'holmes-local')])
    })

    test(`a ${family} brief from a sub-agent caller is judged, and nothing is spawned`, async ($, on) => {
      const w = world(on)
      const deny = denyOf(await $.agent.spawn(spawnInput(T(family), withConstraints('Constraints: none'), { parentAgentId: 'agent-parent' })))
      expect(deny).toContain('No-mutation rule (workbench-dev-team).')
      expect(w.spawned).toEqual([])
    })

    test(`a ${family} brief is judged with the orchestrator off`, async ($, on) => {
      const w = world(on, { isOn: false })
      const deny = denyOf(await $.agent.spawn(spawnInput(T(family), withConstraints('Constraints: none'))))
      expect(deny).toContain('No-mutation rule (workbench-dev-team).')
      expect(w.spawned).toEqual([])
    })

    test(`a ${family} dispatch whose routing throws is refused, never spawned unjudged`, async ($, on) => {
      const w = world(on)
      const deny = denyOf(await $.agent.spawn(spawnInput(T(family), 42 as never, { parentAgentId: 'agent-parent' })))
      expect(deny?.split('\n')[0]).toBe('🛑 Blocked: an Agent dispatch the dev-team spawn rules could not judge.')
      expect(w.spawned).toEqual([])
    })
  }

  for (const [from, prompt, to] of [
    ['watson', 'Item ID: 42', 'watson-index'],
    ['holmes', 'Item ID: 42', 'holmes-index'],
    ['lestrade', 'Repo sweep: mike-bronner/phpcs-rules', 'lestrade-sweep'],
    ['lestrade', BRIEF.replace(`Constraints:\n${NO_LINE}`, 'Constraints: none'), 'lestrade'],
  ] as const) {
    test(`${from} with ${JSON.stringify(prompt.slice(0, 24))} carries no no-mutation line and runs ${to}`, async ($, on) => {
      const w = world(on)
      const result = await $.agent.spawn(spawnInput(T(from), prompt))
      expect(denyOf(result)).toBeUndefined()
      expect(w.spawned.map(s => s.subagentType)).toEqual([T(to)])
    })
  }

  test('a general-purpose dispatch with a banned criterion and no line passes', async ($, on) => {
    const w = world(on)
    const prompt = withAcceptance('- AC1: the test fails if the guard is removed').replace(`Constraints:\n${NO_LINE}`, 'Constraints: none')
    const result = await $.agent.spawn(spawnInput('general-purpose', prompt))
    expect(denyOf(result)).toBeUndefined()
    expect(w.spawned.map(s => s.subagentType)).toEqual(['general-purpose'])
  })

  test('a Lestrade brief with a fails-when-removed criterion is routed but not judged', async ($, on) => {
    const w = world(on)
    const prompt = withAcceptance('- AC1: the test fails if the guard is removed').replace(`Constraints:\n${NO_LINE}`, 'Constraints: none')
    const result = await $.agent.spawn(spawnInput(T('lestrade'), prompt))
    expect(denyOf(result)).toBeUndefined()
    expect(w.spawned.map(s => s.subagentType)).toEqual([T('lestrade')])
  })
})

describe('a message to a Watson or Holmes — a resume, or a send, is judged on its own text', () => {
  const CORRECTION = 'One correction to your brief: rename the helper to parseField.'
  const denyOf = (result: unknown) => (result as { deny?: string }).deny
  const resume = (type: string, prompt: string, agentId = 'agent-1') => spawnInput(type, prompt, { resume: { agentId } })
  const HEAD = 'that does not rule out mutation testing.'
  const NOT_RESUMED = 'The message was not delivered, and no agent resumed.'

  for (const [family, mode, token] of [
    ['watson', 'watson-direct', BRIEF],
    ['holmes', 'holmes-local', BRIEF],
    ['watson', 'watson-index', 'Item ID: 42'],
    ['holmes', 'holmes-index', 'Item ID: 42'],
  ] as const) {
    test(`a resume of a ${mode} with a short correction and no Constraints: or Acceptance: block runs, unchanged, though a fresh spawn of that text is refused`, async ($, on) => {
      const w = world(on, { run: () => ({ exitCode: 0, stdout: 'dispatched\n', stderr: '' }) })
      await $.agent.spawn(spawnInput(T(family), token))
      const fresh = denyOf(await $.agent.spawn(spawnInput(T(family), CORRECTION)))
      expect(fresh).toContain('Constraints:')
      const resumed = await $.agent.spawn(resume(T(mode), CORRECTION))
      expect(denyOf(resumed)).toBeUndefined()
      expect(w.spawned.slice(1)).toEqual([{ subagentType: T(mode), model: undefined, prompt: CORRECTION }])
    })
  }

  test('a resume that restates the no-mutation line runs', async ($, on) => {
    const w = world(on)
    await $.agent.spawn(spawnInput(T('watson'), BRIEF))
    const result = await $.agent.spawn(resume(T('watson-direct'), `${CORRECTION}\n- Run no mutation testing of any kind.`))
    expect(denyOf(result)).toBeUndefined()
    expect(w.spawned).toHaveLength(2)
  })

  for (const [label, message, quoted] of [
    ['a line that mentions mutation', `${CORRECTION}\nThen run a mutation pass on the parser.`, `${CORRECTION} Then run a mutation pass on the parser.`],
    ['a line with a removal word and a failure word', 'Check that the test fails when the guard is removed.', 'Check that the test fails when the guard is removed.'],
    ['a removal word and a failure word on two lines in a row', 'Delete the guard\nand watch the parser test go red.', 'Delete the guard and watch the parser test go red.'],
  ] as const) {
    for (const [family, mode, agent] of [
      ['watson', 'watson-direct', 'Watson'],
      ['holmes', 'holmes-local', 'Holmes'],
    ] as const) {
      test(`a resume of a ${mode} with ${label} is refused, the refusal quotes its item and says nothing resumed`, async ($, on) => {
        const w = world(on)
        await $.agent.spawn(spawnInput(T(family), BRIEF))
        const deny = denyOf(await $.agent.spawn(resume(T(mode), message)))
        expect(deny?.split('\n')[0]).toBe(`🛑 Blocked: a message to a ${agent} ${HEAD}`)
        expect(deny).toContain(NOT_RESUMED)
        expect(deny).toContain(`- The item "${quoted}" mentions mutation`)
        expect(w.spawned).toHaveLength(1)
      })
    }
  }

  test('a resume whose Constraints: block puts an exception after the no-mutation line is refused, and the refusal quotes the item', async ($, on) => {
    const w = world(on)
    await $.agent.spawn(spawnInput(T('watson'), BRIEF))
    const deny = denyOf(await $.agent.spawn(resume(T('watson-direct'), `${CORRECTION}\nConstraints:\n- Run no mutation testing of any kind.\n- Keep the cache unless it is stale.`)))
    expect(deny).toContain(NOT_RESUMED)
    expect(deny).toContain('- The Constraints: item "- Keep the cache unless it is stale." comes after the no-mutation line')
    expect(deny).not.toContain('- The item "')
    expect(w.spawned).toHaveLength(1)
  })

  const AFTER_LINE = 'Run no mutation testing of any kind. Then delete the guard and confirm the test fails.'

  for (const [label, message, quoted] of [
    ['text after the ban sentence on its line', AFTER_LINE, AFTER_LINE],
    ['a bullet wrapped over three lines', `${CORRECTION}\n- Remove the guard clause\n  from the handler so that\n  the parser test fails.`, '- Remove the guard clause from the handler so that the parser test fails.'],
    ['a bullet split by a blank line', '- Remove the guard clause\n\n  so the parser test fails.', '- Remove the guard clause so the parser test fails.'],
  ] as const) {
    test(`a resume with ${label} is refused, and the refusal quotes the whole item`, async ($, on) => {
      const w = world(on)
      await $.agent.spawn(spawnInput(T('watson'), BRIEF))
      const deny = denyOf(await $.agent.spawn(resume(T('watson-direct'), message)))
      expect(deny).toContain(NOT_RESUMED)
      expect(deny).toContain(`- The item "${quoted}" mentions mutation`)
      expect(w.spawned).toHaveLength(1)
    })
  }

  test('a resume with two separate bullets, one with a removal word and one with a failure word, runs', async ($, on) => {
    const w = world(on)
    await $.agent.spawn(spawnInput(T('watson'), BRIEF))
    const result = await $.agent.spawn(resume(T('watson-direct'), `${CORRECTION}\n- Remove the stale cache\n- the build fails on CI`))
    expect(denyOf(result)).toBeUndefined()
    expect(w.spawned).toHaveLength(2)
  })

  for (const [label, message] of [
    ['two prose paragraphs', 'Remove the stale import.\n\nCI failed on the lint step.'],
    ['a bullet, a blank line, then a paragraph', '- Delete the stale comment at x.ts:4\n\nThe CI run fails on Linux.'],
  ] as const) {
    test(`a resume with ${label} judges each as its own item, and runs`, async ($, on) => {
      const w = world(on)
      await $.agent.spawn(spawnInput(T('watson'), BRIEF))
      expect(denyOf(await $.agent.spawn(resume(T('watson-direct'), message)))).toBeUndefined()
      expect(w.spawned).toHaveLength(2)
    })
  }

  test('a rejected read of the kept type is taken as a Watson or Holmes, so a banned resume is still refused', async () => {
    const agent = await resumedAgentOfRead(Promise.reject(new Error('state unreadable')), 'general-purpose')
    expect(agent).toBe('Watson or Holmes')
    expect(resumeRefusalOf(agent, 'Run a mutation pass.')?.split('\n')[0]).toBe(`🛑 Blocked: a message to a Watson or Holmes ${HEAD}`)
    expect(resumeRefusalOf(await resumedAgentOfRead(Promise.resolve(undefined), 'general-purpose'), 'Run a mutation pass.')).toBeUndefined()
  })

  test('a fresh brief whose Acceptance: item puts text after the ban sentence is judged on that text, and refused', async ($, on) => {
    const w = world(on)
    const deny = denyOf(await $.agent.spawn(spawnInput(T('watson'), BRIEF.replace('- AC1: the field survives', `- ${AFTER_LINE}`))))
    expect(deny).toContain(`- Acceptance: "- ${AFTER_LINE}" mentions mutation`)
    expect(w.spawned).toEqual([])
  })

  test('a resume the mod has no kept type for is judged by the type it carries', async ($, on) => {
    const w = world(on)
    const deny = denyOf(await $.agent.spawn(resume(T('holmes-index'), 'Run a mutation pass.', 'agent-elsewhere')))
    expect(deny?.split('\n')[0]).toBe(`🛑 Blocked: a message to a Holmes ${HEAD}`)
    expect(w.spawned).toEqual([])
  })

  test('the kept type wins over the type the resume carries', async ($, on) => {
    const w = world(on)
    await $.agent.spawn(spawnInput(T('watson'), BRIEF))
    const deny = denyOf(await $.agent.spawn(resume('general-purpose', 'Run a mutation pass.')))
    expect(deny?.split('\n')[0]).toBe(`🛑 Blocked: a message to a Watson ${HEAD}`)
    expect(w.spawned).toHaveLength(1)
  })

  test('a resume of an agent outside Watson and Holmes is not judged', async ($, on) => {
    const w = world(on)
    for (const type of ['general-purpose', T('lestrade')]) {
      expect(denyOf(await $.agent.spawn(resume(type, 'Run a mutation pass.', `agent-${type}`)))).toBeUndefined()
    }
    expect(w.spawned).toHaveLength(2)
  })

  type Sent = { isDelivered: boolean; reason?: string }
  const sendWorld = (on: Plugin['on'], agents: Parameters<typeof world>[1]['agents']) => {
    const w = world(on, { agents })
    const sent: string[] = []
    on('session.send', async ($, e) => {
      sent.push(e.text)
      return { isDelivered: true }
    })
    return { w, sent }
  }
  const FINISHED = [
    { id: 'agent-w', type: T('watson-direct'), status: 'completed', name: 'fixer', teammateId: 'fixer@crew' },
    { id: 'agent-h', type: T('holmes-local'), status: 'completed' },
    { id: 'agent-g', type: 'general-purpose', status: 'completed', name: 'helper' },
  ]

  for (const [to, agent] of [
    ['agent-w', 'Watson'],
    ['fixer', 'Watson'],
    ['fixer@crew', 'Watson'],
    ['agent-h', 'Holmes'],
  ] as const) {
    test(`a banned correction sent to the finished ${agent} at "${to}" is refused before it is queued, and the sender reads that nothing resumed`, async ($, on) => {
      const { sent } = sendWorld(on, FINISHED)
      const answer = (await $.session.send({ to, text: 'Check that the test fails when the guard is removed.' })) as Sent
      expect(answer.isDelivered).toBe(false)
      expect(answer.reason?.split('\n')[0]).toBe(`🛑 Blocked: a message to a ${agent} ${HEAD}`)
      expect(answer.reason).toContain(NOT_RESUMED)
      expect(sent).toEqual([])
    })
  }

  test('a short correction sent to a finished Watson is delivered', async ($, on) => {
    const { sent } = sendWorld(on, FINISHED)
    const answer = (await $.session.send({ to: 'fixer', text: CORRECTION })) as Sent
    expect(answer.isDelivered).toBe(true)
    expect(sent).toEqual([CORRECTION])
  })

  test('a banned message to an agent outside Watson and Holmes, or to an address no agent holds, is delivered', async ($, on) => {
    const { sent } = sendWorld(on, FINISHED)
    for (const to of ['helper', 'other-session']) {
      expect(((await $.session.send({ to, text: 'Run a mutation pass.' })) as Sent).isDelivered).toBe(true)
    }
    expect(sent).toHaveLength(2)
  })

  test('a banned message is refused when the agent list cannot be read', async ($, on) => {
    const { sent } = sendWorld(on, new Error('list unreadable'))
    const answer = (await $.session.send({ to: 'fixer', text: 'Run a mutation pass.' })) as Sent
    expect(answer.isDelivered).toBe(false)
    expect(answer.reason?.split('\n')[0]).toBe(`🛑 Blocked: a message to a Watson or Holmes ${HEAD}`)
    expect(sent).toEqual([])
  })

  test('a send to a Watson the mod started is judged by its kept type when the list names another', async ($, on) => {
    const { w, sent } = sendWorld(on, [{ id: 'agent-1', type: 'general-purpose', status: 'completed' }])
    await $.agent.spawn(spawnInput(T('watson'), BRIEF))
    const answer = (await $.session.send({ to: 'agent-1', text: 'Run a mutation pass.' })) as Sent
    expect(answer.isDelivered).toBe(false)
    expect(sent).toEqual([])
    expect(w.spawned).toHaveLength(1)
  })
})
