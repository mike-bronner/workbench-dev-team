import { describe, expect, test } from 'claude-code/testing'
import type { Plugin } from 'claude-code/testing'

import { configLineOf, configTextOf, isGated, isHolmesMode, knobsOf, lensSpawnOf, mutationDeny, mutationFindingsOf, withConfigLine, workdirOf } from '../hooks/mods/spawn'
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

  test('a Watson prompt on main with a bare Workdir and no other slot is refused too', async ($, on) => {
    const w = world(on, { run: onBranch('main') })
    const result = (await $.agent.spawn(spawnInput(T('watson'), 'Workdir: /tmp/repo\nfix the parser'))) as Spawned
    expect(result.deny).toContain('onto main, with no branch recorded')
    expect(w.spawned).toEqual([])
  })

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

  test('a lane callerLane cannot give is read as the main session, so the brief on main is refused', async ($, on) => {
    const w = world(on, { run: onBranch('main'), lane: () => new Error('workbench: the lane is unknown') })
    expect(((await $.agent.spawn(spawnInput(T('watson'), BRIEF))) as Spawned).deny).toContain('onto main, with no branch recorded')
    expect(w.spawned).toEqual([])
  })

  test('an orchestrator mode that cannot be read is on, so the brief on main is refused', async ($, on) => {
    const w = world(on, { run: onBranch('main'), isOn: new Error('no state') })
    expect(((await $.agent.spawn(spawnInput(T('watson'), BRIEF))) as Spawned).deny).toContain('onto main, with no branch recorded')
    expect(w.spawned).toEqual([])
  })

  test("a top-level --agent run's Watson brief is not checked, and runs no git", async ($, on) => {
    const w = world(on, { run: onBranch('main'), lane: () => 'top-level-agent' })
    expect(((await $.agent.spawn(spawnInput(T('watson'), BRIEF))) as Spawned).deny).toBeUndefined()
    expect(w.runs).toEqual([])
    expect(w.spawned.map(s => s.subagentType)).toEqual([T('watson-direct')])
  })
})

describe('isGated — only the main session with orchestrator mode on', () => {
  for (const [lane, isOn, want] of [
    ['main', true, true],
    ['main', false, false],
    ['sub-agent', true, false],
    ['sub-agent', false, false],
    ['top-level-agent', true, false],
    ['top-level-agent', false, false],
  ] as const) {
    test(`${lane}, orchestrator ${isOn ? 'on' : 'off'}: ${want ? 'gated' : 'not gated'}`, () => {
      expect(isGated(lane, isOn)).toBe(want)
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

describe('mutationFindingsOf — the exact line and the strict ban', () => {
  const NO_LINE = '- Run no mutation testing of any kind.'
  const withConstraints = (lines: string) => BRIEF.replace(`Constraints:\n${NO_LINE}`, lines)
  const withAcceptance = (line: string) => BRIEF.replace('- AC1: the field survives', line)
  const CLEAN = { missingSlots: [], lacksNoMutationLine: false, bannedItems: [] }
  const bannedOf = (prompt: string) => mutationFindingsOf(prompt).bannedItems

  for (const constraints of [
    `Constraints:\n${NO_LINE}`,
    'Constraints:\n- run no mutation testing of any kind',
    "Constraints:\n- Run no mutation testing of any kind: the human's standing rule.",
    'Constraints:\n* **Run no mutation testing of any kind.**',
    'Constraints:\n1. Run no mutation testing of any kind.',
    'Constraints:\n1) Run no mutation testing of any kind.',
    'Constraints:\n- "Run no mutation testing of any kind."',
    'Constraints:\n- (Run no mutation testing of any kind.)',
    'Constraints: Run no mutation testing of any kind.',
    `Constraints:\n- Keep the public API: callers depend on it.\n${NO_LINE}`,
    `**Constraints**:\n${NO_LINE}`,
    `Constraints:\n- Except on Fridays, keep the deploy frozen.\n${NO_LINE}`,
  ]) {
    test(`${JSON.stringify(constraints)} carries the exact line`, () => {
      expect(mutationFindingsOf(withConstraints(constraints))).toEqual(CLEAN)
    })
  }

  for (const [name, prompt] of [
    ['reads "none"', withConstraints('Constraints: none')],
    ['holds other bullets only', withConstraints('Constraints:\n- Keep the public API: callers depend on it.')],
    ['words the rule another way', withConstraints('Constraints:\n- Never run mutation checks.')],
    ['says "of any kind-ish"', withConstraints('Constraints:\n- Run no mutation testing of any kind-ish.')],
    ['says "of any kinds"', withConstraints('Constraints:\n- Run no mutation testing of any kinds.')],
    ['follows the line with "except"', withConstraints('Constraints:\n- Run no mutation testing of any kind, except on the parser.')],
    ['follows the line with "but"', withConstraints('Constraints:\n- Run no mutation testing of any kind: but a spot check is fine.')],
    ['follows the line with "unless"', withConstraints('Constraints:\n- Run no mutation testing of any kind unless asked.')],
    ['follows the line with "other than"', withConstraints('Constraints:\n- Run no mutation testing of any kind other than Pest runs.')],
    ['has the line only in Acceptance', withConstraints('Constraints: none').replace('- AC1: the field survives', '- AC1: the field survives\n- AC2: Run no mutation testing of any kind.')],
    ['has the line only as a quoted line', withConstraints('Constraints:\n> Run no mutation testing of any kind.')],
    ['has the line only as a sub-bullet under a parent bullet', withConstraints('Constraints:\n- Keep the public API: callers depend on it.\n  - Run no mutation testing of any kind.')],
    ['lacks the line, though a quoted Constraints: line in Context holds it', withConstraints('Constraints: none').replace('Context: It drops a field.', 'Context: It drops a field.\n> Constraints: Run no mutation testing of any kind.')],
    ['has a second block without the line', `${BRIEF}\nConstraints:\n- Keep the public API.`],
    ['voids the line with a later "Except" bullet', withConstraints(`Constraints:\n${NO_LINE}\n- Except on the parser.`)],
    ['voids the line with a later bullet holding "but"', withConstraints(`Constraints:\n${NO_LINE}\n- Keep the API, but a spot check is fine.`)],
    ['has the line only in Context', withConstraints('Constraints: none').replace('Context: It drops a field.', 'Context: It drops a field. Run no mutation testing of any kind.')],
  ] as const) {
    test(`a brief whose Constraints: ${name} lacks the exact line`, () => {
      expect(mutationFindingsOf(prompt).lacksNoMutationLine).toBe(true)
    })
  }

  for (const criterion of [
    '- AC1: prove the guard with a mutation check',
    '- AC1: Watson runs no mutation testing',
    '- AC1: kill every mutant',
    '- AC1: no surviving mutants',
    '- AC1: run _mutation testing_ on the parser',
    '- AC1: the test fails if the guard is removed',
    '- AC1: If the guard is removed, the test fails.',
    '- AC1: deleting either rule turns them red',
    '- AC1: removing the guard turns the suite red',
    '- AC1: the spec breaks with the check deleted',
    '- AC1: the test breaking once the guard is deleted',
    '- AC1: the test fail when the guard is deleted',
    '- AC1: the test failed after the guard was reverted',
    '- AC1: the test failing once the fix is restored',
    '- AC1: the test fails with the guard commented out',
    '- AC1: a commented-out guard fails the test',
    '- AC1: the lint goes red when the condition is inverted',
    '- AC1: the lint went red when the guard was dropped',
    '- AC1: the lint turned red when the rule was disabled',
    '- AC1: the lint turns red when the guard is removed',
    '- AC1: the test reddens once the fix is undone',
    '- AC1: removing the guard is a test failure',
    '- AC1: the build broke once the check was deleted',
    '- AC1: the suite is broken after the guard is skipped and removed',
    '- AC1: no existing test fails after the helper is removed',
    '- AC1: the new parser test fails\n  if the guard is removed.',
    '- AC1: the guard\n  - is removed\n  - and the test fails',
    '- AC1: removing the guard turns the whole build red',
  ]) {
    test(`Acceptance ${JSON.stringify(criterion)} is banned`, () => {
      expect(bannedOf(withAcceptance(criterion))).toEqual([{ slot: 'Acceptance:', item: criterion.replace(/\n\s*/gu, ' ') }])
    })
  }

  for (const criterion of [
    '- AC1: a test covers the dropped field',
    '- AC1: a test covers the GraphQL `mutation` endpoint',
    '- AC1: the gate refuses `the test fails if X is removed`',
    '- AC1: a test covers the immutable cache',
    '- AC1: the importer reports an error when the source file is deleted',
    '- AC1: the test fails on bad input',
    '- AC1: a test covers the commutation table',
    '- AC1: a test covers every permutation',
    '- AC1: removing the cache turns the whole big build red',
    '- AC1: a test covers the parser\n  when the field is missing',
  ]) {
    test(`Acceptance ${JSON.stringify(criterion)} passes`, () => {
      expect(mutationFindingsOf(withAcceptance(criterion))).toEqual(CLEAN)
    })
  }

  test('the AC1:, 1. and * bullet shapes each start their own item', () => {
    const prompt = withAcceptance('AC1: the test fails\n1. the guard is removed\n* the lint goes red')
    expect(bannedOf(prompt)).toEqual([])
  })

  test('a clean first Acceptance block does not hide a banned second one', () => {
    const prompt = `${BRIEF}\nAcceptance:\n- AC9: the test fails if the guard is removed`
    expect(bannedOf(prompt)).toEqual([{ slot: 'Acceptance:', item: '- AC9: the test fails if the guard is removed' }])
  })

  test('an item that starts a Goal: line is still judged', () => {
    const prompt = withAcceptance('- AC1: the field survives\nGoal: run a mutation check')
    expect(bannedOf(prompt)).toEqual([{ slot: 'Goal:', item: 'run a mutation check' }])
  })

  for (const [slot, prompt] of [
    ['Goal:', BRIEF.replace('Goal: Fix the parser.', 'Goal: Fix the parser, and prove it with a mutation check.')],
    ['Done when:', BRIEF.replace('Done when: the test passes.', 'Done when: the test fails if the guard is removed.')],
  ] as const) {
    test(`the ban applies to ${slot}`, () => {
      expect(bannedOf(prompt).map(b => b.slot)).toEqual([slot])
    })
  }

  test('a quoted Constraints: line supplies no slot', () => {
    const prompt = BRIEF.replace(`Constraints:\n${NO_LINE}`, '> Constraints: Run no mutation testing of any kind.')
    expect(mutationFindingsOf(prompt).missingSlots).toEqual(['Constraints:'])
  })

  test('a quoted Acceptance: line in Context opens no judged block', () => {
    const prompt = BRIEF.replace('Context: It drops a field.', 'Context: It drops a field.\n> Acceptance: the test fails if the guard is removed')
    expect(mutationFindingsOf(prompt)).toEqual(CLEAN)
  })

  test('items after a stray Context: label inside Acceptance are still judged', () => {
    const prompt = withAcceptance('- AC1: the field survives\nContext: an aside\n- AC2: run a mutation check')
    expect(bannedOf(prompt)).toEqual([{ slot: 'Context:', item: '- AC2: run a mutation check' }])
  })

  test('items after a stray Workdir: label inside Done when are still judged', () => {
    const prompt = BRIEF.replace('Done when: the test passes.', 'Done when: the test passes.\nWorkdir: /tmp/other\n- the test fails if the guard is removed')
    expect(bannedOf(prompt)).toEqual([{ slot: 'Workdir:', item: '- the test fails if the guard is removed' }])
  })

  test('items after a stray Constraints: label inside Acceptance are still judged, and the line itself is not banned', () => {
    const prompt = withAcceptance(`- AC1: the field survives\nConstraints:\n${NO_LINE}\n- AC2: run a mutation check`)
    expect(mutationFindingsOf(prompt)).toEqual({ ...CLEAN, bannedItems: [{ slot: 'Constraints:', item: '- AC2: run a mutation check' }] })
  })

  test('the first Constraints: block is not read for banned wording', () => {
    expect(mutationFindingsOf(withConstraints(`Constraints:\n${NO_LINE}\n- Keep the mutation API stable.`))).toEqual(CLEAN)
  })

  test('Context: stays unscanned', () => {
    const findings = mutationFindingsOf(BRIEF.replace('Context: It drops a field.', 'Context: An earlier run ran mutation checks, and the test failed when the guard was removed.'))
    expect(findings).toEqual(CLEAN)
  })

  for (const [label, end] of [
    ['acceptance:', 'Done when:'],
    ['**Acceptance**:', '**Done when:**'],
    ['**Acceptance:**', '**Done when**:'],
    ['## Acceptance:', '_done when_:'],
    ['`Acceptance`:', 'DONE WHEN:'],
  ] as const) {
    test(`the label ${JSON.stringify(label)} is read, and ${JSON.stringify(end)} ends the slot`, () => {
      const prompt = withAcceptance('- AC1: the test fails if the guard is removed')
        .replace('Acceptance:', label)
        .replace('Done when: the test passes.', `${end} the field survives.`)
      expect(mutationFindingsOf(prompt)).toEqual({ ...CLEAN, bannedItems: [{ slot: 'Acceptance:', item: '- AC1: the test fails if the guard is removed' }] })
    })
  }

  for (const slot of ['Acceptance:', 'Constraints:'] as const) {
    test(`a brief with no findable ${slot} slot is a finding`, () => {
      const prompt = BRIEF.replace(slot, `The ${slot.slice(0, -1).toLowerCase()} list`)
      expect(mutationFindingsOf(prompt).missingSlots).toEqual([slot])
    })
  }
})

describe('mutationDeny — the refusal text', () => {
  test('it names each fix, and cuts a long item with an ellipsis', () => {
    const long = `- AC1: the test fails if ${'x'.repeat(300)} is removed`
    const deny = mutationDeny('Watson Direct-mode', {
      missingSlots: ['Acceptance:'],
      lacksNoMutationLine: true,
      bannedItems: [{ slot: 'Done when:', item: long }],
    })
    const lines = deny.split('\n')
    expect(lines[0]).toBe('🛑 Blocked: a Watson Direct-mode dispatch whose brief does not rule out mutation testing.')
    expect(lines).toContain('- Acceptance: could not be found. Write it as a label at the start of its own line, such as "Acceptance:".')
    expect(lines).toContain('- A Constraints: block carries no no-mutation line. Add this exact bullet to every Constraints: block: "- Run no mutation testing of any kind."')
    const banned = lines.find(line => line.startsWith('- Done when: "')) ?? ''
    expect(banned).toContain(`"${long.slice(0, 200)}…"`)
    expect(banned).not.toContain(long)
    expect(banned).toContain('put them in backticks, which the gate does not read')
  })

  for (const [length, ellipsis] of [[200, false], [201, true]] as const) {
    test(`a ${length}-character item is quoted ${ellipsis ? 'cut, with' : 'whole, with no'} ellipsis`, () => {
      const item = `- ${'x'.repeat(length - 2)}`
      const deny = mutationDeny('Watson Direct-mode', { missingSlots: [], lacksNoMutationLine: false, bannedItems: [{ slot: 'Acceptance:', item }] })
      expect(deny).toContain(ellipsis ? `"${item.slice(0, 200)}…"` : `"${item}"`)
    })
  }

  test('with nothing found, it holds no fix line', () => {
    const deny = mutationDeny('Holmes Local-mode', { missingSlots: [], lacksNoMutationLine: false, bannedItems: [] })
    expect(deny.split('\n').filter(line => line.startsWith('- '))).toEqual([])
  })
})
