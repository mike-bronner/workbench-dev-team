// hooks/register.ts with hooks/mods/scratch.ts: a dev-team agent's bare mktemp
// lands in a folder of its own under a scratch root, and the folder is deleted
// when the agent's run completes.

import { describe, expect, test } from 'claude-code/testing'

import { isDeletable, pointMktemp, prefixOf, readsAsPointed, rootOf, sweepOf } from '../hooks/mods/scratch'
import { parseShell } from './core/hooks/mods/shell'
import type { GuardOptions } from './world'
import { BRIEF, complete, endSession, spawnInput, world } from './world'

const T = (name: string) => `workbench-dev-team:${name}`
const ROOTS = ['/scratch/session', '/Users/tester/Developer/scratchpad', '/Users/tester/.claude/plans']
const FOLDER = '/scratch/session/watson-direct.abc123'
const TEMPLATE = `'${FOLDER}/tmp.XXXXXXXX'`

const bash = (command: string, agentId?: string) =>
  ({ tool: 'Bash', tool_use_id: 'toolu_1', description: 'd', command, ...(agentId === undefined ? {} : { agentId }) }) as never

// A world with a Watson started from the main session, as agent-1.
async function withWatson($: { agent: { spawn: (e: never) => Promise<unknown> } }, on: Parameters<typeof world>[0], options: GuardOptions = {}) {
  const w = world(on, { roots: ROOTS, agents: [{ id: 'agent-1', type: T('watson-direct') }], ...options })
  await $.agent.spawn(spawnInput(T('watson'), BRIEF))
  return w
}

describe('scratch — a bare mktemp lands in the agent\'s own folder', () => {
  for (const [line, pointed] of [
    ['mktemp -d', `mktemp -d ${TEMPLATE}`],
    ['mktemp', `mktemp ${TEMPLATE}`],
    ['mktemp -dq', `mktemp -dq ${TEMPLATE}`],
    // A trailing comment, as a copied step carries one.
    ['mktemp -d   # prints <checkout path>', `mktemp -d '${FOLDER}/tmp.XXXXXXXX'   # prints <checkout path>`],
    ['mktemp -d # a\necho b', `mktemp -d '${FOLDER}/tmp.XXXXXXXX' # a\necho b`],
    ['D=$(mktemp -d) && cd "$D"', `D=$(mktemp -d ${TEMPLATE}) && cd "$D"`],
    ['cp -R src "$(mktemp -d)"', `cp -R src "$(mktemp -d ${TEMPLATE})"`],
    ['A=$(mktemp -d); B=$(mktemp)', `A=$(mktemp -d ${TEMPLATE}); B=$(mktemp ${TEMPLATE})`],
  ] as const) {
    test(`${JSON.stringify(line)} is pointed at the folder`, async ($, on) => {
      const w = await withWatson($, on)
      await $.tool.call(bash(line, 'agent-1'))
      expect(w.ran).toEqual([`Bash: ${pointed}`])
      expect(w.runs.filter(argv => argv[0] === 'mktemp')).toEqual([['mktemp', '-d', '/scratch/session/watson-direct.XXXXXX']])
    })
  }

  test('a second mktemp in the same run reuses the folder', async ($, on) => {
    const w = await withWatson($, on)
    await $.tool.call(bash('mktemp -d', 'agent-1'))
    await $.tool.call(bash('mktemp -d', 'agent-1'))
    expect(w.ran).toEqual([`Bash: mktemp -d ${TEMPLATE}`, `Bash: mktemp -d ${TEMPLATE}`])
    expect(w.runs.filter(argv => argv[0] === 'mktemp').length).toBe(1)
  })

  test('holmes-lens gets a folder of its own, named for it', async ($, on) => {
    const w = world(on, { roots: ROOTS })
    await $.agent.spawn(spawnInput(T('holmes-lens'), 'lens prompt', { parentAgentId: 'agent-x' }))
    await $.tool.call(bash('mktemp -d', 'agent-1'))
    expect(w.ran).toEqual([`Bash: mktemp -d '/scratch/session/holmes-lens.abc123/tmp.XXXXXXXX'`])
  })

  test('the top-level loop of a dev-team --agent run is pointed too', async ($, on) => {
    const w = world(on, { roots: ROOTS, lane: () => 'top-level-agent', env: { CLAUDE_CODE_AGENT: T('watson-index') } })
    await $.tool.call(bash('mktemp -d'))
    expect(w.ran).toEqual([`Bash: mktemp -d '/scratch/session/watson-index.abc123/tmp.XXXXXXXX'`])
  })

  test('with no session scratchpad the folder goes in ~/Developer/scratchpad, never in ~/.claude/plans', async ($, on) => {
    const w = await withWatson($, on, { roots: ROOTS.slice(1) })
    await $.tool.call(bash('mktemp -d', 'agent-1'))
    expect(w.ran).toEqual([`Bash: mktemp -d '/Users/tester/Developer/scratchpad/watson-direct.abc123/tmp.XXXXXXXX'`])
  })

  for (const line of [
    'mktemp -d -t probe',
    'mktemp -d /scratch/session/x.XXXXXX',
    'mktemp -p /tmp',
    'echo "run mktemp -d; then cd"',
    // A real bare mktemp beside a quoted one: the text match reaches both, the
    // read-back sees the echo change, and the whole line is left as written.
    'mktemp -d && echo "then mktemp -d; done"',
    "cat <<'EOF'\nmktemp -d\nEOF",
    'env mktemp -d',
    'TMPDIR=/x mktemp -d',
    'if mktemp -d; then :; fi',
    'git status',
  ]) {
    test(`${JSON.stringify(line)} runs as written`, async ($, on) => {
      const w = await withWatson($, on)
      await $.tool.call(bash(line, 'agent-1'))
      expect(w.ran).toEqual([`Bash: ${line}`])
    })
  }

  test("the main session's mktemp runs as written", async ($, on) => {
    const w = world(on, { roots: ROOTS })
    await $.tool.call(bash('mktemp -d'))
    expect(w.ran).toEqual(['Bash: mktemp -d'])
    expect(w.runs).toEqual([])
  })

  test("a generic sub-agent's mktemp runs as written", async ($, on) => {
    const w = world(on, { roots: ROOTS })
    await $.agent.spawn(spawnInput('general-purpose', BRIEF))
    await $.tool.call(bash('mktemp -d', 'agent-1'))
    expect(w.ran).toEqual(['Bash: mktemp -d'])
  })

  test('with no scratch root, the line runs as written', async ($, on) => {
    const w = await withWatson($, on, { roots: [] })
    await $.tool.call(bash('mktemp -d', 'agent-1'))
    expect(w.ran).toEqual(['Bash: mktemp -d'])
  })

  test('a folder mktemp fails to make leaves the line as written', async ($, on) => {
    const w = await withWatson($, on, { run: argv => (argv[0] === 'mktemp' ? { exitCode: 1, stdout: '', stderr: 'mktemp: failed' } : undefined) })
    await $.tool.call(bash('mktemp -d', 'agent-1'))
    expect(w.ran).toEqual(['Bash: mktemp -d'])
  })

  test('a mktemp that cannot run leaves the line as written', async ($, on) => {
    const w = await withWatson($, on, { run: argv => (argv[0] === 'mktemp' ? new Error('spawn failed') : undefined) })
    await $.tool.call(bash('mktemp -d', 'agent-1'))
    expect(w.ran).toEqual(['Bash: mktemp -d'])
  })

  test('a folder mktemp printed outside the roots is not used', async ($, on) => {
    const w = await withWatson($, on, { run: argv => (argv[0] === 'mktemp' ? { exitCode: 0, stdout: '/elsewhere/x\n', stderr: '' } : undefined) })
    await $.tool.call(bash('mktemp -d', 'agent-1'))
    expect(w.ran).toEqual(['Bash: mktemp -d'])
  })

  test('the guards judge the pointed line', async ($, on) => {
    const w = await withWatson($, on)
    await $.tool.call(bash('D=$(mktemp -d) && git -C "$D" push --force', 'agent-1'))
    expect(w.ran).toEqual([])
  })
})

describe('scratch — the folder is deleted when the run completes', () => {
  test("the agent's folder is removed at its run's end, and the next run makes a new one", async ($, on) => {
    const w = await withWatson($, on)
    await $.tool.call(bash('mktemp -d', 'agent-1'))
    await complete($ as never, 'agent-1')
    expect(w.runs.filter(argv => argv[0] === 'rm')).toEqual([['rm', '-rf', '--', FOLDER]])
    expect(w.made.has(FOLDER)).toBe(false)
    await $.tool.call(bash('mktemp -d', 'agent-1'))
    expect(w.runs.filter(argv => argv[0] === 'mktemp').length).toBe(2)
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
    expect(w.ran).toEqual([`Bash: mktemp -d ${TEMPLATE}`])
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
    await $.tool.call(bash('mktemp -d', 'agent-1')) // the second turn
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
      run: argv => (argv[0] === 'mktemp' ? { exitCode: 0, stdout: `/scratch/session/run.${++made}\n`, stderr: '' } : undefined),
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
  test('the rewrite stands only when it reads back as the line plus the template', () => {
    const line = 'echo "a; mktemp -d; b"'
    const pointed = pointMktemp(line, FOLDER)
    expect(pointed).toBeDefined()
    expect(readsAsPointed(parseShell(line), parseShell(pointed ?? ''), FOLDER)).toBe(false)
    const mixed = 'mktemp -d && echo "then mktemp -d; done"'
    expect(readsAsPointed(parseShell(mixed), parseShell(pointMktemp(mixed, FOLDER) ?? ''), FOLDER)).toBe(false)
    const plain = pointMktemp('mktemp -d', FOLDER) ?? ''
    expect(readsAsPointed(parseShell('mktemp -d'), parseShell(plain), FOLDER)).toBe(true)
  })

  test('a folder with a quote or a space is never pointed at', () => {
    expect(pointMktemp('mktemp -d', "/scratch/it's")).toBeUndefined()
    expect(pointMktemp('mktemp -d', '/scratch/a b')).toBeUndefined()
  })

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
