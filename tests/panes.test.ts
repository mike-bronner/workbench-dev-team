// hooks/register.ts with hooks/mods/runs.ts, board.ts and panes.tsx: the two
// read-only dev-team panes. The runs pane reads fixture logs through stand-in
// fs.list, awk and ps answers; the board pane reads a stand-in run of
// `bin/dispatch-tick.sh --board`, whose real run against tests/fake-index.py is
// pinned in bin/test-dispatch-tick.sh, and the awk program's real output in
// bin/test-scan-run-logs.sh.

import { describe, expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'
import type { Engine } from 'claude-code/testing'

import { afterFetch, boardArgv, boardOf, boardOutcome, cadenceMsOf, EMPTY_BOARD, escalatedOf, isDue } from '../hooks/mods/board'
import { endsOf, livePairsOf, markersOf, newestRuns, rowsOf, runLogOf, scanArgv, stateOf } from '../hooks/mods/runs'
import type { Board, BoardView } from '../types'

const HOME = '/Users/tester'
const DIR = `${HOME}/.claude-workbench/dev-team-logs`
const TOKEN_CACHE = `${HOME}/.claude-workbench/the-index-token.json`
const SECRET = 'tok-SECRET-0123456789'
const MINUTE = 60_000
const RS = '\u001e'

type Answer = { exitCode: number; stdout: string; stderr: string }
type FileEntry = { name: string; kind: string; mtimeMs: number; size: number }

// A log in the fixture folder: its end as awk reads it.
type Fixture = { name: string; mtimeMs: number; size?: number; tail?: string[]; refusals?: number }

type Host = {
  // Each $.process.run, as its argv.
  runs: string[][]
  // Each path $.fs.read, $.fs.write or $.fs.list touched, by kind.
  reads: string[]
  writes: string[]
  lists: string[]
  // The panes open now, and how many times the module asked which.
  open: Set<string>
  paneQueries: number
  // The fixture logs and other files in the log folder; tests change them.
  logs: Fixture[]
  other: string[]
  // Logs the listing names that are gone by the scan, and the scan's exit code
  // when it meets one: 0 as bin/scan-run-logs.awk skips it, 2 for a log that
  // went in the moment between its open check and its read.
  vanished: Fixture[]
  vanishedExit: number
  ps: string
  board: () => Answer | Error | Promise<Answer>
}

const board = (lanes: Record<string, unknown>): Answer => ({ exitCode: 0, stdout: JSON.stringify({ lanes }), stderr: '' })

const item = (id: number, n: number, repo = 'o/a', claimedAt: string | null = null) => ({ id, number: n, isPr: false, repo, title: `Item ${n}`, claimedAt })

const GOOD_BOARD = board({
  unrefined: { limit: 25, items: [item(11, 101), item(12, 102)] },
  review: { limit: 25, items: Array.from({ length: 25 }, (_, i) => item(200 + i, 400 + i)) },
  development: { limit: 25, items: [item(31, 301, 'o/a', '2026-10-08T10:00:00+00:00'), item(32, 302, 'o/b')] },
})

function host(on: On, options: { logs?: Fixture[]; other?: string[]; ps?: string; board?: () => Answer | Error | Promise<Answer>; home?: boolean; now?: number; failing?: string } = {}) {
  const h: Host = {
    runs: [],
    reads: [],
    writes: [],
    lists: [],
    open: new Set(),
    paneQueries: 0,
    logs: options.logs ?? [],
    other: options.other ?? [],
    vanished: [],
    vanishedExit: 0,
    ps: options.ps ?? '',
    board: options.board ?? (() => GOOD_BOARD),
  }
  if (options.home !== false) mock.env(on, { HOME })
  else mock.env(on, {})
  const clock = mock.clock(on, { now: options.now ?? Date.UTC(2026, 9, 8, 12, 0, 0) })

  on('fs.list', async ($, e) => {
    h.lists.push(e.path ?? '')
    if (e.path !== DIR) throw new Error(`ENOENT: ${e.path}`)
    const entries: FileEntry[] = [
      ...[...h.logs, ...h.vanished].map(log => ({ name: log.name, kind: 'file', mtimeMs: log.mtimeMs, size: log.size ?? 100 })),
      ...h.other.map(name => ({ name, kind: 'file', mtimeMs: 1, size: 1 })),
    ]
    return { value: entries.map(entry => ({ ...entry, isLink: false })) } as never
  })
  on('fs.read', async ($, e) => {
    h.reads.push(e.path)
    throw new Error(`ENOENT: ${e.path}`)
  })
  on('fs.write', async ($, e) => {
    h.writes.push((e as { path: string }).path)
    return { value: undefined } as never
  })
  on('process.run', async ($, e) => {
    const argv = [...e.argv]
    h.runs.push(argv)
    let answer: Answer | Error
    if (argv[0] === options.failing) answer = { exitCode: 2, stdout: '', stderr: `${argv[0]}: failed` }
    else if (argv[0] === 'awk') answer = scan(h, argv.slice(3))
    else if (argv[0] === 'ps') answer = { exitCode: 0, stdout: h.ps, stderr: '' }
    else if (argv[0] === 'bash' && argv[2] === '--board') answer = await h.board()
    else answer = new Error(`unexpected command: ${argv.join(' ')}`)
    if (answer instanceof Error) throw answer
    return { value: { ...answer, isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('ui.open', async ($, e) => {
    h.open.add(e.id)
    return { value: { isPlaced: true } } as never
  })
  on('ui.close', async ($, e) => {
    h.open.delete((e as { id: string }).id)
    return { value: undefined } as never
  })
  on('ui.panes', async () => {
    h.paneQueries++
    return { value: [...h.open].map(id => ({ id, title: id, isShown: true, isFocused: false, isPlaced: true })) } as never
  })
  return { h, clock }
}

// What awk prints for the fixture logs it is given, in bin/scan-run-logs.awk's
// format: a header and the tail per log it can open, none for one it cannot.
function scan(h: Host, paths: string[]): Answer {
  const out: string[] = []
  let exitCode = 0
  for (const path of paths) {
    const log = h.logs.find(one => `${DIR}/${one.name}` === path)
    if (log === undefined) {
      exitCode = h.vanishedExit
      continue
    }
    out.push(`${RS}${log.refusals ?? 0}\t${path}`, ...(log.tail ?? []))
  }
  return { exitCode, stdout: out.length === 0 ? '' : `${out.join('\n')}\n`, stderr: exitCode === 0 ? '' : "awk: can't open file" }
}

const PANE_PROPS = (title: string) => ({
  title,
  isFocused: false,
  bodyColumns: 100,
  placement: 'dock' as const,
  scroll: { offset: 0, bodyRows: 40 },
  view: {},
})

// A command run as the person typing it does.
const typed = (command: string) => ({ command, args: '', origin: { kind: 'composer' } }) as never

async function open($: Engine, command: 'dev-team-runs' | 'dev-team-board', clock: { settle: () => Promise<unknown> }) {
  const result = await $.command.run(typed(command))
  await clock.settle()
  return result
}

type Drawing = Awaited<ReturnType<typeof drawn>>

// The run rows a drawing holds, each a Box keyed run-<n>, with its text's
// whitespace runs folded to one space.
async function runRows(ui: Drawing): Promise<string[]> {
  const boxes = await ui.findAll({ type: 'Box' })
  return boxes.filter(box => box.key?.startsWith('run-')).map(box => box.text.replace(/\s+/g, ' ').trim())
}

const SCRIPT_IN_PLUGIN = /^\/.+\/bin\/dispatch-tick\.sh$/
const AWK_IN_PLUGIN = /^\/.+\/bin\/scan-run-logs\.awk$/

async function drawn($: Engine, id: 'dev-team-runs' | 'dev-team-board') {
  const ui = await $.ui.mount({
    plugin: 'workbench-dev-team',
    surface: 'terminal',
    component: 'Pane',
    requestId: id,
    props: PANE_PROPS(id),
  })
  return ui
}

// ── The runs pane: pure parts ────────────────────────────────────────────────

describe('runs — log names', () => {
  test('an item log names its agent, item, start and pair', () => {
    expect(runLogOf('watson-42-20261008-101500.log')).toEqual({
      name: 'watson-42-20261008-101500.log',
      agent: 'watson',
      target: 'item 42',
      pair: 'watson-42',
      startedAt: '2026-10-08 10:15:00',
    })
  })

  test('a sweep log names its repo slug', () => {
    expect(runLogOf('lestrade-sweep-mike-bronner-workbench-dev-team-20261008-090102.log')).toMatchObject({
      agent: 'lestrade',
      target: 'sweep mike-bronner-workbench-dev-team',
      pair: 'lestrade-sweep-mike-bronner-workbench-dev-team',
      startedAt: '2026-10-08 09:01:02',
    })
  })

  test('the tick log, locks, markers and strangers are no runs', () => {
    for (const name of ['dispatch-tick.log', 'watson-42.lock', 'watson-42.escalated', 'claude-42-20261008-101500.log', 'watson-x-20261008-101500.log', 'watson-42-20261008-1015.log', 'watson-42-20261008-101500.log.bak']) {
      expect(runLogOf(name)).toBeUndefined()
    }
  })

  test('newestRuns keeps the newest files only, newest first', () => {
    const entries = [
      ...Array.from({ length: 10 }, (_, i) => ({ name: `holmes-${i}-20261008-1000${String(i).padStart(2, '0')}.log`, kind: 'file', mtimeMs: i, size: 1 })),
      { name: 'dispatch-tick.log', kind: 'file', mtimeMs: 99, size: 1 },
      { name: 'watson-1-20261008-100000.log', kind: 'dir', mtimeMs: 98, size: 0 },
    ]
    const newest = newestRuns(entries, 3)
    expect(newest.map(run => run.name)).toEqual(['holmes-9-20261008-100009.log', 'holmes-8-20261008-100008.log', 'holmes-7-20261008-100007.log'])
    expect(newestRuns(entries).length).toBe(8)
  })

  test('markers name the escalated pairs', () => {
    const names = ['watson-42.escalated', 'holmes-7.escalated', 'watson-42.lock', 'x.escalated']
    expect(markersOf(names.map(name => ({ name, kind: 'file', mtimeMs: 0, size: 0 })))).toEqual(['watson-42', 'holmes-7'])
  })
})

describe('runs — which runs are live', () => {
  test('a dispatcher command line names its pair; a check or a mark does not', () => {
    const ps = [
      'bash /Users/tester/.claude-workbench/bin/dispatch-agent.sh watson 42',
      'bash /Users/tester/.claude-workbench/bin/dispatch-agent.sh lestrade o/r-x',
      'bash /Users/tester/.claude-workbench/bin/dispatch-agent.sh --check holmes 7',
      'bash /Users/tester/.claude-workbench/bin/dispatch-agent.sh --mark-escalated holmes 8',
      'bash /Users/tester/.claude-workbench/bin/dispatch-agent.sh holmes o/r',
      'vim dispatch-agent.sh',
      '/usr/bin/less /Users/tester/notes about dispatch-agent.sh watson 9 later',
    ].join('\n')
    expect([...livePairsOf(ps)].sort()).toEqual(['lestrade-sweep-o-r-x', 'watson-42'])
  })
})

describe('runs — a log\u2019s end and the state it means', () => {
  test('endsOf reads the scan format, path by path', () => {
    const out = `${RS}2\t/l/a.log\nworking\nError: Exceeded USD budget\n${RS}0\t/l/b.log\none\n`
    const ends = endsOf(out)
    expect(ends.get('/l/a.log')).toEqual({ tail: ['working', 'Error: Exceeded USD budget'], refusals: 2 })
    expect(ends.get('/l/b.log')).toEqual({ tail: ['one'], refusals: 0 })
    expect(ends.size).toBe(2)
  })

  const end = (...tail: string[]) => ({ tail, refusals: 0 })
  const facts = { isNewest: true, isLive: false, isEscalated: false }

  test('the newest run of a live pair is running, whatever its log says', () => {
    expect(stateOf({ ...facts, isLive: true, end: end('Error: Exceeded USD budget') })).toBe('running')
  })
  test('an older run of a live pair has ended', () => {
    expect(stateOf({ ...facts, isNewest: false, isLive: true, end: end('all done') })).toBe('done')
  })
  test('the newest run of an escalated pair is escalated', () => {
    expect(stateOf({ ...facts, isEscalated: true, end: end('API Error: 500') })).toBe('escalated')
  })
  test('an older run of an escalated pair is read from its log', () => {
    expect(stateOf({ ...facts, isNewest: false, isEscalated: true, end: end('API Error: 500') })).toBe('failed')
  })
  test('the content filter is a refusal', () => {
    expect(stateOf({ ...facts, end: end('API Error: Output blocked by content filtering policy') })).toBe('refused')
  })
  test('the budget kill line is budget-killed', () => {
    expect(stateOf({ ...facts, end: end('Error: Exceeded USD budget') })).toBe('budget-killed')
  })
  for (const line of ['API Error: 529 overloaded', 'Execution error', 'Error: Reached max turns', 'error: No messages returned from query']) {
    test(`"${line}" is a failure`, () => {
      expect(stateOf({ ...facts, end: end('x', line) })).toBe('failed')
    })
  }
  test('a log that ends on its report is done, and an empty one too', () => {
    expect(stateOf({ ...facts, end: end('Moved #12 to In Review.') })).toBe('done')
    expect(stateOf({ ...facts, end: end() })).toBe('done')
  })

  test('rowsOf marks only the newest run of a pair as the live one', () => {
    const runs = newestRuns(
      ['watson-42-20261008-110000.log', 'watson-42-20261008-100000.log'].map((name, i) => ({ name, kind: 'file', mtimeMs: 10 - i, size: 1 })),
    )
    const ends = new Map([[`${DIR}/watson-42-20261008-100000.log`, { tail: ['done'], refusals: 3 }]])
    const rows = rowsOf(DIR, runs, ends, new Set(['watson-42']), [])
    expect(rows.map(row => [row.state, row.refusals, row.log])).toEqual([
      ['running', 0, `${DIR}/watson-42-20261008-110000.log`],
      ['done', 3, `${DIR}/watson-42-20261008-100000.log`],
    ])
  })

  test('the scan runs the shipped awk file, on the files given', () => {
    expect(scanArgv('/p', ['/l/a.log'])).toEqual(['awk', '-f', '/p/bin/scan-run-logs.awk', '/l/a.log'])
  })
})

// ── The runs pane: the hooks ─────────────────────────────────────────────────

const LOGS: Fixture[] = [
  { name: 'watson-42-20261008-110000.log', mtimeMs: 900, tail: ['working on it'] },
  { name: 'holmes-7-20261008-105000.log', mtimeMs: 800, tail: ['Approved.'], refusals: 2 },
  { name: 'lestrade-9-20261008-104000.log', mtimeMs: 700, tail: ['Error: Exceeded USD budget'] },
  { name: 'watson-5-20261008-103000.log', mtimeMs: 600, tail: ['API Error: Output blocked by content filtering policy'] },
  { name: 'holmes-8-20261008-102000.log', mtimeMs: 500, tail: ['API Error: 529'] },
  { name: 'lestrade-sweep-o-r-20261008-101000.log', mtimeMs: 400, tail: ['Swept.'] },
]
const PS = 'bash /Users/tester/.claude-workbench/bin/dispatch-agent.sh watson 42\n'

describe('the runs pane', () => {
  test('/dev-team-runs opens the pane and draws each run: agent, target, start, state and log', async ($, on) => {
    const { h, clock } = host(on, { logs: LOGS, ps: PS, other: ['holmes-8.escalated', 'dispatch-tick.log', 'watson-42.lock'] })
    const result = await open($, 'dev-team-runs', clock)
    expect(result.text).toBe('Dev-team runs pane opened.')
    expect([...h.open]).toEqual(['dev-team-runs'])
    const ui = await drawn($, 'dev-team-runs')
    expect(await runRows(ui)).toEqual([
      `running watson item 42 · started 2026-10-08 11:00:00 ${DIR}/watson-42-20261008-110000.log`,
      `done holmes item 7 · started 2026-10-08 10:50:00 · 2 refused calls ${DIR}/holmes-7-20261008-105000.log`,
      `budget-killed lestrade item 9 · started 2026-10-08 10:40:00 ${DIR}/lestrade-9-20261008-104000.log`,
      `refused watson item 5 · started 2026-10-08 10:30:00 ${DIR}/watson-5-20261008-103000.log`,
      `escalated holmes item 8 · started 2026-10-08 10:20:00 ${DIR}/holmes-8-20261008-102000.log`,
      `done lestrade sweep o-r · started 2026-10-08 10:10:00 ${DIR}/lestrade-sweep-o-r-20261008-101000.log`,
    ])
    await ui.unmount()
  })

  test('it reads only the newest eight logs, and the log folder, nothing else', async ($, on) => {
    const many: Fixture[] = Array.from({ length: 12 }, (_, i) => ({ name: `holmes-${i}-20261008-10${String(i).padStart(2, '0')}00.log`, mtimeMs: i, tail: ['ok'] }))
    const { h, clock } = host(on, { logs: many })
    await open($, 'dev-team-runs', clock)
    const awk = h.runs.filter(argv => argv[0] === 'awk')
    expect(awk.length).toBe(1)
    expect(awk[0]?.slice(3)).toEqual(many.slice(4).reverse().map(log => `${DIR}/${log.name}`))
    expect(awk[0]?.slice(0, 2)).toEqual(['awk', '-f'])
    expect(awk[0]?.[2]).toMatch(AWK_IN_PLUGIN)
    expect(h.lists).toEqual([DIR])
  })

  test('a refresh reads again only the logs whose size or mtime changed', async ($, on) => {
    const { h, clock } = host(on, { logs: LOGS.map(log => ({ ...log })), ps: PS })
    await open($, 'dev-team-runs', clock)
    expect(h.runs.filter(argv => argv[0] === 'awk').length).toBe(1)
    await clock.advance(15_000)
    expect(h.runs.filter(argv => argv[0] === 'awk').length).toBe(1)
    expect(h.runs.filter(argv => argv[0] === 'ps').length).toBe(2)
    const live = h.logs[0]
    if (live) {
      live.size = 500
      live.tail = ['Moved #12 to In Review.']
    }
    h.ps = ''
    await clock.advance(15_000)
    const awk = h.runs.filter(argv => argv[0] === 'awk')
    expect(awk.length).toBe(2)
    expect(awk[1]?.slice(3)).toEqual([`${DIR}/watson-42-20261008-110000.log`])
    const ui = await drawn($, 'dev-team-runs')
    expect((await runRows(ui))[0]).toMatch(/^done watson item 42 /)
    await ui.unmount()
  })

  test('a new run joins at the top on the next refresh', async ($, on) => {
    const { h, clock } = host(on, { logs: LOGS.map(log => ({ ...log })), ps: PS })
    await open($, 'dev-team-runs', clock)
    h.logs.push({ name: 'holmes-77-20261008-120000.log', mtimeMs: 1000, tail: [] })
    h.ps = `${PS}bash /x/dispatch-agent.sh holmes 77\n`
    await clock.advance(15_000)
    const ui = await drawn($, 'dev-team-runs')
    expect((await runRows(ui))[0]).toMatch(/^running holmes item 77 · started 2026-10-08 12:00:00 /)
    await ui.unmount()
  })

  test('with no logs yet the pane says so', async ($, on) => {
    const { clock } = host(on)
    await open($, 'dev-team-runs', clock)
    const ui = await drawn($, 'dev-team-runs')
    expect(await ui.find({ type: 'Text', text: /No dispatched runs/ })).toBeDefined()
    await ui.unmount()
  })

  for (const [command, message] of [
    ['awk', /dispatch logs could not be read/],
    ['ps', /process list could not be read/],
  ] as const) {
    test(`an ${command} that fails shows an error, never rows it cannot vouch for`, async ($, on) => {
      const { clock } = host(on, { logs: LOGS, ps: PS, failing: command })
      await open($, 'dev-team-runs', clock)
      const ui = await drawn($, 'dev-team-runs')
      expect(await ui.find({ type: 'Text', text: message })).toBeDefined()
      expect(await runRows(ui)).toEqual([])
      await ui.unmount()
    })
  }

  for (const exitCode of [0, 2]) {
    test(`a log deleted between the listing and the scan drops its run only (scan exit ${exitCode})`, async ($, on) => {
      const { h, clock } = host(on, { logs: LOGS.map(log => ({ ...log })), ps: PS })
      h.vanished = [{ name: 'holmes-99-20261008-120000.log', mtimeMs: 1000, tail: ['gone'] }]
      h.vanishedExit = exitCode
      await open($, 'dev-team-runs', clock)
      const ui = await drawn($, 'dev-team-runs')
      expect(await ui.find({ type: 'Text', text: /could not be read/ })).toBeUndefined()
      const rows = await runRows(ui)
      expect(rows.length).toBe(LOGS.length)
      expect(rows.some(row => row.includes('item 99'))).toBe(false)
      expect(rows[0]).toMatch(/^running watson item 42 /)
      await ui.unmount()
      // Once the listing drops it too, nothing is read again.
      h.vanished = []
      const scans = h.runs.filter(argv => argv[0] === 'awk').length
      await clock.advance(15_000)
      expect(h.runs.filter(argv => argv[0] === 'awk').length).toBe(scans)
    })
  }

  test('a scan that fails with no output shows an error', async ($, on) => {
    const { h, clock } = host(on, { ps: PS })
    h.vanished = [{ name: 'holmes-99-20261008-120000.log', mtimeMs: 1000 }]
    h.vanishedExit = 2
    await open($, 'dev-team-runs', clock)
    const ui = await drawn($, 'dev-team-runs')
    expect(await ui.find({ type: 'Text', text: /dispatch logs could not be read/ })).toBeDefined()
    await ui.unmount()
  })

  test('with HOME unset the pane says the logs cannot be found, and runs nothing', async ($, on) => {
    const { h, clock } = host(on, { home: false })
    await open($, 'dev-team-runs', clock)
    const ui = await drawn($, 'dev-team-runs')
    expect(await ui.find({ type: 'Text', text: /HOME is not set/ })).toBeDefined()
    expect(h.runs).toEqual([])
    await ui.unmount()
  })

  test('once the pane closes, the refreshes stop', async ($, on) => {
    const { h, clock } = host(on, { logs: LOGS, ps: PS })
    await open($, 'dev-team-runs', clock)
    const before = h.runs.length
    h.open.delete('dev-team-runs')
    await clock.advance(15_000)
    const queries = h.paneQueries
    await clock.advance(15 * 60_000)
    expect(h.runs.length).toBe(before)
    expect(h.paneQueries).toBe(queries)
  })
})

// ── The board pane: pure parts ───────────────────────────────────────────────

describe('board — the client\u2019s output', () => {
  test('a board keeps the named fields only, each of its own type', () => {
    const parsed = boardOf(
      JSON.stringify({
        lanes: {
          unrefined: { limit: 25, items: [{ id: 1, number: 2, isPr: false, repo: 'o/a', title: 't', claimedAt: null, access_token: SECRET, url: 'x' }] },
          review: { error: 'down' },
          development: { limit: 25, items: [] },
        },
        token: SECRET,
      }),
    )
    expect(parsed).toEqual({
      unrefined: { limit: 25, items: [{ id: 1, number: 2, isPr: false, repo: 'o/a', title: 't', claimedAt: null }] },
      review: { error: 'down' },
      development: { limit: 25, items: [] },
    })
    expect(JSON.stringify(parsed)).not.toContain(SECRET)
  })

  for (const [label, text] of [
    ['not JSON', 'minted a new Index token'],
    ['no lanes', '{}'],
    ['a missing lane', JSON.stringify({ lanes: { unrefined: { limit: 25, items: [] }, review: { limit: 25, items: [] } } })],
    ['an item with no id', JSON.stringify({ lanes: { unrefined: { limit: 25, items: [{ number: 1 }] }, review: { error: 'x' }, development: { error: 'x' } } })],
    ['a lane with no limit', JSON.stringify({ lanes: { unrefined: { items: [] }, review: { error: 'x' }, development: { error: 'x' } } })],
    ['an items list that is no list', JSON.stringify({ lanes: { unrefined: { limit: 25, items: {} }, review: { error: 'x' }, development: { error: 'x' } } })],
  ] as const) {
    test(`${label} is no board`, () => {
      expect(boardOf(text)).toBeUndefined()
    })
  }

  test('the outcome is the board, or the first stderr line, or what failed', () => {
    expect('board' in boardOutcome(GOOD_BOARD)).toBe(true)
    expect(boardOutcome({ exitCode: 1, stdout: '', stderr: 'an earlier notice\nThe Index could not be reached.\n\n' })).toEqual({
      error: 'The Index could not be reached.',
    })
    expect(boardOutcome({ exitCode: 3, stdout: '', stderr: '' })).toEqual({ error: 'the board client exited 3' })
    expect(boardOutcome({ exitCode: 0, stdout: 'nope', stderr: '' })).toEqual({ error: 'the board client printed something that is not a board' })
    expect(boardOutcome({ exitCode: 1, stdout: GOOD_BOARD.stdout, stderr: 'x' })).toEqual({ error: 'x' })
    expect(boardOutcome(undefined)).toEqual({ error: 'the board client could not run' })
  })

  test('the client is the tick script in board mode, from the plugin folder', () => {
    expect(boardArgv('/p')).toEqual(['bash', '/p/bin/dispatch-tick.sh', '--board'])
  })
})

describe('board — the cadence', () => {
  test('the cadence comes from the /config row, and a bad row reads as the default', () => {
    expect(cadenceMsOf(30)).toBe(30 * MINUTE)
    expect(cadenceMsOf(1)).toBe(MINUTE)
    for (const bad of [0, 0.5, -5, Number.NaN, Number.POSITIVE_INFINITY, '5', undefined, null]) expect(cadenceMsOf(bad)).toBe(20 * MINUTE)
  })

  test('a fetch is due when none was tried, or a whole cadence after the last try', () => {
    expect(isDue(EMPTY_BOARD, 5, 20 * MINUTE)).toBe(true)
    const tried: BoardView = { ...EMPTY_BOARD, attemptedAt: 1_000 }
    expect(isDue(tried, 1_000 + 20 * MINUTE - 1, 20 * MINUTE)).toBe(false)
    expect(isDue(tried, 1_000 + 20 * MINUTE, 20 * MINUTE)).toBe(true)
  })

  test('a failed fetch keeps the last board and its age, and counts as the attempt', () => {
    const board = boardOf(GOOD_BOARD.stdout) as Board
    const fetched = afterFetch({ ...EMPTY_BOARD, escalated: ['watson item 1'] }, 100, { board })
    expect(fetched).toEqual({ attemptedAt: 100, board, boardAt: 100, escalated: ['watson item 1'] })
    const failed = afterFetch(fetched, 200, { error: 'down' })
    expect(failed).toEqual({ attemptedAt: 200, board, boardAt: 100, error: 'down', escalated: ['watson item 1'] })
    expect(afterFetch(EMPTY_BOARD, 300, { error: 'down' })).toEqual({ attemptedAt: 300, error: 'down', escalated: [] })
  })

  test('escalated pairs read as agent and item', () => {
    expect(escalatedOf(['watson-42', 'holmes-7'])).toEqual(['watson item 42', 'holmes item 7'])
  })
})

// ── The board pane: the hooks ────────────────────────────────────────────────

const boardRuns = (h: Host) => h.runs.filter(argv => argv[2] === '--board')

describe('the board pane', () => {
  test('/dev-team-board fetches once through the tick\u2019s board mode, and draws the three lanes', async ($, on) => {
    const { h, clock } = host(on, { other: ['watson-42.escalated'] })
    const result = await open($, 'dev-team-board', clock)
    expect(result.text).toBe('The Index board pane opened.')
    expect(boardRuns(h).length).toBe(1)
    const [shell, script, flag] = boardRuns(h)[0] ?? []
    expect([shell, flag]).toEqual(['bash', '--board'])
    expect(script).toMatch(SCRIPT_IN_PLUGIN)
    const ui = await drawn($, 'dev-team-board')
    expect((await ui.find({ type: 'Box', key: 'lane-unrefined' }))?.text).toContain('Unrefined (Lestrade) 2')
    expect((await ui.find({ type: 'Box', key: 'lane-unrefined' }))?.text).toContain('#101 o/a  Item 101')
    expect((await ui.find({ type: 'Box', key: 'lane-review' }))?.text).toContain('Review (Holmes) 25+')
    expect((await ui.find({ type: 'Box', key: 'lane-development' }))?.text).toContain('Development (Watson) 2 · 1 claimed')
    expect((await ui.find({ type: 'Box', key: 'claimed' }))?.text).toContain('#301 o/a  since 2026-10-08T10:00:00+00:00')
    expect((await ui.find({ type: 'Box', key: 'escalated' }))?.text).toContain('watson item 42')
    expect((await ui.find({ type: 'Box', key: 'board-status' }))?.text).toMatch(/^Fetched \d\d:\d\d · next fetch after \d\d:\d\d$/)
    await ui.unmount()
  })

  test('it fetches no more often than the dispatch cadence', async ($, on) => {
    const { h, clock } = host(on)
    await open($, 'dev-team-board', clock)
    expect(boardRuns(h).length).toBe(1)
    await clock.advance(20 * MINUTE - 15_000)
    expect(boardRuns(h).length).toBe(1)
    await open($, 'dev-team-board', clock)
    expect(boardRuns(h).length).toBe(1)
    await clock.advance(15_000)
    expect(boardRuns(h).length).toBe(2)
    await clock.advance(19 * MINUTE)
    expect(boardRuns(h).length).toBe(2)
  })

  test('a longer cadence in /config spaces the fetches out', { options: { dispatchCadenceMinutes: 45 } }, async ($, on) => {
    const { h, clock } = host(on)
    await open($, 'dev-team-board', clock)
    await clock.advance(44 * MINUTE)
    expect(boardRuns(h).length).toBe(1)
    await clock.advance(MINUTE)
    expect(boardRuns(h).length).toBe(2)
  })

  test('a failed fetch counts against the cadence, and the pane says why', async ($, on) => {
    let calls = 0
    const { h, clock } = host(on, {
      board: () => (++calls === 2 ? { exitCode: 1, stdout: '', stderr: 'The Index could not be reached.' } : GOOD_BOARD),
    })
    await open($, 'dev-team-board', clock)
    await clock.advance(20 * MINUTE)
    expect(boardRuns(h).length).toBe(2)
    const ui = await drawn($, 'dev-team-board')
    expect((await ui.find({ type: 'Box', key: 'board-error' }))?.text).toBe('The last fetch failed: The Index could not be reached.')
    expect((await ui.find({ type: 'Box', key: 'lane-review' }))?.text).toContain('25+')
    await clock.advance(20 * MINUTE - 15_000)
    expect(boardRuns(h).length).toBe(2)
    await ui.unmount()
  })

  for (const reason of [
    'There is no valid cached Index token yet. The next Dispatch tick mints one.',
    'The Index refused the cached token (HTTP 401). The next Dispatch tick drops it and mints a new one.',
    'The Index could not be reached.',
    'jq is not on PATH, so the board cannot be fetched.',
    'The Index answered list_unrefined_items with HTTP 404. This router posts a bare tools/call with no initialize and no session, and expects a plain JSON reply.',
  ]) {
    test(`the pane shows the client's reason: ${reason.slice(0, 40)}`, async ($, on) => {
      const { clock } = host(on, { board: () => ({ exitCode: 1, stdout: '', stderr: `curl: a notice before it\n${reason}\n` }) })
      await open($, 'dev-team-board', clock)
      const ui = await drawn($, 'dev-team-board')
      expect((await ui.find({ type: 'Box', key: 'board-error' }))?.text).toBe(`The last fetch failed: ${reason}`)
      await ui.unmount()
    })
  }

  test('a lane whose tool failed says so, and the others still draw', async ($, on) => {
    const { clock } = host(on, {
      board: () => board({ unrefined: { limit: 25, items: [] }, review: { error: 'review lane down' }, development: { limit: 25, items: [] } }),
    })
    await open($, 'dev-team-board', clock)
    const ui = await drawn($, 'dev-team-board')
    expect((await ui.find({ type: 'Box', key: 'lane-review' }))?.text).toContain('could not list: review lane down')
    expect((await ui.find({ type: 'Box', key: 'lane-unrefined' }))?.text).toContain('Unrefined (Lestrade) 0')
    await ui.unmount()
  })

  test('a client that cannot run is an error, and still counts as the attempt', async ($, on) => {
    const { h, clock } = host(on, { board: () => new Error('ENOENT') })
    await open($, 'dev-team-board', clock)
    await clock.advance(15_000)
    expect(boardRuns(h).length).toBe(1)
    const ui = await drawn($, 'dev-team-board')
    expect((await ui.find({ type: 'Box', key: 'board-error' }))?.text).toContain('could not run')
    await ui.unmount()
  })

  test('a fetch still running holds back every other, past the cadence too', async ($, on) => {
    let finish: (answer: Answer) => void = () => undefined
    const { h, clock } = host(on, { board: () => new Promise<Answer>(resolve => (finish = resolve)) })
    void $.command.run(typed('dev-team-board'))
    await clock.advance(25 * MINUTE)
    expect(boardRuns(h).length).toBe(1)
    // The cadence counts from the start of the fetch, so the next one is due
    // at the first refresh after it ends.
    finish(GOOD_BOARD)
    await clock.settle()
    expect(boardRuns(h).length).toBe(1)
    await clock.advance(15_000)
    expect(boardRuns(h).length).toBe(2)
  })

  test('once the pane closes, no more fetches run', async ($, on) => {
    const { h, clock } = host(on)
    await open($, 'dev-team-board', clock)
    h.open.delete('dev-team-board')
    await clock.advance(60 * MINUTE)
    expect(boardRuns(h).length).toBe(1)
  })
})

// ── Neither pane writes, or shows a secret ───────────────────────────────────

describe('neither pane writes anything or exposes a secret', () => {
  test('both panes open and refresh for an hour with no write, no read of the token cache, and only their three commands', async ($, on) => {
    const { h, clock } = host(on, { logs: LOGS, ps: PS, other: ['watson-42.escalated'] })
    await open($, 'dev-team-runs', clock)
    await open($, 'dev-team-board', clock)
    await clock.advance(60 * MINUTE)
    expect(h.writes).toEqual([])
    expect(h.reads).toEqual([])
    expect(new Set(h.runs.map(argv => argv[0]))).toEqual(new Set(['awk', 'ps', 'bash']))
    for (const argv of h.runs) {
      if (argv[0] === 'bash') {
        expect(argv.length).toBe(3)
        expect(argv[1]).toMatch(SCRIPT_IN_PLUGIN)
        expect(argv[2]).toBe('--board')
      }
      if (argv[0] === 'ps') expect(argv).toEqual(['ps', '-axo', 'command='])
      if (argv[0] === 'awk') for (const path of argv.slice(3)) expect(path.startsWith(`${DIR}/`)).toBe(true)
      expect(argv.join(' ')).not.toContain(TOKEN_CACHE)
    }
    const ui = await drawn($, 'dev-team-runs')
    expect((await runRows(ui)).length).toBe(LOGS.length)
    await ui.unmount()
  })

  // The test engine has no state noun to read, so the state side is boardOf's
  // own test above: it keeps only the named fields.
  test('a token in the client\u2019s output never reaches the drawn pane', async ($, on) => {
    const leaky = {
      exitCode: 0,
      stdout: JSON.stringify({
        lanes: {
          unrefined: { limit: 25, items: [{ ...item(1, 1), access_token: SECRET }] },
          review: { limit: 25, items: [] },
          development: { limit: 25, items: [] },
        },
        access_token: SECRET,
      }),
      stderr: '',
    }
    const { clock } = host(on, { board: () => leaky })
    await open($, 'dev-team-board', clock)
    const ui = await drawn($, 'dev-team-board')
    expect((await ui.find({ type: 'Box', key: 'lane-unrefined' }))?.text).toContain('#1 o/a')
    for (const element of await ui.findAll({ type: 'Text' })) expect(element.text).not.toContain(SECRET)
    await ui.unmount()
  })

  test('another plugin\u2019s pane is drawn by its own hooks, not these', async ($, on) => {
    host(on)
    on('ui.render', async ($, e) => (e.requestId === 'other' ? ($.ui.resolve(e).Text({ children: 'theirs' }) as never) : (undefined as never)))
    const ui = await $.ui.mount({
      plugin: 'workbench-dev-team',
      surface: 'terminal',
      component: 'Pane',
      requestId: 'other',
      props: PANE_PROPS('other'),
    })
    expect((await ui.find({ type: 'Text' }))?.text).toBe('theirs')
    await ui.unmount()
  })
})
