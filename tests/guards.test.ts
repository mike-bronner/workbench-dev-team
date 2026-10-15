import { describe, expect, test } from 'claude-code/testing'

import type { Entry, GuardOptions } from './world'
import { readPlain, world } from './world'

type Call = { tool: string; command?: string; file_path?: string; notebook_path?: string }

async function refusalOf($: { tool: { call: (e: never) => Promise<unknown> } }, call: Call, agentId?: string): Promise<string | undefined> {
  const input = { tool_use_id: 'toolu_1', ...(call.tool === 'Bash' ? { description: 'd' } : {}), ...call, ...(agentId === undefined ? {} : { agentId }) }
  const result = (await $.tool.call(input as never)) as { deny?: string; isError?: boolean; text?: string }
  return result.deny ?? (result.isError ? result.text : undefined)
}

const bash = (command: string): Call => ({ tool: 'Bash', command })

type Lane = 'main' | 'sub-agent' | 'pipeline'

const LANES: Readonly<Record<Lane, { agentId?: string; options: GuardOptions & { lane?: (id: string | undefined) => 'main' | 'sub-agent' | 'top-level-agent' } }>> = {
  main: { options: { lane: () => 'main', unattended: false } },
  'sub-agent': { agentId: 'agent-1', options: { lane: () => 'sub-agent', unattended: false, agents: [{ id: 'agent-1', type: 'workbench-dev-team:watson-direct' }] } },
  pipeline: { options: { lane: () => 'top-level-agent', unattended: true } },
}

describe('the stand-in reader takes plain lines only', () => {
  test('a plain line reads as its statements', () => {
    const parse = readPlain('A=1 git -C /repo push origin x && echo "a b" > out')
    expect(parse.statements.map(s => [s.name, s.subcommandAt, s.assignments, s.isCertain])).toEqual([
      ['git', 2, ['A=1'], true],
      ['echo', -1, [], false],
    ])
    expect(parse.statements[1]?.redirects).toEqual([{ op: '>', fd: '', target: 'out', isReal: true }])
  })
  test('anything it does not model is refused, never misread', () => {
    for (const line of ['echo $(git push)', 'cat <<EOF', 'env git push', 'bash -c "git push"', 'sleep 1 &', 'echo "open']) {
      expect(() => readPlain(line)).toThrow()
    }
  })
})

describe('commit guard — the hook passes the lane and the line to the guard', () => {
  const cases: [string, Lane, string][] = [
    ['git push --force', 'main', 'forces or deletes'],
    ['gh pr merge 5', 'sub-agent', 'does not merge'],
    ['gh pr merge 5', 'pipeline', 'does not merge'],
    ['git commit -m x', 'sub-agent', 'a sub-agent does not commit or push'],
    ['HUSKY=0 git commit -m x', 'main', 'as a plain line'],
    ['git commit -m x', 'main', 'a commit subject that breaks the git-commit format'],
  ]
  for (const [line, lane, words] of cases) {
    test(`refused [${lane}]: ${line}`, async ($, on) => {
      const w = world(on, LANES[lane].options)
      expect(await refusalOf($, bash(line), LANES[lane].agentId)).toContain(words)
      expect(w.ran).toEqual([])
    })
  }
  for (const lane of ['main', 'pipeline'] as const) {
    test(`a plain commit and push reach the engine [${lane}]`, async ($, on) => {
      const w = world(on, LANES[lane].options)
      expect(await refusalOf($, bash('git commit -m "fix: 🐛 Fix x."'), LANES[lane].agentId)).toBeUndefined()
      expect(await refusalOf($, bash('git push'), LANES[lane].agentId)).toBeUndefined()
      expect(w.ran).toEqual(['Bash: git commit -m "fix: 🐛 Fix x."', 'Bash: git push'])
    })
  }
  test('a sub-agent reads and searches freely', async ($, on) => {
    const w = world(on, LANES['sub-agent'].options)
    expect(await refusalOf($, bash('git status'), 'agent-1')).toBeUndefined()
    expect(await refusalOf($, bash('grep -n "git push" t.ts | sed -n 1,5p'), 'agent-1')).toBeUndefined()
    expect(w.ran.length).toBe(2)
  })
})

describe('commit guard — an answer the nouns cannot give fails closed', () => {
  test('a lane callerLane cannot give is read as a sub-agent', async ($, on) => {
    world(on, { lane: () => new Error('lane unknown') })
    expect(await refusalOf($, bash('git push'))).toContain('a sub-agent does not commit or push')
  })
  test('an isUnattended that rejects is read as unattended, so a merge is refused', async ($, on) => {
    world(on, { lane: () => 'main', unattended: new Error('unknown') })
    expect(await refusalOf($, bash('gh pr merge 5'))).toContain('does not merge')
  })
  test('an attended main loop may merge plainly, and an unattended one may not', async ($, on) => {
    world(on, { lane: () => 'main', unattended: false })
    expect(await refusalOf($, bash('gh pr merge 5'))).toBeUndefined()
  })
  test('an unattended main loop refuses a merge', async ($, on) => {
    world(on, { lane: () => 'main', unattended: true })
    expect(await refusalOf($, bash('gh pr merge 5'))).toContain('does not merge')
  })
  test('an unattended main loop still commits plainly', async ($, on) => {
    world(on, { lane: () => 'main', unattended: true })
    expect(await refusalOf($, bash('git commit -m "fix: 🐛 Fix x."'))).toBeUndefined()
  })
  test('a line parseShell cannot read is refused, and never reaches the engine', async ($, on) => {
    const w = world(on, { lane: () => 'main', parseFails: true })
    expect(await refusalOf($, bash('git status'))).toContain('could not judge')
    expect(w.ran).toEqual([])
  })
  test('a sub-agent of the pipeline does not commit, though the pipeline does', async ($, on) => {
    world(on, { lane: id => (id === undefined ? 'top-level-agent' : 'sub-agent'), unattended: true })
    expect(await refusalOf($, bash('git commit -m "fix: 🐛 Fix x."'))).toBeUndefined()
    expect(await refusalOf($, bash('git commit -m "fix: 🐛 Fix x."'), 'helper-1')).toContain('a sub-agent does not commit or push')
  })
})

const SB = '/SB'
const DISK: Record<string, Entry> = {
  [SB]: 'dir',
  [`${SB}/repo`]: 'dir',
  [`${SB}/repo/README.md`]: 'file',
  [`${SB}/repo/src`]: 'dir',
  [`${SB}/tmp`]: 'dir',
  [`${SB}/tmp/scratch`]: 'dir',
  [`${SB}/tmp/scratch/target.txt`]: 'file',
  [`${SB}/tmp/link-into-tree`]: { link: `${SB}/repo/src` },
  [`${SB}/home`]: 'dir',
  [`${SB}/home/Developer`]: 'dir',
  [`${SB}/home/Developer/scratchpad`]: 'dir',
}
const LENS = 'workbench-dev-team:holmes-lens'

function reviewWorld(on: Parameters<typeof world>[0], options: NonNullable<Parameters<typeof world>[1]> = {}) {
  return world(on, {
    lane: id => (id === undefined ? 'main' : 'sub-agent'),
    env: { HOME: `${SB}/home`, TMPDIR: `${SB}/tmp`, ...(options.env ?? {}) },
    roots: [`${SB}/home/Developer/scratchpad`],
    cwd: `${SB}/repo`,
    disk: DISK,
    agents: [{ id: 'lens-1', type: LENS }],
    ...options,
  })
}

describe('review guard — who is held', () => {
  const BREACH = `chmod 644 ${SB}/repo/README.md`
  const held: [string, string][] = [
    ['the helper', LENS],
    ['Holmes', 'workbench-dev-team:holmes'],
    ['his Local mode', 'workbench-dev-team:holmes-local'],
    ['his Index mode', 'workbench-dev-team:holmes-index'],
    ['a bare holmes type', 'holmes'],
    ['holmes spelled with ſ', 'workbench-dev-team:holmeſ'],
  ]
  for (const [who, type] of held) {
    test(`${who} (${type}) is held`, async ($, on) => {
      reviewWorld(on, { agents: [{ id: 'a-1', type }] })
      expect(await refusalOf($, bash(BREACH), 'a-1')).toContain('A Holmes reviewer')
    })
  }
  const free: [string, string][] = [
    ['Watson', 'workbench-dev-team:watson'],
    ['a Watson mode', 'workbench-dev-team:watson-direct'],
    ['a generic sub-agent', 'general-purpose'],
    ['a type that only contains holmes', 'workbench-dev-team:holmes-review-bot'],
    ['a type that only extends a mode name', 'workbench-dev-team:holmes-localbot'],
  ]
  for (const [who, type] of free) {
    test(`${who} (${type}) keeps its tools`, async ($, on) => {
      reviewWorld(on, { agents: [{ id: 'a-1', type }] })
      expect(await refusalOf($, bash(BREACH), 'a-1')).toBeUndefined()
    })
  }
  test('the main loop of a session keeps its tools', async ($, on) => {
    reviewWorld(on)
    expect(await refusalOf($, bash(BREACH))).toBeUndefined()
  })
  test('anything a reviewer spawned is held, at any depth', async ($, on) => {
    reviewWorld(on, {
      agents: [
        { id: 'h-1', type: 'workbench-dev-team:holmes-local' },
        { id: 'g-1', type: 'general-purpose', parentId: 'h-1' },
        { id: 'g-2', type: 'Explore', parentId: 'g-1' },
      ],
    })
    expect(await refusalOf($, bash(BREACH), 'g-2')).toContain('A Holmes reviewer')
  })
  test('a pipeline run of Holmes is held on its main loop and in its sub-agents', async ($, on) => {
    reviewWorld(on, {
      lane: id => (id === undefined ? 'top-level-agent' : 'sub-agent'),
      env: { CLAUDE_CODE_AGENT: 'workbench-dev-team:holmes-index' },
      agents: [{ id: 'g-1', type: 'general-purpose' }],
    })
    expect(await refusalOf($, bash(BREACH))).toContain('A Holmes reviewer')
    expect(await refusalOf($, bash(BREACH), 'g-1')).toContain('A Holmes reviewer')
  })
  test('a pipeline run of Watson keeps its tools', async ($, on) => {
    reviewWorld(on, { lane: () => 'top-level-agent', env: { CLAUDE_CODE_AGENT: 'workbench-dev-team:watson-index' } })
    expect(await refusalOf($, bash(BREACH))).toBeUndefined()
  })
  test('an agent the list does not name is held, and the refusal says why', async ($, on) => {
    reviewWorld(on, { agents: [] })
    expect(await refusalOf($, bash(BREACH), 'ghost-1')).toContain('could not tell which agent')
    expect(await refusalOf($, bash('git status'), 'ghost-1')).toBeUndefined()
  })
  test('an agent list that rejects holds the call too', async ($, on) => {
    reviewWorld(on, { agents: new Error('no list') })
    expect(await refusalOf($, bash(BREACH), 'a-1')).toContain('could not tell which agent')
  })
})

describe('review guard — the hook reads the disk, the roots and the working directory', () => {
  const cases: [string, Call, boolean][] = [
    ['a write through a scratch link into the tree', bash(`touch ${SB}/tmp/link-into-tree/new.txt`), true],
    ['a new path several folders deep in scratch', bash(`mkdir -p ${SB}/tmp/a/b/c`), false],
    ["$TMPDIR as a root", bash(`touch ${SB}/tmp/probe`), false],
    ["core's scratch root", bash(`touch ${SB}/home/Developer/scratchpad/probe`), false],
    ['a relative path in the tree', bash('touch new.txt'), true],
    ['an Edit in the tree', { tool: 'Edit', file_path: `${SB}/repo/README.md` }, true],
    ['an Edit in scratch', { tool: 'Edit', file_path: `${SB}/tmp/scratch/target.txt` }, false],
    ['a NotebookEdit in scratch', { tool: 'NotebookEdit', notebook_path: `${SB}/tmp/n.ipynb` }, false],
  ]
  for (const [what, call, isRefused] of cases) {
    test(`${isRefused ? 'refused' : 'passes'}: ${what}`, async ($, on) => {
      reviewWorld(on)
      expect((await refusalOf($, call, 'lens-1')) !== undefined).toBe(isRefused)
    })
  }
  test('with no scratch root at all, every write is refused', async ($, on) => {
    reviewWorld(on, { roots: [], env: { TMPDIR: '/nowhere' } })
    expect(await refusalOf($, bash(`touch ${SB}/tmp/probe`), 'lens-1')).toContain('no scratch root was found')
  })
  test('with no working directory, a relative path is refused', async ($, on) => {
    reviewWorld(on, { cwd: undefined })
    expect(await refusalOf($, bash('touch x'), 'lens-1')).toContain('cannot be resolved')
  })
  test('the refusal names the roots the hook found', async ($, on) => {
    reviewWorld(on)
    expect(await refusalOf($, bash(`chmod 644 ${SB}/repo/README.md`), 'lens-1')).toContain(`\`${SB}/home/Developer/scratchpad\`, \`${SB}/tmp\``)
  })
})
