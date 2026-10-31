import { describe, expect, test } from 'claude-code/testing'

import type { Entry } from './world'
import { readPlain, world } from './world'

type Call = { tool: string; command?: string; file_path?: string; notebook_path?: string }

async function refusalOf($: { tool: { call: (e: never) => Promise<unknown> } }, call: Call, agentId?: string): Promise<string | undefined> {
  const input = { tool_use_id: 'toolu_1', ...(call.tool === 'Bash' ? { description: 'd' } : {}), ...call, ...(agentId === undefined ? {} : { agentId }) }
  const result = (await $.tool.call(input as never)) as { deny?: string; isError?: boolean; text?: string }
  return result.deny ?? (result.isError ? result.text : undefined)
}

const bash = (command: string): Call => ({ tool: 'Bash', command })

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

describe('no guard of its own on commits, pushes or merges — workbench-core holds them', () => {
  const LINES = ['git push --force', 'gh pr merge 5', 'git commit -m x', 'HUSKY=0 git commit -m x', 'git push']
  const lanes: [string, string | undefined, Parameters<typeof world>[1]][] = [
    ['main', undefined, { lane: () => 'main' }],
    ['sub-agent', 'agent-1', { lane: () => 'sub-agent', agents: [{ id: 'agent-1', type: 'workbench-dev-team:watson-direct' }] }],
    ['pipeline', undefined, { lane: () => 'top-level-agent', env: { CLAUDE_CODE_AGENT: 'workbench-dev-team:watson-index' } }],
  ]
  for (const [lane, agentId, options] of lanes) {
    test(`every line reaches the engine [${lane}]`, async ($, on) => {
      const w = world(on, options)
      for (const line of LINES) expect(await refusalOf($, bash(line), agentId)).toBeUndefined()
      expect(w.ran).toEqual(LINES.map(line => `Bash: ${line}`))
    })
  }
  test("a call outside the review guard's reach is not read, so a reader that fails refuses nothing", async ($, on) => {
    const w = world(on, { lane: () => 'main', parseFails: true })
    expect(await refusalOf($, bash('git status'))).toBeUndefined()
    expect(w.ran).toEqual(['Bash: git status'])
  })
})

describe('review guard — a guard that throws refuses the call', () => {
  test("a reviewer's line parseShell cannot read is refused, and never reaches the engine", async ($, on) => {
    const w = reviewWorld(on, { parseFails: true })
    expect(await refusalOf($, bash('git status'), 'lens-1')).toContain('🛑 Blocked: a call the review guard could not judge.')
    expect(w.ran).toEqual([])
  })
  test('a call whose maker cannot be told is read too, and refused when the reader fails', async ($, on) => {
    const w = reviewWorld(on, { parseFails: true, agents: [] })
    expect(await refusalOf($, bash('git status'), 'ghost-1')).toContain('could not judge')
    expect(w.ran).toEqual([])
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
    ['a Write in the tree', { tool: 'Write', file_path: `${SB}/repo/new.txt` }, true],
    ['a Write in scratch', { tool: 'Write', file_path: `${SB}/tmp/scratch/new.txt` }, false],
    ['a NotebookEdit in the tree', { tool: 'NotebookEdit', notebook_path: `${SB}/repo/n.ipynb` }, true],
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

describe('a reviewer reaches GitHub through gh read verbs only (C9, C19, C21)', () => {
  const HOLMES = { lane: () => 'top-level-agent' as const, env: { CLAUDE_CODE_AGENT: 'workbench-dev-team:holmes-index' } }
  for (const line of [
    'gh pr merge 5',
    'gh pr review 5 --approve',
    'gh pr comment 5 -b looks-good',
    'gh issue create -t x -b y',
    'gh issue comment 1 -b x',
    'gh pr checkout 5',
    'gh repo clone o/r /scratch/x',
    'gh project item-edit --id x',
    'gh api -X POST repos/o/r/issues',
    'gh api --method=PATCH repos/o/r/pulls/5',
    'gh api repos/o/r/issues -f title=x',
    'gh api repos/o/r/issues --input body.json',
    'gh api graphql -F query=x',
    'curl -X POST https://api.github.com/repos/o/r/issues',
    'security find-generic-password -s x -w',
    'gh auth status --show-token',
    'gh auth status',
  ]) {
    test(`\`${line}\` is refused`, async ($, on) => {
      const w = world(on, HOLMES)
      expect(await refusalOf($ as never, bash(line))).toContain('Blocked')
      expect(w.ran).toEqual([])
    })
  }
  for (const line of [
    'gh pr view 5 -R o/r --json reviews',
    'gh pr checks 5 -R o/r',
    'gh pr diff 5 -R o/r',
    'gh pr list -R o/r --state all',
    'gh issue view 1 -R o/r --json body,comments',
    'gh api repos/o/r/pulls/5/comments',
    'gh api -X GET repos/o/r',
    'gh run list --branch main',
  ]) {
    test(`\`${line}\` reaches the engine`, async ($, on) => {
      const w = world(on, HOLMES)
      expect(await refusalOf($ as never, bash(line))).toBeUndefined()
      expect(w.ran).toEqual([`Bash: ${line}`])
    })
  }
})
