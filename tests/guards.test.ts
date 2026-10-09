// hooks/register.ts with hooks/mods/commit-guard.ts and review-guard.ts: what
// the two guards refuse on a Bash or editing call, in each lane, read through
// workbench-core's own shell reader (tests/core/). tests/differential.mjs holds
// both guards to the bash guards they replaced, line by line.

import { describe, expect, test } from 'claude-code/testing'

import { BUILT_REFUSAL, PLAIN_REFUSAL, commitVerdict } from '../hooks/mods/commit-guard'
import { reviewBash } from '../hooks/mods/review-guard'
import { parseShell } from './core/hooks/mods/shell'
import { COMMIT_MAIN_PASSES, COMMIT_PASSES, COMMIT_REFUSALS, REVIEW_PASSES, REVIEW_REFUSALS } from './guard-cases'
import type { CommitLane } from './guard-cases'
import type { Entry, GuardOptions } from './world'
import { world } from './world'

type Call = { tool: string; command?: string; file_path?: string; notebook_path?: string }

// The refusal a call met, or undefined when it reached the engine.
async function refusalOf($: { tool: { call: (e: never) => Promise<unknown> } }, call: Call, agentId?: string): Promise<string | undefined> {
  const input = { tool_use_id: 'toolu_1', ...(call.tool === 'Bash' ? { description: 'd' } : {}), ...call, ...(agentId === undefined ? {} : { agentId }) }
  const result = (await $.tool.call(input as never)) as { deny?: string; isError?: boolean; text?: string }
  return result.deny ?? (result.isError ? result.text : undefined)
}

const bash = (command: string): Call => ({ tool: 'Bash', command })

// ── The commit guard ──────────────────────────────────────────────────────────

// Each lane as the module reads it: callerLane's answer, the agentId the call
// carries, and isUnattended.
const LANES: Readonly<Record<CommitLane, { agentId?: string; options: GuardOptions & { lane?: (id: string | undefined) => 'main' | 'sub-agent' | 'top-level-agent' } }>> = {
  main: { options: { lane: () => 'main', unattended: false } },
  'sub-agent': { agentId: 'agent-1', options: { lane: () => 'sub-agent', unattended: false, agents: [{ id: 'agent-1', type: 'workbench-dev-team:watson-direct' }] } },
  pipeline: { options: { lane: () => 'top-level-agent', unattended: true } },
}

describe('commit guard — the spellings review rounds found stay refused', () => {
  for (const [line, lanes] of COMMIT_REFUSALS) {
    for (const lane of ['main', 'sub-agent', 'pipeline'] as const) {
      const want = lanes.includes(lane)
      test(`${want ? 'refused' : 'passes'} [${lane}]: ${JSON.stringify(line)}`, async ($, on) => {
        const w = world(on, LANES[lane].options)
        const refusal = await refusalOf($, bash(line), LANES[lane].agentId)
        expect(refusal !== undefined).toBe(want)
        if (want) expect(refusal).toContain('Commit guard (workbench-dev-team)')
        expect(w.ran.length).toBe(want ? 0 : 1)
      })
    }
  }
})

describe('commit guard — the false positives pass', () => {
  for (const line of COMMIT_PASSES) {
    for (const lane of ['main', 'sub-agent', 'pipeline'] as const) {
      test(`passes [${lane}]: ${JSON.stringify(line.slice(0, 60))}`, async ($, on) => {
        const w = world(on, LANES[lane].options)
        expect(await refusalOf($, bash(line), LANES[lane].agentId)).toBeUndefined()
        expect(w.ran).toEqual([`Bash: ${line}`])
      })
    }
  }
  for (const line of COMMIT_MAIN_PASSES) {
    test(`a plain commit, push or merge is left to the ask rules [main]: ${JSON.stringify(line.slice(0, 60))}`, async ($, on) => {
      world(on, LANES.main.options)
      expect(await refusalOf($, bash(line))).toBeUndefined()
    })
  }
})

describe('commit guard — each refusal names its rule', () => {
  const cases: [string, CommitLane, string][] = [
    ['git push --force', 'main', 'forces or deletes'],
    ['gh pr merge 5', 'sub-agent', 'does not merge'],
    ['gh pr merge 5', 'pipeline', 'does not merge'],
    ['git commit -m x', 'sub-agent', 'a sub-agent does not commit or push'],
    ['HUSKY=0 git commit -m x', 'main', 'as a plain line'],
  ]
  for (const [line, lane, words] of cases) {
    test(`${lane}: ${line}`, async ($, on) => {
      world(on, LANES[lane].options)
      expect(await refusalOf($, bash(line), LANES[lane].agentId)).toContain(words)
    })
  }
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
    world(on, { lane: () => 'main', unattended: true })
    expect(await refusalOf($, bash('gh pr merge 5'))).toContain('does not merge')
  })
  test('an unattended main loop refuses a command name built at run time', async ($, on) => {
    world(on, { lane: () => 'main', unattended: true })
    expect(await refusalOf($, bash('"$PY" script.py'))).toContain('a command name the guard cannot read')
  })
  test('an attended top-level --agent run does not meet the built-name rule', async ($, on) => {
    world(on, { lane: () => 'top-level-agent', unattended: false })
    expect(await refusalOf($, bash('"$PY" script.py'))).toBeUndefined()
  })
  test('the unattended pipeline refuses a command name built at run time', async ($, on) => {
    world(on, { lane: () => 'top-level-agent', unattended: true })
    expect(await refusalOf($, bash('"$PY" script.py'))).toContain('a command name the guard cannot read')
  })
  // workbench-core's guards refuse this line in every lane before this one runs
  // (4e83554). This guard leaves it to them in an attended main loop.
  test('an attended main loop does not meet the built-name rule', async ($, on) => {
    world(on, { lane: () => 'main', unattended: false })
    expect(await refusalOf($, bash('"$PY" script.py'))).toBeUndefined()
    expect(await refusalOf($, bash('g$(echo it) com$(echo mit) -m x'))).toBeUndefined()
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

// ── isPlaced, apart from the unknown that always comes with it ────────────────

// workbench-core sets the `wrapper` unknown whenever a statement is not placed,
// so a line from the reader never shows one without the other. Each guard
// checks isPlaced on its own too, and these readings hold that check alone.
describe('both guards — a statement not placed is refused even with no unknown', () => {
  const unplaced = (line: string) => {
    const parse = parseShell(line)
    return { ...parse, unknowns: [], statements: parse.statements.map(s => ({ ...s, isPlaced: false })) }
  }
  test('the commit guard reads it as a hidden commit or push', () => {
    const line = 'sudo -s git push'
    expect(commitVerdict(unplaced(line), line, { lane: 'main', isUnattended: false })).toEqual(PLAIN_REFUSAL)
  })
  test('the review guard refuses it', () => {
    expect('finding' in reviewBash(unplaced('sudo -s rm x'), { cwd: '/SB/repo', home: '/SB/home' })).toBe(true)
  })
})

// ── The compound unknown ──────────────────────────────────────────────────────

// Since workbench-core 47a5e27 the reader sets `compound` when an array or a
// case is still open where the line ends. Each guard that names unknowns, or
// counts them, must refuse on it.
describe('both guards — an array or case still open, and the other unknowns, are refused', () => {
  const OPEN = ['x=(a $(echo b)', 'case x in\n a) ls ;;']
  for (const line of OPEN) {
    test(`the reader marks it: ${JSON.stringify(line)}`, () => {
      expect(parseShell(line).unknowns).toEqual(['compound'])
    })
    test(`the commit guard refuses it where nobody watches: ${JSON.stringify(line)}`, () => {
      expect(commitVerdict(parseShell(line), line, { lane: 'sub-agent', isUnattended: false })).toEqual(BUILT_REFUSAL)
      expect(commitVerdict(parseShell(line), line, { lane: 'top-level-agent', isUnattended: true })).toEqual(BUILT_REFUSAL)
      expect(commitVerdict(parseShell(line), line, { lane: 'main', isUnattended: false })).toBeUndefined()
    })
    test(`the review guard refuses it: ${JSON.stringify(line)}`, () => {
      const verdict = reviewBash(parseShell(line), { cwd: '/SB/repo', home: '/SB/home' })
      expect('finding' in verdict && JSON.stringify(verdict.finding)).toContain('compound')
    })
  }
  test('a push inside an open case is a hidden push, in every lane', () => {
    const line = 'case x in\n a) git push ;;'
    expect(commitVerdict(parseShell(line), line, { lane: 'main', isUnattended: false })).toEqual(PLAIN_REFUSAL)
  })
  test('scripts nested past four levels set depth, and rule 5 refuses them where nobody watches', () => {
    const line = "bash -c 'bash -c \"bash -c \\\"bash -c \\\\\\\"bash -c ls\\\\\\\"\\\"\"'"
    expect(parseShell(line).unknowns).toEqual(['depth'])
    expect(commitVerdict(parseShell(line), line, { lane: 'sub-agent', isUnattended: false })).toEqual(BUILT_REFUSAL)
    expect(commitVerdict(parseShell(line), line, { lane: 'top-level-agent', isUnattended: true })).toEqual(BUILT_REFUSAL)
  })
  // Where the reader and the shell disagree on where a quote, a substitution
  // or a heredoc ends, the shell runs a command the reader read as text
  // (Holmes, 47a5e27 review: zsh runs `$x$y` in the first two, and bash and
  // zsh both in the third). Rule 5 refuses each unknown where nobody watches.
  test('a quote, substitution or heredoc the reader cannot close is refused where nobody watches', () => {
    const lines: [string, string[]][] = [
      ['x=ech; y=o; echo $[ "1 ]; $x$y MARK', ['quote']],
      ['echo $(( 1 + "1 )); $x$y MARK', ['quote', 'substitution']],
      ["cat <<$'EOF'\nhi\nEOF\n$x$y MARK", ['heredoc']],
    ]
    for (const [line, unknowns] of lines) {
      expect(parseShell(line).unknowns).toEqual(unknowns)
      expect(commitVerdict(parseShell(line), line, { lane: 'sub-agent', isUnattended: false })).toEqual(BUILT_REFUSAL)
      expect(commitVerdict(parseShell(line), line, { lane: 'top-level-agent', isUnattended: true })).toEqual(BUILT_REFUSAL)
    }
  })
  test('a closed array and a closed case are not refused', () => {
    for (const line of ['x=(a b) ; ls', 'case x in\n a) ls ;;\nesac']) {
      expect(parseShell(line).unknowns).toEqual([])
      expect(commitVerdict(parseShell(line), line, { lane: 'sub-agent', isUnattended: false })).toBeUndefined()
    }
  })
})

// ── The review guard ──────────────────────────────────────────────────────────

const SB = '/SB'
const DISK: Record<string, Entry> = {
  [SB]: 'dir',
  [`${SB}/repo`]: 'dir',
  [`${SB}/repo/README.md`]: 'file',
  [`${SB}/repo/file.txt`]: 'file',
  [`${SB}/repo/src`]: 'dir',
  [`${SB}/repo/src/a.txt`]: 'file',
  [`${SB}/repo/src/b.txt`]: 'file',
  [`${SB}/repo/link-out`]: { link: `${SB}/tmp/scratch/target.txt` },
  [`${SB}/tmp`]: 'dir',
  [`${SB}/tmp/scratch`]: 'dir',
  [`${SB}/tmp/scratch/target.txt`]: 'file',
  [`${SB}/tmp/link-into-tree`]: { link: `${SB}/repo/src` },
  [`${SB}/tmp/dangling`]: { link: `${SB}/repo/new.txt` },
  [`${SB}/home`]: 'dir',
  [`${SB}/home/Developer`]: 'dir',
  [`${SB}/home/Developer/scratchpad`]: 'dir',
}
const LENS = 'workbench-dev-team:holmes-lens'
const fill = (line: string) => line.replaceAll('@SANDBOX@', SB)

// A world with the sandbox's disk, core's scratch root and $TMPDIR, and the
// agents given.
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

describe('review guard — a reviewer writes nothing outside scratch', () => {
  for (const line of REVIEW_REFUSALS) {
    test(`refused: ${JSON.stringify(line.slice(0, 70))}`, async ($, on) => {
      const w = reviewWorld(on)
      const refusal = await refusalOf($, bash(fill(line)), 'lens-1')
      // A command name built at run time meets the commit guard first.
      expect(refusal).toMatch(/A Holmes reviewer writes only in scratch|a command name the guard cannot read/)
      expect(w.ran).toEqual([])
    })
  }
})

describe('review guard — the false positives and the scratch writes pass', () => {
  for (const line of REVIEW_PASSES) {
    test(`passes: ${JSON.stringify(line.slice(0, 70))}`, async ($, on) => {
      const w = reviewWorld(on)
      expect(await refusalOf($, bash(fill(line)), 'lens-1')).toBeUndefined()
      expect(w.ran).toEqual([`Bash: ${fill(line)}`])
    })
  }
})

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
  test("the main loop of a session keeps its tools", async ($, on) => {
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
  test("a pipeline run of Holmes is held on its main loop and in its sub-agents", async ($, on) => {
    reviewWorld(on, {
      lane: id => (id === undefined ? 'top-level-agent' : 'sub-agent'),
      env: { CLAUDE_CODE_AGENT: 'workbench-dev-team:holmes-index' },
      agents: [{ id: 'g-1', type: 'general-purpose' }],
    })
    expect(await refusalOf($, bash(BREACH))).toContain('A Holmes reviewer')
    expect(await refusalOf($, bash(BREACH), 'g-1')).toContain('A Holmes reviewer')
  })
  test("a pipeline run of Watson keeps its tools", async ($, on) => {
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

describe('review guard — paths are judged on the disk', () => {
  const cases: [string, Call, boolean][] = [
    ['a write through a scratch link into the tree', bash(`touch ${SB}/tmp/link-into-tree/new.txt`), true],
    ['a link in the tree removed where it lives, though it points into scratch', bash(`rm ${SB}/repo/link-out`), true],
    ['a write through a link that leads nowhere', bash(`echo x > ${SB}/tmp/dangling`), true],
    ['a write to a root itself', bash(`rm -rf ${SB}/tmp`), true],
    ['a new path several folders deep in scratch', bash(`mkdir -p ${SB}/tmp/a/b/c`), false],
    ['a path that climbs out of scratch', bash(`touch ${SB}/tmp/../repo/x`), true],
    ['a path with .. below what exists', bash(`touch ${SB}/tmp/new/../../repo/x`), true],
    ["$TMPDIR as a root", bash(`touch ${SB}/tmp/probe`), false],
    ["core's scratch root", bash(`touch ${SB}/home/Developer/scratchpad/probe`), false],
    ['~ expanded to HOME', bash('touch ~/Developer/scratchpad/probe'), false],
    ['a relative path in the tree', bash('touch new.txt'), true],
    ['a relative path after cd', bash(`cd ${SB}/tmp && touch new.txt`), true],
    ['a write to a variable', bash('touch "$DIR/x"'), true],
    ['an Edit in the tree', { tool: 'Edit', file_path: `${SB}/repo/README.md` }, true],
    ['an Edit in scratch', { tool: 'Edit', file_path: `${SB}/tmp/scratch/target.txt` }, false],
    ['a Write by a relative path in the tree', { tool: 'Write', file_path: 'notes.md' }, true],
    ['a Write with no path', { tool: 'Write' }, true],
    ['a NotebookEdit in scratch', { tool: 'NotebookEdit', notebook_path: `${SB}/tmp/n.ipynb` }, false],
    ['a NotebookEdit in the tree', { tool: 'NotebookEdit', notebook_path: `${SB}/repo/n.ipynb` }, true],
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
  test("zsh's >! and >>! clobber the next word, which bash reads as a file named !", async ($, on) => {
    reviewWorld(on, { cwd: `${SB}/tmp` })
    expect(await refusalOf($, bash(`echo x >! ${SB}/repo/README.md`), 'lens-1')).toContain('cannot be resolved')
    expect(await refusalOf($, bash(`echo x >>!${SB}/repo/README.md`), 'lens-1')).toContain('outside the scratch roots')
    expect(await refusalOf($, bash(`echo x >!${SB}/tmp/probe`), 'lens-1')).toBeUndefined()
  })
  test('with no working directory, a relative path is refused', async ($, on) => {
    reviewWorld(on, { cwd: undefined })
    expect(await refusalOf($, bash('touch x'), 'lens-1')).toContain('cannot be resolved')
  })
  test('the refusal names the roots and sends a probe to a scratch copy', async ($, on) => {
    reviewWorld(on)
    const refusal = await refusalOf($, bash(`chmod 644 ${SB}/repo/README.md`), 'lens-1')
    expect(refusal).toContain(`\`${SB}/home/Developer/scratchpad\`, \`${SB}/tmp\``)
    expect(refusal).toContain('under the session scratchpad or ~/Developer/scratchpad, and deleted')
  })
})
