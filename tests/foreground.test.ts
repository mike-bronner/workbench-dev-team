import { describe, expect, test } from 'claude-code/testing'

import { backgroundDeny, isBackgroundAsked, probeLinesOf } from '../hooks/mods/helper-wait'
import { mktempDeny } from '../hooks/mods/scratch'
import { BRIEF, readPlain, spawnInput, world } from './world'

const T = (name: string) => `workbench-dev-team:${name}`

const bash = (command: string, extra: Record<string, unknown> = {}) => ({ tool: 'Bash', tool_use_id: 'toolu_1', description: 'd', command, ...extra })

const MODES = [
  ['watson-direct', T('watson'), BRIEF, {}],
  ['watson-index', T('watson'), 'Item ID: 5', {}],
  ['holmes-local', T('holmes'), BRIEF, {}],
  ['holmes-index', T('holmes'), 'Item ID: 5', {}],
  ['lestrade', T('lestrade'), BRIEF, {}],
  ['lestrade-item', T('lestrade'), 'Item ID: 5', {}],
  ['lestrade-sweep', T('lestrade'), 'Repo sweep: owner/repo', {}],
  ['holmes-lens', T('holmes-lens'), 'lens prompt', { parentAgentId: 'agent-x' }],
] as const

describe('foreground — a dev-team agent cannot start a background Bash command', () => {
  for (const [mode, type, prompt, extra] of MODES) {
    test(`${mode}'s background Bash call is refused, and nothing runs`, async ($, on) => {
      const w = world(on, { agents: [{ id: 'agent-1', type: T(mode) }] })
      await $.agent.spawn(spawnInput(type, prompt, extra))
      const answer = (await $.tool.call(bash('npm test', { run_in_background: true, agentId: 'agent-1' }) as never)) as { deny?: string }
      expect(answer.deny).toBe(backgroundDeny)
      expect(w.ran).toEqual([])
      expect(w.calls).toEqual([])
    })
  }

  for (const mode of ['watson-index', 'holmes-index', 'lestrade-item', 'lestrade-sweep']) {
    test(`the top-level loop of a ${mode} --agent run is refused too`, async ($, on) => {
      const w = world(on, { lane: () => 'top-level-agent', env: { CLAUDE_CODE_AGENT: T(mode) } })
      const answer = (await $.tool.call(bash('npm test', { run_in_background: true }) as never)) as { deny?: string }
      expect(answer.deny).toBe(backgroundDeny)
      expect(w.ran).toEqual([])
    })
  }

  test('the refusal says to run in the foreground within 600000 ms and to split a longer command, never to background it', () => {
    expect(backgroundDeny).toContain('refuses `run_in_background`, a background `&`, `nohup`, `setsid` and `disown`')
    expect(backgroundDeny).toContain('Run the command again in the foreground, with none of those')
    expect(backgroundDeny).toContain('600000 ms')
    expect(backgroundDeny).toContain('split it into parts that each finish within the limit')
    expect(backgroundDeny).not.toMatch(/run it in the background|`run_in_background: true`/)
  })

  test('the refusal comes before the mktemp rule, and the call is not rewritten to the foreground', async ($, on) => {
    const w = world(on, { agents: [{ id: 'agent-1', type: T('watson-direct') }] })
    await $.agent.spawn(spawnInput(T('watson'), BRIEF))
    const answer = (await $.tool.call(bash('mktemp -d', { run_in_background: true, agentId: 'agent-1' }) as never)) as { deny?: string }
    expect(answer.deny).toBe(backgroundDeny)
    expect(w.calls).toEqual([])
  })
})

describe('foreground — a command that backgrounds itself at shell level is refused too', () => {
  const ampersand = (line: string) => readPlain(line.replace(/ &$/, ' ;').replace(/ & /g, ' ; '))
  for (const line of ['npm test &', 'npm test & echo started', 'setsid npm test', 'disown', 'npm test; disown']) {
    test(`a dev-team agent's ${JSON.stringify(line)} is refused with the foreground text`, async ($, on) => {
      const w = world(on, { agents: [{ id: 'agent-1', type: T('watson-direct') }], reader: ampersand })
      await $.agent.spawn(spawnInput(T('watson'), BRIEF))
      const answer = (await $.tool.call(bash(line, { agentId: 'agent-1' }) as never)) as { deny?: string }
      expect(answer.deny).toBe(backgroundDeny)
      expect(w.calls).toEqual([])
    })
  }

  for (const line of ['npm test && npm run lint', 'npm test 2>&1', 'echo setsid']) {
    test(`a dev-team agent's ${JSON.stringify(line)} reaches the engine unchanged`, async ($, on) => {
      const w = world(on, { agents: [{ id: 'agent-1', type: T('watson-direct') }], reader: text => readPlain(text.replace(' 2>&1', '')) })
      await $.agent.spawn(spawnInput(T('watson'), BRIEF))
      const call = bash(line, { agentId: 'agent-1' })
      await $.tool.call(call as never)
      expect(w.calls).toEqual([call])
    })
  }

  test("the main session's \"npm test &\" reaches the engine unchanged", async ($, on) => {
    const w = world(on, { reader: ampersand })
    const call = bash('npm test &')
    await $.tool.call(call as never)
    expect(w.calls).toEqual([call])
  })
})

describe('foreground — a sub-agent a dev-team agent spawns gets the same refusals', () => {
  const LENS = [
    { id: 'agent-1', type: T('lestrade-item') },
    { id: 'agent-2', type: 'general-purpose', parentId: 'agent-1' },
  ]

  test("a Lestrade lens's background Bash call is refused, found through its parent", async ($, on) => {
    const w = world(on, { agents: LENS })
    await $.agent.spawn(spawnInput(T('lestrade'), 'Item ID: 5'))
    const answer = (await $.tool.call(bash('npm test', { run_in_background: true, agentId: 'agent-2' }) as never)) as { deny?: string }
    expect(answer.deny).toBe(backgroundDeny)
    expect(w.calls).toEqual([])
  })

  test("a Lestrade lens's disown is refused, and its bare mktemp is refused with a folder of its own", async ($, on) => {
    world(on, { agents: LENS, roots: ['/scratch/session'] })
    await $.agent.spawn(spawnInput(T('lestrade'), 'Item ID: 5'))
    expect(((await $.tool.call(bash('disown', { agentId: 'agent-2' }) as never)) as { deny?: string }).deny).toBe(backgroundDeny)
    expect(((await $.tool.call(bash('mktemp -d', { agentId: 'agent-2' }) as never)) as { deny?: string }).deny).toBe(mktempDeny('/scratch/session/general-purpose.abc123'))
  })

  test("a lens's foreground Bash call reaches the engine unchanged", async ($, on) => {
    const w = world(on, { agents: LENS })
    await $.agent.spawn(spawnInput(T('lestrade'), 'Item ID: 5'))
    const call = bash('npm test', { agentId: 'agent-2' })
    await $.tool.call(call as never)
    expect(w.calls).toEqual([call])
  })

  test('a grandchild is found through the whole chain', async ($, on) => {
    world(on, { agents: [...LENS, { id: 'agent-3', type: 'Explore', parentId: 'agent-2' }] })
    await $.agent.spawn(spawnInput(T('lestrade'), 'Item ID: 5'))
    const answer = (await $.tool.call(bash('npm test', { run_in_background: true, agentId: 'agent-3' }) as never)) as { deny?: string }
    expect(answer.deny).toBe(backgroundDeny)
  })

  test('a sub-agent of a top-level dev-team --agent run is refused too', async ($, on) => {
    world(on, { agents: [{ id: 'agent-2', type: 'general-purpose' }], env: { CLAUDE_CODE_AGENT: T('lestrade-item') } })
    const answer = (await $.tool.call(bash('npm test', { run_in_background: true, agentId: 'agent-2' }) as never)) as { deny?: string }
    expect(answer.deny).toBe(backgroundDeny)
  })
})

describe('foreground — the parent walk ends on a broken chain', () => {
  const asked = (agentId: string) => bash('npm test', { run_in_background: true, agentId })

  test('a loop in the parents goes through, and the walk ends', async ($, on) => {
    const w = world(on, {
      agents: [
        { id: 'agent-2', type: 'general-purpose', parentId: 'agent-3' },
        { id: 'agent-3', type: 'Explore', parentId: 'agent-2' },
      ],
    })
    await $.tool.call(asked('agent-2') as never)
    expect(w.calls).toEqual([asked('agent-2')])
  })

  test('a parent missing from the list, with no kept type, goes through', async ($, on) => {
    const w = world(on, { agents: [{ id: 'agent-2', type: 'general-purpose', parentId: 'agent-9' }] })
    await $.tool.call(asked('agent-2') as never)
    expect(w.calls).toEqual([asked('agent-2')])
  })

  test('a parent missing from the list, with a kept dev-team type, is refused', async ($, on) => {
    const w = world(on, { agents: [{ id: 'agent-2', type: 'general-purpose', parentId: 'agent-1' }] })
    await $.agent.spawn(spawnInput(T('lestrade'), 'Item ID: 5'))
    const answer = (await $.tool.call(asked('agent-2') as never)) as { deny?: string }
    expect(answer.deny).toBe(backgroundDeny)
    expect(w.calls).toEqual([])
  })

  test('a kept dev-team type is read before the type the list gives', async ($, on) => {
    const w = world(on, {
      agents: [
        { id: 'agent-1', type: 'general-purpose' },
        { id: 'agent-2', type: 'general-purpose', parentId: 'agent-1' },
      ],
    })
    await $.agent.spawn(spawnInput(T('lestrade'), 'Item ID: 5'))
    const answer = (await $.tool.call(asked('agent-2') as never)) as { deny?: string }
    expect(answer.deny).toBe(backgroundDeny)
    expect(w.calls).toEqual([])
  })

  test('a caller missing from the list goes through', async ($, on) => {
    const w = world(on, { agents: [{ id: 'agent-2', type: 'general-purpose', parentId: 'agent-1' }] })
    await $.tool.call(asked('agent-5') as never)
    expect(w.calls).toEqual([asked('agent-5')])
  })
})

describe('foreground — a run that cannot be looked up', () => {
  test('a top-level dev-team run whose lane cannot be read gets the foreground text, while its foreground call still runs', async ($, on) => {
    const w = world(on, { lane: () => new Error('lane unreadable'), env: { CLAUDE_CODE_AGENT: T('watson-index') } })
    const answer = (await $.tool.call(bash('npm test', { run_in_background: true }) as never)) as { deny?: string }
    expect(answer.deny).toBe(backgroundDeny)
    const call = bash('npm test')
    await $.tool.call(call as never)
    expect(w.calls).toEqual([call])
  })

  test("the main session's background call goes through when its env read throws", async ($, on) => {
    const w = world(on, { envFails: true })
    const call = bash('npm test', { run_in_background: true })
    await $.tool.call(call as never)
    expect(w.calls).toEqual([call])
  })

  test("a generic sub-agent's background call goes through when the agent list cannot be read", async ($, on) => {
    const w = world(on, { agents: new Error('list unreadable') })
    await $.agent.spawn(spawnInput('general-purpose', BRIEF))
    const call = bash('npm test', { run_in_background: true, agentId: 'agent-1' })
    await $.tool.call(call as never)
    expect(w.calls).toEqual([call])
  })
})

describe('foreground — every other Bash call goes through as the model wrote it', () => {
  for (const [mode, type, prompt, extra] of MODES) {
    test(`${mode}'s foreground Bash call reaches the engine unchanged`, async ($, on) => {
      const w = world(on, { agents: [{ id: 'agent-1', type: T(mode) }] })
      await $.agent.spawn(spawnInput(type, prompt, extra))
      const call = bash('npm test', { agentId: 'agent-1' })
      await $.tool.call(call as never)
      expect(w.calls).toEqual([call])
    })
  }

  test("a dev-team agent's call with run_in_background false reaches the engine unchanged", async ($, on) => {
    const w = world(on, { agents: [{ id: 'agent-1', type: T('watson-direct') }] })
    await $.agent.spawn(spawnInput(T('watson'), BRIEF))
    const call = bash('npm test', { run_in_background: false, agentId: 'agent-1', timeout: 600000 })
    await $.tool.call(call as never)
    expect(w.calls).toEqual([call])
  })

  test("the main session's background Bash call reaches the engine unchanged", async ($, on) => {
    const w = world(on)
    const call = bash('npm test', { run_in_background: true })
    await $.tool.call(call as never)
    expect(w.calls).toEqual([call])
  })

  test("a generic sub-agent's background Bash call reaches the engine unchanged", async ($, on) => {
    const w = world(on)
    await $.agent.spawn(spawnInput('general-purpose', BRIEF))
    const call = bash('npm test', { run_in_background: true, agentId: 'agent-1' })
    await $.tool.call(call as never)
    expect(w.calls).toEqual([call])
  })

  test("the top-level loop of a --agent run outside the dev-team keeps its background call", async ($, on) => {
    const w = world(on, { lane: () => 'top-level-agent', env: { CLAUDE_CODE_AGENT: 'other-plugin:builder' } })
    const call = bash('npm test', { run_in_background: true })
    await $.tool.call(call as never)
    expect(w.calls).toEqual([call])
  })
})

describe('foreground — the pure rule', () => {
  test('isBackgroundAsked reads true and any other set value, 0, "" and "FALSE" included, as background, and only false, "false" and absent as foreground', () => {
    expect([true, 'true', 1, null, 0, '', 'FALSE'].map(isBackgroundAsked)).toEqual([true, true, true, true, true, true, true])
    expect([undefined, false, 'false'].map(isBackgroundAsked)).toEqual([false, false, false])
  })

  test("probeLinesOf probes every lone &, inside ${...} and quotes too, and leaves the reading to core's reader", () => {
    expect(probeLinesOf('echo ${x//&/and}')).toEqual([{ separator: 'echo ${x//;/and}', statement: 'echo ${x//;:;/and}' }])
    expect(probeLinesOf('out=${v/a/&}')).toEqual([{ separator: 'out=${v/a/;}', statement: 'out=${v/a/;:;}' }])
    expect(probeLinesOf("echo 'a & b'")).toEqual([{ separator: "echo 'a ; b'", statement: "echo 'a ;:; b'" }])
    expect(probeLinesOf('echo ${x//&/and} &')).toEqual([
      { separator: 'echo ${x//;/and} &', statement: 'echo ${x//;:;/and} &' },
      { separator: 'echo ${x//&/and} ;', statement: 'echo ${x//&/and} ;:;' },
    ])
    expect(probeLinesOf('a && b 2>&1 &> f |& c >& d &>> e')).toEqual([])
  })
})
