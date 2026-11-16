import { describe, expect, test } from 'claude-code/testing'

import { isDeletable, mktempDeny, prefixOf, rootOf, scratchContextOf, sweepOf } from '../hooks/mods/scratch'
import type { GuardOptions } from './world'
import { BRIEF, complete, endSession, spawnInput, world } from './world'

const T = (name: string) => `workbench-dev-team:${name}`
const ROOTS = ['/scratch/session', '/Users/tester/Developer/scratchpad', '/Users/tester/.claude/plans']
const FOLDER = '/scratch/session/watson-direct.abc123'
const TEMPLATE = `'${FOLDER}/tmp.XXXXXXXX'`

const bash = (command: string, agentId?: string) =>
  ({ tool: 'Bash', tool_use_id: 'toolu_1', description: 'd', command, ...(agentId === undefined ? {} : { agentId }) }) as never

const subagentStart = (agentType: string, agentId = 'agent-1') =>
  ({ session_id: 's-1', transcript_path: '/t', cwd: '/repo', hook_event_name: 'SubagentStart', agent_id: agentId, agent_type: agentType }) as never

const beneath = (on: Parameters<typeof world>[0]) => on('classic.SubagentStart', () => ({ additionalContext: ['BENEATH'] }) as never)

const submit = { text: 'Item ID: 5', wait: false, origin: { kind: 'composer' } } as never

// A world with a Watson started from the main session, as agent-1.
async function withWatson($: { agent: { spawn: (e: never) => Promise<unknown> } }, on: Parameters<typeof world>[0], options: GuardOptions = {}) {
  const w = world(on, { roots: ROOTS, agents: [{ id: 'agent-1', type: T('watson-direct') }], ...options })
  await $.agent.spawn(spawnInput(T('watson'), BRIEF))
  return w
}

describe('scratch — no Bash call reaches the engine changed', () => {
  for (const line of [`mktemp -d ${TEMPLATE}`, `mktemp ${TEMPLATE}`, 'git status', 'mktemp -d /scratch/session/x.XXXXXX && ls']) {
    test(`a dev-team agent's ${JSON.stringify(line)} reaches the engine as the model wrote it`, async ($, on) => {
      const w = await withWatson($, on)
      const call = { tool: 'Bash', tool_use_id: 'toolu_1', description: 'd', command: line, agentId: 'agent-1' }
      await $.tool.call(call as never)
      expect(w.calls).toEqual([call])
    })
  }
})

describe('scratch — a bare mktemp is refused, and the refusal names the folder', () => {
  for (const line of ['mktemp -d', 'mktemp', 'mktemp -dq', 'mktemp -d && ls', 'mktemp -d -t probe', 'mktemp -tprobe', 'TMPDIR=/x mktemp -d', 'mktemp --directory', 'mktemp --tmpdir', 'mktemp -d --tmpdir', 'mktemp --tmpdir=', "mktemp -p ''", 'mktemp -d --', 'mktemp -d && echo "then mktemp -d; done"']) {
    test(`${JSON.stringify(line)} is refused with the folder and the template form`, async ($, on) => {
      const w = await withWatson($, on)
      const answer = (await $.tool.call(bash(line, 'agent-1'))) as { deny?: string }
      expect(answer.deny).toBe(mktempDeny(FOLDER))
      expect(answer.deny).toContain(`mktemp -d ${TEMPLATE}`)
      expect(answer.deny).toContain(`mktemp ${TEMPLATE}`)
      expect(w.ran).toEqual([])
      expect(w.runs.filter(argv => argv[0] === 'mktemp')).toEqual([['mktemp', '-d', '/scratch/session/watson-direct.XXXXXX']])
    })
  }

  test('a templated mktemp into the folder passes, and the folder is made only once', async ($, on) => {
    const w = await withWatson($, on)
    await $.tool.call(bash('mktemp -d', 'agent-1'))
    await $.tool.call(bash(`mktemp -d ${TEMPLATE}`, 'agent-1'))
    await $.tool.call(bash(`mktemp ${TEMPLATE}`, 'agent-1'))
    expect(w.ran).toEqual([`Bash: mktemp -d ${TEMPLATE}`, `Bash: mktemp ${TEMPLATE}`])
    expect(w.runs.filter(argv => argv[0] === 'mktemp').length).toBe(1)
  })

  test('holmes-lens is refused with a folder of its own, named for it', async ($, on) => {
    world(on, { roots: ROOTS })
    await $.agent.spawn(spawnInput(T('holmes-lens'), 'lens prompt', { parentAgentId: 'agent-x' }))
    const answer = (await $.tool.call(bash('mktemp -d', 'agent-1'))) as { deny?: string }
    expect(answer.deny).toBe(mktempDeny('/scratch/session/holmes-lens.abc123'))
  })

  test('the top-level loop of a dev-team --agent run is refused too', async ($, on) => {
    world(on, { roots: ROOTS, lane: () => 'top-level-agent', env: { CLAUDE_CODE_AGENT: T('watson-index') } })
    const answer = (await $.tool.call(bash('mktemp -d'))) as { deny?: string }
    expect(answer.deny).toBe(mktempDeny('/scratch/session/watson-index.abc123'))
  })

  test('with no session scratchpad the folder goes in ~/Developer/scratchpad, never in ~/.claude/plans', async ($, on) => {
    await withWatson($, on, { roots: ROOTS.slice(1) })
    const answer = (await $.tool.call(bash('mktemp -d', 'agent-1'))) as { deny?: string }
    expect(answer.deny).toBe(mktempDeny('/Users/tester/Developer/scratchpad/watson-direct.abc123'))
  })

  for (const line of ['mktemp -d /scratch/session/x.XXXXXX', 'mktemp -p /tmp', 'echo "run mktemp -d; then cd"', 'git status']) {
    test(`${JSON.stringify(line)} runs as written`, async ($, on) => {
      const w = await withWatson($, on)
      await $.tool.call(bash(line, 'agent-1'))
      expect(w.ran).toEqual([`Bash: ${line}`])
    })
  }

  test("the main session's mktemp runs as written, and no folder is made", async ($, on) => {
    const w = world(on, { roots: ROOTS })
    await $.tool.call(bash('mktemp -d'))
    expect(w.ran).toEqual(['Bash: mktemp -d'])
    expect(w.runs).toEqual([])
  })

  test("a generic sub-agent's mktemp runs as written, and no folder is made", async ($, on) => {
    const w = world(on, { roots: ROOTS })
    await $.agent.spawn(spawnInput('general-purpose', BRIEF))
    await $.tool.call(bash('mktemp -d', 'agent-1'))
    expect(w.ran).toEqual(['Bash: mktemp -d'])
    expect(w.runs).toEqual([])
  })

  for (const [label, options] of [
    ['with no scratch root', { roots: [] }],
    ['when mktemp fails to make the folder', { run: (argv: readonly string[]) => (argv[0] === 'mktemp' ? { exitCode: 1, stdout: '', stderr: 'mktemp: failed' } : undefined) }],
    ['when mktemp cannot run', { run: (argv: readonly string[]) => (argv[0] === 'mktemp' ? new Error('spawn failed') : undefined) }],
    ['when mktemp prints a folder outside the roots', { run: (argv: readonly string[]) => (argv[0] === 'mktemp' ? { exitCode: 0, stdout: '/elsewhere/x\n', stderr: '' } : undefined) }],
  ] as const) {
    test(`${label}, a bare mktemp is still refused, and the refusal names the scratch roots`, async ($, on) => {
      const w = await withWatson($, on, options as GuardOptions)
      const answer = (await $.tool.call(bash('mktemp -d', 'agent-1'))) as { deny?: string }
      expect(answer.deny).toBe(mktempDeny(undefined))
      expect(answer.deny).toContain('~/Developer/scratchpad')
      expect(w.ran).toEqual([])
    })
  }

  test('a line the shell reader cannot read is refused, never run unjudged', async ($, on) => {
    const w = await withWatson($, on, { parseFails: true })
    const answer = (await $.tool.call(bash('mktemp -d', 'agent-1'))) as { deny?: string }
    expect(answer.deny).toBeDefined()
    expect(w.ran).toEqual([])
  })

  test('the review guard refuses before the mktemp rule does', async ($, on) => {
    const w = world(on, { roots: ROOTS, cwd: '/repo', agents: [{ id: 'agent-1', type: T('holmes-local') }] })
    await $.agent.spawn(spawnInput(T('holmes'), BRIEF))
    const answer = (await $.tool.call(bash('mktemp -d && chmod 644 /repo/README.md', 'agent-1'))) as { deny?: string }
    expect(answer.deny).toContain('A Holmes reviewer')
    expect(w.ran).toEqual([])
  })
})

describe('scratch — each dev-team agent gets its folder at its start', () => {
  for (const type of ['watson-direct', 'holmes-local', 'holmes-lens', 'lestrade-item']) {
    test(`a ${type} start makes the folder and names it in the context`, async ($, on) => {
      const w = world(on, { roots: ROOTS })
      beneath(on)
      const folder = `/scratch/session/${type}.abc123`
      const result = (await $.classic.SubagentStart(subagentStart(T(type)))) as { additionalContext?: string[] }
      expect(result.additionalContext).toContain(scratchContextOf(folder))
      expect(scratchContextOf(folder)).toContain(`mktemp -d '${folder}/tmp.XXXXXXXX'`)
      expect(w.made.has(folder)).toBe(true)
    })
  }

  test('the folder named at the start is the one the refusal names, made once', async ($, on) => {
    const w = world(on, { roots: ROOTS, agents: [{ id: 'agent-1', type: T('watson-direct') }] })
    beneath(on)
    await $.agent.spawn(spawnInput(T('watson'), BRIEF))
    const result = (await $.classic.SubagentStart(subagentStart(T('watson-direct')))) as { additionalContext?: string[] }
    expect(result.additionalContext).toContain(scratchContextOf(FOLDER))
    const answer = (await $.tool.call(bash('mktemp -d', 'agent-1'))) as { deny?: string }
    expect(answer.deny).toBe(mktempDeny(FOLDER))
    await $.tool.call(bash(`mktemp -d ${TEMPLATE}`, 'agent-1'))
    expect(w.ran).toEqual([`Bash: mktemp -d ${TEMPLATE}`])
    expect(w.runs.filter(argv => argv[0] === 'mktemp').length).toBe(1)
  })

  test('a generic sub-agent gets no folder and no scratch context', async ($, on) => {
    const w = world(on, { roots: ROOTS })
    beneath(on)
    const result = (await $.classic.SubagentStart(subagentStart('general-purpose'))) as { additionalContext?: string[] }
    expect((result.additionalContext ?? []).some(line => line.includes('scratch folder for this run'))).toBe(false)
    expect(w.runs).toEqual([])
  })

  test('with no scratch root the start adds no scratch context', async ($, on) => {
    world(on, { roots: [] })
    beneath(on)
    const result = (await $.classic.SubagentStart(subagentStart(T('watson-direct')))) as { additionalContext?: string[] }
    expect((result.additionalContext ?? []).some(line => line.includes('scratch folder for this run'))).toBe(false)
  })

  test('the folder made at the start is removed when the run ends', async ($, on) => {
    const w = world(on, { roots: ROOTS, agents: [{ id: 'agent-1', type: T('watson-direct') }] })
    beneath(on)
    await $.agent.spawn(spawnInput(T('watson'), BRIEF))
    await $.classic.SubagentStart(subagentStart(T('watson-direct')))
    await complete($ as never, 'agent-1')
    expect(w.runs.filter(argv => argv[0] === 'rm')).toEqual([['rm', '-rf', '--', FOLDER]])
    expect(w.made.has(FOLDER)).toBe(false)
  })

  test('a top-level dev-team run gets its folder as context on its prompt', async ($, on) => {
    const w = world(on, { roots: ROOTS, lane: () => 'top-level-agent', env: { CLAUDE_CODE_AGENT: T('watson-index') } })
    const seen: { context?: string[] }[] = []
    on('prompt.submit', async ($, e) => {
      seen.push(e as never)
      return { text: '' } as never
    })
    await $.prompt.submit(submit)
    expect(seen[0]?.context).toEqual([scratchContextOf('/scratch/session/watson-index.abc123')])
    expect(w.made.has('/scratch/session/watson-index.abc123')).toBe(true)
  })

  test('the main session gets no scratch context on its prompt, and no folder', async ($, on) => {
    const w = world(on, { roots: ROOTS })
    const seen: { context?: string[] }[] = []
    on('prompt.submit', async ($, e) => {
      seen.push(e as never)
      return { text: '' } as never
    })
    await $.prompt.submit(submit)
    expect(seen[0]?.context).toBeUndefined()
    expect(w.runs).toEqual([])
  })

  test('a resumed run finds its folder again at the same path, and its end removes it again', async ($, on) => {
    const w = world(on, { roots: ROOTS, agents: [{ id: 'agent-1', type: T('watson-direct') }] })
    beneath(on)
    await $.agent.spawn(spawnInput(T('watson'), BRIEF))
    await $.classic.SubagentStart(subagentStart(T('watson-direct')))
    await complete($ as never, 'agent-1')
    expect(w.made.has(FOLDER)).toBe(false)
    await $.tool.call(bash(`mktemp -d ${TEMPLATE}`, 'agent-1'))
    expect(w.runs.filter(argv => argv[0] === 'mkdir')).toEqual([['mkdir', '-m', '700', '--', FOLDER]])
    expect(w.ran).toEqual([`Bash: mktemp -d ${TEMPLATE}`])
    await complete($ as never, 'agent-1')
    expect(w.runs.filter(argv => argv[0] === 'rm')).toEqual([['rm', '-rf', '--', FOLDER], ['rm', '-rf', '--', FOLDER]])
    expect(w.runs.filter(argv => argv[0] === 'mktemp').length).toBe(1)
  })

  test('a resumed run whose mkdir fails gets a new folder, and every later refusal names that one', async ($, on) => {
    const NEW = '/scratch/session/watson-direct.def456'
    let made = 0
    const w = world(on, {
      roots: ROOTS,
      agents: [{ id: 'agent-1', type: T('watson-direct') }],
      run: argv => {
        if (argv[0] === 'mkdir') return { exitCode: 1, stdout: '', stderr: 'mkdir: Permission denied' }
        if (argv[0] !== 'mktemp') return undefined
        const folder = made++ === 0 ? FOLDER : NEW
        w.made.add(folder)
        return { exitCode: 0, stdout: `${folder}\n`, stderr: '' }
      },
    })
    beneath(on)
    await $.agent.spawn(spawnInput(T('watson'), BRIEF))
    await $.classic.SubagentStart(subagentStart(T('watson-direct')))
    await complete($ as never, 'agent-1')
    const first = (await $.tool.call(bash('mktemp -d', 'agent-1'))) as { deny?: string }
    const second = (await $.tool.call(bash('mktemp -d', 'agent-1'))) as { deny?: string }
    expect(w.runs.filter(argv => argv[0] === 'mkdir')).toEqual([['mkdir', '-m', '700', '--', FOLDER]])
    expect(first.deny).toBe(mktempDeny(NEW))
    expect(second.deny).toBe(mktempDeny(NEW))
    expect(w.runs.filter(argv => argv[0] === 'mktemp').length).toBe(2)
  })

  test('a kept folder no longer under a scratch root is never made again with mkdir', async ($, on) => {
    const roots = [...ROOTS]
    const w = world(on, { roots, agents: [{ id: 'agent-1', type: T('watson-direct') }] })
    beneath(on)
    await $.agent.spawn(spawnInput(T('watson'), BRIEF))
    await $.classic.SubagentStart(subagentStart(T('watson-direct')))
    w.made.delete(FOLDER)
    roots.splice(0, roots.length, '/other')
    const answer = (await $.tool.call(bash('mktemp -d', 'agent-1'))) as { deny?: string }
    expect(w.runs.filter(argv => argv[0] === 'mkdir')).toEqual([])
    expect(answer.deny).toBe(mktempDeny('/other/watson-direct.abc123'))
  })

  test('a folder another call made between the check and the mkdir is shared, not replaced', async ($, on) => {
    const w = world(on, {
      roots: ROOTS,
      agents: [{ id: 'agent-1', type: T('watson-direct') }],
      run: argv => {
        if (argv[0] !== 'mkdir') return undefined
        w.made.add(FOLDER)
        return { exitCode: 1, stdout: '', stderr: 'mkdir: File exists' }
      },
    })
    beneath(on)
    await $.agent.spawn(spawnInput(T('watson'), BRIEF))
    await $.classic.SubagentStart(subagentStart(T('watson-direct')))
    await complete($ as never, 'agent-1')
    const answer = (await $.tool.call(bash('mktemp -d', 'agent-1'))) as { deny?: string }
    expect(answer.deny).toBe(mktempDeny(FOLDER))
    expect(w.runs.filter(argv => argv[0] === 'mkdir').length).toBe(1)
    expect(w.runs.filter(argv => argv[0] === 'mktemp').length).toBe(1)
  })

  test('two parallel calls after a resume share one folder', async ($, on) => {
    const w = world(on, {
      roots: ROOTS,
      agents: [{ id: 'agent-1', type: T('watson-direct') }],
      run: argv => {
        if (argv[0] !== 'mkdir') return undefined
        const isTaken = w.made.has(FOLDER)
        w.made.add(FOLDER)
        return isTaken ? { exitCode: 1, stdout: '', stderr: 'mkdir: File exists' } : { exitCode: 0, stdout: '', stderr: '' }
      },
    })
    beneath(on)
    await $.agent.spawn(spawnInput(T('watson'), BRIEF))
    await $.classic.SubagentStart(subagentStart(T('watson-direct')))
    await complete($ as never, 'agent-1')
    const answers = (await Promise.all([$.tool.call(bash('mktemp -d', 'agent-1')), $.tool.call(bash('mktemp', 'agent-1'))])) as { deny?: string }[]
    expect(answers.map(answer => answer.deny)).toEqual([mktempDeny(FOLDER), mktempDeny(FOLDER)])
    expect(w.runs.filter(argv => argv[0] === 'mktemp').length).toBe(1)
  })

  test('a turn that ends after the folder was already removed runs no second rm', async ($, on) => {
    const w = world(on, { roots: ROOTS, agents: [{ id: 'agent-1', type: T('watson-direct') }] })
    beneath(on)
    await $.agent.spawn(spawnInput(T('watson'), BRIEF))
    await $.classic.SubagentStart(subagentStart(T('watson-direct')))
    await complete($ as never, 'agent-1')
    await complete($ as never, 'agent-1')
    expect(w.runs.filter(argv => argv[0] === 'rm').length).toBe(1)
  })
})

describe('scratch — the folder is deleted when the run completes', () => {
  test("the agent's folder is removed at its run's end, and the next run makes it again at the same path", async ($, on) => {
    const w = await withWatson($, on)
    await $.tool.call(bash('mktemp -d', 'agent-1'))
    await complete($ as never, 'agent-1')
    expect(w.runs.filter(argv => argv[0] === 'rm')).toEqual([['rm', '-rf', '--', FOLDER]])
    expect(w.made.has(FOLDER)).toBe(false)
    const answer = (await $.tool.call(bash('mktemp -d', 'agent-1'))) as { deny?: string }
    expect(answer.deny).toBe(mktempDeny(FOLDER))
    expect(w.made.has(FOLDER)).toBe(true)
    expect(w.runs.filter(argv => argv[0] === 'mktemp').length).toBe(1)
  })

  test("another loop's end removes nothing", async ($, on) => {
    const w = await withWatson($, on)
    await $.tool.call(bash('mktemp -d', 'agent-1'))
    await complete($ as never, 'agent-2')
    await complete($ as never)
    expect(w.runs.filter(argv => argv[0] === 'rm')).toEqual([])
    expect(w.made.has(FOLDER)).toBe(true)
  })

  test('a run that made no folder removes nothing', async ($, on) => {
    const w = await withWatson($, on)
    await complete($ as never, 'agent-1')
    expect(w.runs.filter(argv => argv[0] === 'rm')).toEqual([])
  })

  test("the top-level run's folder goes when its turn completes", async ($, on) => {
    const w = world(on, { roots: ROOTS, lane: () => 'top-level-agent', env: { CLAUDE_CODE_AGENT: T('holmes-index') } })
    await $.tool.call(bash('mktemp -d'))
    await complete($ as never)
    expect(w.runs.filter(argv => argv[0] === 'rm')).toEqual([['rm', '-rf', '--', '/scratch/session/holmes-index.abc123']])
  })

  test('a folder that is no longer inside a root is not deleted', async ($, on) => {
    // world() answers scratchRoots with this very array, so emptying it later
    // changes what the run's end reads.
    const roots = [...ROOTS]
    const w = world(on, { roots })
    await $.agent.spawn(spawnInput(T('watson'), BRIEF))
    await $.tool.call(bash('mktemp -d', 'agent-1'))
    expect(w.made.has(FOLDER)).toBe(true)
    roots.splice(0, roots.length, '/other')
    await complete($ as never, 'agent-1')
    expect(w.runs.filter(argv => argv[0] === 'rm')).toEqual([])
  })
})

describe('scratch — no folder is deleted while a child of its run is live', () => {
  const rms = (w: { runs: string[][] }) => w.runs.filter(argv => argv[0] === 'rm')
  type Listed = { id: string; type: string; parentId?: string; status?: string }

  for (const status of ['pending', 'running', 'waiting', 'idle']) {
    test(`a turn that ends with a ${status} child keeps the folder`, async ($, on) => {
      const agents: Listed[] = [
        { id: 'agent-1', type: T('watson-direct') },
        { id: 'lens-1', type: 'Explore', parentId: 'agent-1', status },
      ]
      const w = world(on, { roots: ROOTS, agents })
      await $.agent.spawn(spawnInput(T('watson'), BRIEF))
      await $.tool.call(bash('mktemp -d', 'agent-1'))
      await complete($ as never, 'agent-1')
      expect(rms(w)).toEqual([])
      expect(w.made.has(FOLDER)).toBe(true)
    })
  }

  test("a second turn reuses the folder its first turn kept, and the child's own end deletes nothing of the parent's", async ($, on) => {
    const agents: Listed[] = [
      { id: 'agent-1', type: T('watson-direct') },
      { id: 'agent-2', type: 'Explore', parentId: 'agent-1', status: 'running' },
    ]
    const w = world(on, { roots: ROOTS, agents })
    await $.agent.spawn(spawnInput(T('watson'), BRIEF)) // agent-1, watson-direct
    await $.tool.call(bash('mktemp -d', 'agent-1'))
    await complete($ as never, 'agent-1') // the first turn ends while the helper runs
    const kept = FOLDER
    agents[1] = { ...agents[1]!, status: 'completed' }
    await complete($ as never, 'agent-2') // the helper's own end
    expect(rms(w)).toEqual([])
    await $.tool.call(bash(`mktemp -d '${kept}/tmp.XXXXXXXX'`, 'agent-1')) // the second turn
    expect(w.ran.at(-1)).toBe(`Bash: mktemp -d '${kept}/tmp.XXXXXXXX'`)
    expect(w.runs.filter(argv => argv[0] === 'mktemp').length).toBe(1)
    await complete($ as never, 'agent-1') // the second turn ends with no live child
    expect(rms(w)).toEqual([['rm', '-rf', '--', kept]])
  })

  test("another agent's child does not hold the folder", async ($, on) => {
    const agents: Listed[] = [
      { id: 'agent-1', type: T('watson-direct') },
      { id: 'other', type: 'Explore', parentId: 'agent-9', status: 'running' },
    ]
    const w = await withWatson($, on, { agents })
    await $.tool.call(bash('mktemp -d', 'agent-1'))
    await complete($ as never, 'agent-1')
    expect(rms(w)).toEqual([['rm', '-rf', '--', FOLDER]])
  })

  test('a top-level run keeps its folder while a sub-agent it spawned is live', async ($, on) => {
    const agents: Listed[] = [{ id: 'lens-1', type: T('holmes-lens'), status: 'running' }]
    const w = world(on, { roots: ROOTS, agents, lane: () => 'top-level-agent', env: { CLAUDE_CODE_AGENT: T('holmes-index') } })
    await $.tool.call(bash('mktemp -d'))
    await complete($ as never)
    expect(rms(w)).toEqual([])
    agents[0] = { ...agents[0]!, status: 'completed' }
    await complete($ as never)
    expect(rms(w)).toEqual([['rm', '-rf', '--', '/scratch/session/holmes-index.abc123']])
  })

  test('an agent list that cannot be read keeps the folder', async ($, on) => {
    const w = world(on, { roots: ROOTS, agents: new Error('list failed'), lane: () => 'top-level-agent', env: { CLAUDE_CODE_AGENT: T('watson-index') } })
    await $.tool.call(bash('mktemp -d'))
    await complete($ as never)
    expect(rms(w)).toEqual([])
  })
})

describe('scratch — the session end deletes every folder still recorded', () => {
  const rms = (w: { runs: string[][] }) => w.runs.filter(argv => argv[0] === 'rm')
  type Listed = { id: string; type: string; parentId?: string; status?: string }

  test('a folder kept for a live child, whose run never resumed, goes at the session end', async ($, on) => {
    const agents: Listed[] = [
      { id: 'agent-1', type: T('watson-direct') },
      { id: 'lens-1', type: 'Explore', parentId: 'agent-1', status: 'running' },
    ]
    const w = world(on, { roots: ROOTS, agents })
    await $.agent.spawn(spawnInput(T('watson'), BRIEF))
    await $.tool.call(bash('mktemp -d', 'agent-1'))
    await complete($ as never, 'agent-1')
    expect(rms(w)).toEqual([])
    await endSession($ as never)
    expect(rms(w)).toEqual([['rm', '-rf', '--', FOLDER]])
    expect(w.made.has(FOLDER)).toBe(false)
  })

  test("only the folders still recorded go, in one rm: a run's end already took its own", async ($, on) => {
    const agents: Listed[] = [
      { id: 'agent-1', type: T('watson-direct') },
      { id: 'agent-2', type: T('holmes-local') },
      { id: 'lens-1', type: T('holmes-lens'), parentId: 'agent-2', status: 'running' },
      { id: 'agent-3', type: T('lestrade-item') },
    ]
    let made = 0
    const w = world(on, {
      roots: ROOTS,
      agents,
      run: argv => {
        if (argv[0] !== 'mktemp') return undefined
        w.made.add(`/scratch/session/run.${++made}`)
        return { exitCode: 0, stdout: `/scratch/session/run.${made}\n`, stderr: '' }
      },
    })
    await $.agent.spawn(spawnInput(T('watson'), BRIEF)) // agent-1
    await $.agent.spawn(spawnInput(T('holmes'), BRIEF)) // agent-2
    await $.agent.spawn(spawnInput(T('lestrade'), 'Item ID: 9')) // agent-3
    await $.tool.call(bash('mktemp -d', 'agent-1'))
    await $.tool.call(bash('mktemp -d', 'agent-2'))
    await $.tool.call(bash('mktemp -d', 'agent-3'))
    await complete($ as never, 'agent-1') // no live child: its folder goes now
    await complete($ as never, 'agent-2') // a live helper: kept
    await complete($ as never, 'agent-3') // kept too: its turn has not ended (no complete)
    expect(rms(w)).toEqual([['rm', '-rf', '--', '/scratch/session/run.1'], ['rm', '-rf', '--', '/scratch/session/run.3']])
    await endSession($ as never)
    expect(rms(w).at(-1)).toEqual(['rm', '-rf', '--', '/scratch/session/run.2'])
    expect(rms(w).length).toBe(3)
  })

  test('a folder whose run never ended goes too', async ($, on) => {
    const w = await withWatson($, on)
    await $.tool.call(bash('mktemp -d', 'agent-1'))
    await endSession($ as never)
    expect(rms(w)).toEqual([['rm', '-rf', '--', FOLDER]])
  })

  test("the top-level run's folder, kept for a live sub-agent, goes at the end of a -p run", async ($, on) => {
    const agents: Listed[] = [{ id: 'lens-1', type: T('holmes-lens'), status: 'running' }]
    const w = world(on, { roots: ROOTS, agents, lane: () => 'top-level-agent', env: { CLAUDE_CODE_AGENT: T('holmes-index') } })
    await $.tool.call(bash('mktemp -d'))
    await complete($ as never)
    expect(rms(w)).toEqual([])
    await endSession($ as never)
    expect(rms(w)).toEqual([['rm', '-rf', '--', '/scratch/session/holmes-index.abc123']])
  })

  test('a recorded folder no longer under a scratch root is never deleted', async ($, on) => {
    const roots = [...ROOTS]
    const w = world(on, { roots, agents: [{ id: 'agent-1', type: T('watson-direct') }, { id: 'c', type: 'Explore', parentId: 'agent-1' }] })
    await $.agent.spawn(spawnInput(T('watson'), BRIEF))
    await $.tool.call(bash('mktemp -d', 'agent-1'))
    await complete($ as never, 'agent-1')
    roots.splice(0, roots.length, '/other')
    await endSession($ as never)
    expect(rms(w)).toEqual([])
    // It stays recorded: back under a root, the next end deletes it.
    roots.splice(0, roots.length, ...ROOTS)
    await endSession($ as never)
    expect(rms(w)).toEqual([['rm', '-rf', '--', FOLDER]])
  })

  test('an rm that fails keeps every folder it was given, so the next end tries again', async ($, on) => {
    let fail = true
    const w = await withWatson($, on, { run: argv => (argv[0] === 'rm' && fail ? { exitCode: 1, stdout: '', stderr: 'busy' } : undefined) })
    await $.tool.call(bash('mktemp -d', 'agent-1'))
    await endSession($ as never)
    fail = false
    await endSession($ as never)
    await endSession($ as never)
    expect(rms(w)).toEqual([['rm', '-rf', '--', FOLDER], ['rm', '-rf', '--', FOLDER]])
  })

  test('an rm that cannot run keeps the folders too', async ($, on) => {
    let fail = true
    const w = await withWatson($, on, { run: argv => (argv[0] === 'rm' && fail ? new Error('timed out') : undefined) })
    await $.tool.call(bash('mktemp -d', 'agent-1'))
    await endSession($ as never)
    fail = false
    await endSession($ as never)
    expect(rms(w).length).toBe(2)
    expect(w.made.has(FOLDER)).toBe(false)
  })

  test('a folder outside the roots stays recorded while the rest go', async ($, on) => {
    let made = 0
    const roots = [...ROOTS]
    const w = world(on, {
      roots,
      agents: [{ id: 'agent-1', type: T('watson-direct') }, { id: 'agent-2', type: T('watson-direct') }],
      run: argv => (argv[0] === 'mktemp' ? { exitCode: 0, stdout: `${made++ === 0 ? '/scratch/session' : '/Users/tester/Developer/scratchpad'}/run.${made}\n`, stderr: '' } : undefined),
    })
    await $.agent.spawn(spawnInput(T('watson'), BRIEF))
    await $.agent.spawn(spawnInput(T('watson'), BRIEF))
    await $.tool.call(bash('mktemp -d', 'agent-1'))
    await $.tool.call(bash('mktemp -d', 'agent-2'))
    roots.splice(0, roots.length, '/scratch/session')
    await endSession($ as never)
    expect(rms(w)).toEqual([['rm', '-rf', '--', '/scratch/session/run.1']])
    roots.splice(0, roots.length, ...ROOTS)
    await endSession($ as never)
    expect(rms(w).at(-1)).toEqual(['rm', '-rf', '--', '/Users/tester/Developer/scratchpad/run.2'])
    expect(rms(w).length).toBe(2)
  })

  test('the record is emptied, so a second end deletes nothing', async ($, on) => {
    const w = await withWatson($, on)
    await $.tool.call(bash('mktemp -d', 'agent-1'))
    await endSession($ as never)
    await endSession($ as never)
    expect(rms(w).length).toBe(1)
  })

  test('no recorded folder, no rm', async ($, on) => {
    const w = await withWatson($, on)
    await endSession($ as never)
    expect(rms(w)).toEqual([])
  })

  test('the rm is held to the end\'s short budget', async ($, on) => {
    const w = await withWatson($, on)
    await $.tool.call(bash('mktemp -d', 'agent-1'))
    await endSession($ as never)
    const timeout = w.timeouts[w.runs.findIndex(argv => argv[0] === 'rm')]
    expect(timeout).toBeGreaterThan(0)
    expect(timeout).toBeLessThanOrEqual(1_000)
  })

  test('scratch roots that cannot be read leave the folders, and the session still ends', async ($, on) => {
    const w = await withWatson($, on)
    await $.tool.call(bash('mktemp -d', 'agent-1'))
    w.rootsFail = true
    await endSession($ as never)
    expect(rms(w)).toEqual([])
    expect(w.made.has(FOLDER)).toBe(true)
  })
})

describe('scratch — the pure rules', () => {
  test('rootOf skips ~/.claude/plans, and isDeletable refuses a root and anything outside', () => {
    expect(rootOf(['/Users/t/.claude/plans', '/Users/t/Developer/scratchpad'])).toBe('/Users/t/Developer/scratchpad')
    expect(rootOf([])).toBeUndefined()
    expect(isDeletable('/scratch/session/a.1', ROOTS)).toBe(true)
    expect(isDeletable('/scratch/session', ROOTS)).toBe(false)
    expect(isDeletable('/scratch/session/', ROOTS)).toBe(false)
    expect(isDeletable('/scratch/sessionx/a', ROOTS)).toBe(false)
    expect(isDeletable('/scratch/session/../x', ROOTS)).toBe(false)
    expect(isDeletable('', ROOTS)).toBe(false)
  })

  test('sweepOf takes only folders under a root, and nothing when too little time is left', () => {
    const kept = ['/scratch/session/a.1', '/elsewhere/b.2', '/Users/tester/Developer/scratchpad/c.3']
    expect(sweepOf(kept, ROOTS, 1_500)).toEqual({ doomed: ['/scratch/session/a.1', '/Users/tester/Developer/scratchpad/c.3'], timeoutMs: 850 })
    expect(sweepOf(kept, ROOTS, Infinity)?.timeoutMs).toBe(850)
    expect(sweepOf(kept, ROOTS, 400)?.timeoutMs).toBe(250)
    expect(sweepOf(kept, ROOTS, 150)).toBeUndefined()
    expect(sweepOf(kept, ROOTS, 0)).toBeUndefined()
    expect(sweepOf(['/elsewhere/b.2'], ROOTS, 1_500)).toBeUndefined()
    expect(sweepOf([], ROOTS, 1_500)).toBeUndefined()
  })

  test('prefixOf names the folder for the bare type', () => {
    expect(prefixOf(T('watson-direct'))).toBe('watson-direct')
    expect(prefixOf('x:../..')).toBe('agent')
  })
})
