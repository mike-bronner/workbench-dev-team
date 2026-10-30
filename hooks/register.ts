// workbench-dev-team's hooks module, beside the command hooks in hooks.json.
// It builds on workbench-core's $.workbench noun (dependencies in plugin.json).
//
// The logic is pure and lives in mods/. Every hook that touches `$` lives in
// this file, because the engine follows `$` into no imported function, and a
// plugin registers each event once.
//
// The scheduled path never reaches agent.spawn: it starts the mode type
// directly (`claude -p --agent workbench-dev-team:watson-index`), and
// bin/dispatch-agent.sh passes the rows' model and effort as flags. The
// other hooks run in that process too.
//
// The /config rows reach this module as its options. Claude Code reloads the
// module when one changes, so `register` runs again with the new values.

import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, Timer, TurnUsage } from 'claude-code'

import type { RunsView } from '../types'

import { BOARD_TIMEOUT_MS, EMPTY_BOARD, afterFetch, boardArgv, boardOutcome, cadenceMsOf, escalatedOf, isDue } from './mods/board'

import { budgetNotice, contextOf, isOverBudget } from './mods/budget'
import {
  DIGEST_MODE,
  DISPATCH_CONTEXT,
  digestArgv,
  digestNoticeOf,
  dispatchDeny,
  dispatcherArgv,
  dispatchOutcome,
  dispatchResult,
  indexDispatchOf,
  isForcedBackground,
} from './mods/dispatch'
import type { ModHook } from './mods/fallback'
import { markerOf, sweepArgvsOf, waitFileOf } from './mods/fallback'
import { outputOf, snapshotOf, stopBlockOf, withStarted } from './mods/helper-wait'
import type { Activity, Watch } from './mods/helper-wait'
import type { Disk, ShellParse } from './mods/review-guard'
import { isReviewerType, judgeWrites, refusalOf, reviewBash, reviewEdit } from './mods/review-guard'
import { BOARD_PANE, RUNS_PANE, boardTree, runsTree } from './mods/panes'
import type { LogEnd } from './mods/runs'
import { LOG_DIR, RUNS_REFRESH_MS, endsOf, livePairsOf, markersOf, newestRuns, rowsOf, scanArgv } from './mods/runs'
import { RULES, isRulesLane, isRulesSubagent, withRules } from './mods/session-rules'
import { hasBareMktemp, hasLiveChild, isDeletable, pointMktemp, prefixOf, readsAsPointed, rootOf, sweepOf } from './mods/scratch'
import type { CallerLane } from './mods/spawn'
import {
  CONFIG_MODES,
  DEFAULT_BRANCHES,
  branchDeny,
  branchUnreadDeny,
  configLineOf,
  configTextOf,
  familyOf,
  isDevTeamType,
  isGated,
  isHolmesMode,
  knobsOf,
  lensSpawnOf,
  modeTypeOf,
  spawnFailedDeny,
  withConfigLine,
  workdirOf,
} from './mods/spawn'

async function gated($: EngineInterface, agentId: string | undefined): Promise<boolean> {
  const lane = await $.workbench.callerLane(agentId === undefined ? {} : { agentId }).catch(() => 'main' as const)
  const isOn = await $.workbench.orchestratorIsOn().catch(() => true)
  return isGated(lane, isOn)
}

// ── Whose run a loop is ──────────────────────────────────────────────────────

// A dev-team run, as the per-run state keys it: its agent type, and its agentId,
// or `run` for the top-level loop of a `claude -p --agent` run. Undefined for
// the main session and for every agent outside the dev-team.
type Run = { type: string; key: string }

async function runOf($: EngineInterface, agentId: string | undefined): Promise<Run | undefined> {
  if (agentId !== undefined) {
    const { value: type } = await $.state.get({ plugin: 'workbench-dev-team', key: 'agentType', id: agentId })
    return isDevTeamType(type) && type !== undefined ? { type, key: agentId } : undefined
  }
  if ((await $.workbench.callerLane({})) !== 'top-level-agent') return undefined
  const type = await $.env.get('CLAUDE_CODE_AGENT')
  return isDevTeamType(type) && type !== undefined ? { type, key: 'run' } : undefined
}

// The type of the loop a spawn happens in: the top-level `--agent` type, or
// none, for a main-loop spawn; the type the mod kept, or the one
// $.agent.list() gives, for a sub-agent's. Undefined when it cannot be told.
async function spawnerTypeOf($: EngineInterface, parentAgentId: string | undefined): Promise<string | undefined> {
  if (parentAgentId === undefined) return $.env.get('CLAUDE_CODE_AGENT').catch(() => undefined)
  const { value: kept } = await $.state.get({ plugin: 'workbench-dev-team', key: 'agentType', id: parentAgentId })
  if (kept !== undefined) return kept
  const agents = await $.agent.list().catch(() => undefined)
  return agents?.find(agent => agent.id === parentAgentId)?.type
}

// ── Scratch folders ──────────────────────────────────────────────────────────

// The run's scratch folder: the one it has, or a new one under the first
// scratch root, made with mktemp. Undefined when none can be made.
async function scratchFolderOf($: EngineInterface, run: Run): Promise<string | undefined> {
  const { value: kept } = await $.state.get({ plugin: 'workbench-dev-team', key: 'scratch', id: run.key })
  if (kept && (await $.fs.exists(kept).catch(() => false))) return kept
  const roots = await $.workbench.scratchRoots()
  const root = rootOf(roots)
  if (root === undefined) return undefined
  const made = await $.process.run(['mktemp', '-d', `${root}/${prefixOf(run.type)}.XXXXXX`])
  const folder = made.stdout.trim()
  if (made.exitCode !== 0 || !isDeletable(folder, roots)) return undefined
  await $.state.set({ plugin: 'workbench-dev-team', key: 'scratch', id: run.key }, folder)
  await recordFolder($, [folder], 'add')
  return folder
}

const FOLDERS = { plugin: 'workbench-dev-team', key: 'scratchFolders' } as const

// Adds folders to the record, or takes them out. Two runs can write at once,
// so the write lands only on the version it read, and is tried again when
// another write came first.
async function recordFolder($: EngineInterface, folders: readonly string[], change: 'add' | 'remove'): Promise<void> {
  for (let attempt = 0; attempt < 8; attempt++) {
    const { value = [], version } = await $.state.get(FOLDERS)
    const rest = value.filter(kept => !folders.includes(kept))
    if ((await $.state.set(FOLDERS, change === 'add' ? [...rest, ...folders] : rest, { ifVersion: version })).isSet) return
  }
}

// The end of the session: every folder still recorded is deleted, in one rm,
// when it lies under a scratch root. Each was kept because its run had not
// ended, or a child of its run was live at the run's last turn, and nothing is
// live once the session ends.
// The rm is held to what the end's one short budget leaves, and skipped when
// too little is left. A folder outside every root is never deleted. Only what
// an rm that exited 0 deleted leaves the record: a folder the rm skipped, or
// one an rm that failed or ran out of time may have left, stays recorded.
async function endSession($: EngineInterface, budget: { remainingMs: number }): Promise<void> {
  const { value: folders = [] } = await $.state.get(FOLDERS)
  if (folders.length === 0) return
  const sweep = sweepOf(folders, await $.workbench.scratchRoots(), budget.remainingMs)
  if (sweep === undefined) return
  const removed = await $.process.run(['rm', '-rf', '--', ...sweep.doomed], { timeoutMs: sweep.timeoutMs }).catch(() => undefined)
  if (removed?.exitCode === 0) await recordFolder($, sweep.doomed, 'remove')
}

// The Bash line with a dev-team agent's bare mktemp pointed at its folder, or
// the line as written when it has none, or when anything here fails: a mktemp
// left in $TMPDIR is how the line ran before the mod.
async function withScratch($: EngineInterface, agentId: string | undefined, line: string): Promise<string> {
  if (!line.includes('mktemp')) return line
  try {
    const before = await $.workbench.parseShell(line)
    if (!hasBareMktemp(before)) return line
    const run = await runOf($, agentId)
    if (run === undefined) return line
    const folder = await scratchFolderOf($, run)
    if (folder === undefined) return line
    const pointed = pointMktemp(line, folder)
    if (pointed === undefined) return line
    return readsAsPointed(before, await $.workbench.parseShell(pointed), folder) ? pointed : line
  } catch {
    return line
  }
}

// The end of a turn: the run's scratch folder deleted, unless a child the run
// spawned is still live, and its budget notice reset. A child's end never
// deletes its parent's folder: an ended agent may resume, as Holmes does when
// his background helpers report, and read it again. A folder kept for a live
// child goes at the end of the next turn that finds none. When the agent list
// cannot be read, the folder stays.
async function endRun($: EngineInterface, agentId: string | undefined): Promise<void> {
  const key = agentId ?? ((await $.workbench.callerLane({})) === 'top-level-agent' ? 'run' : undefined)
  if (key === undefined) return
  const { value: folder } = await $.state.get({ plugin: 'workbench-dev-team', key: 'scratch', id: key })
  const agents = folder ? await $.agent.list().catch(() => undefined) : undefined
  if (folder && agents !== undefined && !hasLiveChild(agents, agentId)) {
    if (isDeletable(folder, await $.workbench.scratchRoots())) await $.process.run(['rm', '-rf', '--', folder])
    await $.state.set({ plugin: 'workbench-dev-team', key: 'scratch', id: key }, '')
    await recordFolder($, [folder], 'remove')
  }
  const { value: told } = await $.state.get({ plugin: 'workbench-dev-team', key: 'overBudget', id: key })
  if (told) await $.state.set({ plugin: 'workbench-dev-team', key: 'overBudget', id: key }, false)
}

async function recordStarted($: EngineInterface, agentId: string | undefined, result: { result?: unknown; text?: unknown }): Promise<void> {
  const id = (result.result as { backgroundTaskId?: unknown } | undefined)?.backgroundTaskId
  if (agentId === undefined || typeof id !== 'string' || id === '') return
  const key = { plugin: 'workbench-dev-team', key: 'backgroundTasks', id: agentId } as const
  for (let attempt = 0; attempt < 8; attempt++) {
    const { value = [], version } = await $.state.get(key)
    const output = outputOf(id, result.text)
    if ((await $.state.set(key, withStarted(value, output === undefined ? { id } : { id, output }), { ifVersion: version })).isSet) return
  }
}

async function waitInputsOf($: EngineInterface, agentId: string) {
  const { value: type } = await $.state.get({ plugin: 'workbench-dev-team', key: 'agentType', id: agentId })
  if (!isDevTeamType(type)) return undefined
  const { value: started = [] } = await $.state.get({ plugin: 'workbench-dev-team', key: 'backgroundTasks', id: agentId })
  const agents = await $.agent.list().catch(() => [])
  return { started, agents }
}

async function stopBlock(
  $: EngineInterface,
  agentId: string,
  inFlight: readonly { id: string; command?: string; description: string }[],
  activity: ReadonlyMap<string, Activity>,
  watches: Map<string, Watch>,
): Promise<string | undefined> {
  const inputs = await waitInputsOf($, agentId)
  if (inputs === undefined) return undefined
  const { started, agents } = inputs
  const sizes = new Map<string, number>()
  for (const entry of started) {
    if (entry.output === undefined || !inFlight.some(task => task.id === entry.id)) continue
    const size = await $.fs.stat(entry.output).then(stat => stat.size, () => undefined)
    if (size !== undefined) sizes.set(entry.output, size)
  }
  return stopBlockOf(agentId, agents, started, inFlight, { helper: id => activity.get(id), outputSize: path => sizes.get(path) }, watches)
}

type Seat = { sessionId?: string }

async function markModRan($: EngineInterface, seat: Seat, sessionId: string, hook: ModHook): Promise<void> {
  const file = markerOf(await $.env.get('HOME').catch(() => undefined), sessionId, hook)
  if (file === undefined) return
  const isWritten = await $.fs.write(file, '').then(
    () => true,
    () => false,
  )
  if (isWritten) seat.sessionId = sessionId
}

async function recordWait($: EngineInterface, seat: Seat, agentId: string, activity: ReadonlyMap<string, Activity>): Promise<void> {
  const sessionId = await $.session.id()
  if (seat.sessionId === sessionId) return
  const inputs = await waitInputsOf($, agentId)
  if (inputs === undefined) return
  const file = waitFileOf(await $.env.get('HOME'), sessionId, agentId, 'snapshot')
  if (file !== undefined) await $.fs.write(file, JSON.stringify(snapshotOf(agentId, inputs.agents, inputs.started, id => activity.get(id))))
}

async function sweepFallbackFiles($: EngineInterface): Promise<void> {
  for (const argv of sweepArgvsOf(await $.env.get('HOME'))) await $.process.run(argv, { timeoutMs: 10_000 }).catch(() => undefined)
}

// ── The context budget ───────────────────────────────────────────────────────

async function measure($: EngineInterface, agentId: string | undefined, usage: TurnUsage | null): Promise<void> {
  const tokens = contextOf(usage)
  if (!isOverBudget(tokens) || tokens === undefined) return
  const run = await runOf($, agentId)
  if (run === undefined) return
  const { value: told } = await $.state.get({ plugin: 'workbench-dev-team', key: 'overBudget', id: run.key })
  if (told) return
  await $.state.set({ plugin: 'workbench-dev-team', key: 'overBudget', id: run.key }, true)
  const notice = budgetNotice(run.type, run.key, tokens)
  $.ui.toast(notice, { timeoutMs: 15000 })
  $.ui.log(notice, { to: 'transcript' })
}

// ── The Index dispatcher ─────────────────────────────────────────────────────

// The Agent call's answer for a Watson Index-mode dispatch: the dispatcher's
// first line, or a refusal. It never falls through to a spawn, which would
// start a run without its pipeline flag.
async function runDispatcher($: EngineInterface, itemId: string, prompt: string) {
  const home = await $.env.get('HOME').catch(() => undefined)
  if (!home) return { deny: dispatchDeny('HOME is not set, so the dispatcher cannot be found') }
  const run = await $.process.run(dispatcherArgv(home, itemId), { timeoutMs: 120_000 }).catch(() => undefined)
  if (run === undefined) return { deny: dispatchDeny('the dispatcher could not run') }
  const outcome = dispatchOutcome(run)
  if ('deny' in outcome) return outcome
  return { result: dispatchResult(outcome.line, prompt), context: [DISPATCH_CONTEXT] }
}

async function withDigestNotice($: EngineInterface, prompt: string): Promise<string> {
  const home = await $.env.get('HOME').catch(() => undefined)
  const run = home ? await $.process.run(digestArgv($.plugin.root), { timeoutMs: 30_000 }).catch(() => undefined) : undefined
  const notice = digestNoticeOf(run)
  return notice === undefined ? prompt : `${prompt.replace(/\s+$/u, '')}\n\n${notice}`
}

// ── The guards ───────────────────────────────────────────────────────────────

const GUARDED: ReadonlySet<string> = new Set(['Bash', 'Edit', 'Write', 'NotebookEdit'])

const GUARD_FAILED =
  '🛑 Blocked: a call the review guard could not judge.\n\nworkbench-dev-team. The review guard failed while reading this call, so it is refused rather than let an unread write through. Report this to the human as a guard defect. Do not try another spelling.'

// The input fields the guards read. The engine types them per tool; these are
// read as unknown, so a field of the wrong type is judged as absent.
type GuardInput = { tool: string; agentId?: string; command?: unknown; file_path?: unknown; notebook_path?: unknown }

// Whether a call comes from a Holmes reviewer, or from anything a reviewer
// spawned: true, false, or undefined when it cannot be told. A top-level
// `--agent` run names its type in CLAUDE_CODE_AGENT, and every loop in it is
// held. A sub-agent's type, and its parents', come from $.agent.list().
async function isReviewer($: EngineInterface, agentId: string | undefined, lane: CallerLane | undefined): Promise<boolean | undefined> {
  if (isReviewerType(await $.env.get('CLAUDE_CODE_AGENT').catch(() => undefined))) return true
  if (lane === 'main' || lane === 'top-level-agent') return false
  if (lane === undefined || agentId === undefined) return undefined
  const agents = await $.agent.list().catch(() => undefined)
  if (agents === undefined) return undefined
  const seen = new Set<string>()
  for (let id: string | undefined = agentId; id !== undefined && !seen.has(id); ) {
    seen.add(id)
    const agent = agents.find(a => a.id === id)
    if (agent === undefined) return undefined
    if (isReviewerType(agent.type)) return true
    id = agent.parentId
  }
  return false
}

// The scratch roots: core's, and $TMPDIR, each a physical directory.
async function scratchRootsOf($: EngineInterface): Promise<string[]> {
  const roots = [...(await $.workbench.scratchRoots().catch(() => []))]
  const tmp = await $.env.get('TMPDIR').catch(() => undefined)
  const real = tmp ? (await $.fs.stat(tmp, { resolve: true }).catch(() => undefined))?.realPath : undefined
  if (real !== undefined && (await $.fs.stat(real).catch(() => undefined))?.kind === 'dir') roots.push(real)
  return roots
}

// The review guard's refusal for a reviewer's call, or undefined.
async function reviewDeny($: EngineInterface, e: GuardInput, parse: ShellParse | undefined): Promise<string | undefined> {
  const cwd = await $.session.cwd().catch(() => undefined)
  const context = { cwd, home: await $.env.get('HOME').catch(() => undefined) }
  let verdict
  if (e.tool === 'Bash') {
    if (parse === undefined) return undefined
    verdict = reviewBash(parse, context)
  } else {
    const raw = e.tool === 'NotebookEdit' ? e.notebook_path : e.file_path
    verdict = reviewEdit(e.tool, typeof raw === 'string' ? raw : '', context)
  }
  const roots = await scratchRootsOf($)
  if ('finding' in verdict) return refusalOf(verdict.finding, roots)
  const disk: Disk = {
    stat: path => $.fs.stat(path, { resolve: true }).then(stat => ({ realPath: stat.realPath }), () => undefined),
    names: dir => $.fs.list(dir).then(entries => entries.map(entry => entry.name), () => undefined),
  }
  const finding = await judgeWrites(verdict.writes, roots, disk)
  return finding === undefined ? undefined : refusalOf(finding, roots)
}

async function guard($: EngineInterface, e: GuardInput): Promise<string | undefined> {
  const lane = await $.workbench.callerLane(e.agentId === undefined ? {} : { agentId: e.agentId }).catch(() => undefined)
  const reviewer = await isReviewer($, e.agentId, lane)
  if (reviewer === false) return undefined
  const parse = e.tool === 'Bash' ? await $.workbench.parseShell(typeof e.command === 'string' ? e.command : '') : undefined
  const deny = await reviewDeny($, e, parse)
  if (deny === undefined || reviewer) return deny
  return `${deny}\n\nThe guard could not tell which agent made this call, so it held the call to the reviewer's rule. Report this to the human as a guard defect.`
}

// ── The panes ────────────────────────────────────────────────────────────────

const RUNS_COMMAND = 'dev-team-runs'
const BOARD_COMMAND = 'dev-team-board'
const PANE_TITLE = { [RUNS_PANE]: 'Dev-team runs', [BOARD_PANE]: 'The Index board' } as const

const runsAtom = atom({ plugin: 'workbench-dev-team', key: 'runs' } as const, { rows: [] } as RunsView)
const boardAtom = atom({ plugin: 'workbench-dev-team', key: 'board' } as const, EMPTY_BOARD)

// What the panes keep between refreshes in one load of the module: each read
// log's end by name, with the size and mtime it was read at, whether a refresh
// of each pane is under way, and the refresh timer.
type PaneMemory = { ends: Map<string, { stamp: string; end: LogEnd }>; isRunsBusy: boolean; isBoardBusy: boolean; timer?: Timer }

async function logDirOf($: EngineInterface): Promise<string | undefined> {
  const home = await $.env.get('HOME').catch(() => undefined)
  return home ? `${home}/${LOG_DIR}` : undefined
}

const stampOf = (run: { mtimeMs: number; size: number }): string => `${run.mtimeMs}:${run.size}`
const NO_END: LogEnd = { tail: [], refusals: 0 }

// The runs view from the newest logs. Only a log whose size or mtime changed
// since its last read is read again.
async function readRuns($: EngineInterface, memory: PaneMemory): Promise<RunsView> {
  const dir = await logDirOf($)
  if (dir === undefined) return { rows: [], error: 'HOME is not set, so the dispatch logs cannot be found.' }
  const entries = await $.fs.list(dir).catch(() => undefined)
  if (entries === undefined) return { rows: [], error: `There is no dispatch log folder at ${dir}.` }
  const runs = newestRuns(entries)
  if (runs.length === 0) return { rows: [] }
  const changed = runs.filter(run => memory.ends.get(run.name)?.stamp !== stampOf(run))
  if (changed.length > 0) {
    const scan = await $.process.run(scanArgv($.plugin.root, changed.map(run => `${dir}/${run.name}`)), { timeoutMs: 20_000 }).catch(() => undefined)
    // The scan skips a log it cannot open, so a non-zero exit with output is
    // still the ends of the logs it read. No output and a failure is no read.
    if (scan === undefined || (scan.exitCode !== 0 && scan.stdout === '')) return { rows: [], error: 'The dispatch logs could not be read.' }
    const scanned = endsOf(scan.stdout)
    for (const run of changed) {
      const end = scanned.get(`${dir}/${run.name}`)
      if (end === undefined) memory.ends.delete(run.name)
      else memory.ends.set(run.name, { stamp: stampOf(run), end })
    }
  }
  // A changed log the scan could not open was deleted since the listing: its
  // run leaves the pane, and the others stay.
  const read = runs.filter(run => memory.ends.get(run.name)?.stamp === stampOf(run))
  for (const name of memory.ends.keys()) if (!read.some(run => run.name === name)) memory.ends.delete(name)
  const ps = await $.process.run(['ps', '-axo', 'command='], { timeoutMs: 10_000 }).catch(() => undefined)
  if (ps === undefined || ps.exitCode !== 0) return { rows: [], error: 'The process list could not be read, so which runs are live is unknown.' }
  const ends = new Map(read.map(run => [`${dir}/${run.name}`, memory.ends.get(run.name)?.end ?? NO_END]))
  return { rows: rowsOf(dir, read, ends, livePairsOf(ps.stdout), markersOf(entries)) }
}

async function refreshRuns($: EngineInterface, memory: PaneMemory): Promise<void> {
  if (memory.isRunsBusy) return
  memory.isRunsBusy = true
  try {
    const view = await readRuns($, memory)
    await update($, runsAtom, () => view)
  } finally {
    memory.isRunsBusy = false
  }
}

// The escalated items, read from the log folder on every refresh, and the
// board from The Index when the cadence allows. The attempt is recorded before
// the client runs, so no later refresh, and no reload, starts a second one
// inside the cadence.
async function refreshBoard($: EngineInterface, memory: PaneMemory, cadenceMs: number): Promise<void> {
  const dir = await logDirOf($)
  const entries = dir === undefined ? [] : await $.fs.list(dir).catch(() => [])
  const escalated = escalatedOf(markersOf(entries))
  await update($, boardAtom, view => ({ ...view, escalated }))
  if (memory.isBoardBusy) return
  const now = await $.clock.now()
  if (!isDue(await read($, boardAtom), now, cadenceMs)) return
  memory.isBoardBusy = true
  try {
    await update($, boardAtom, view => ({ ...view, attemptedAt: now }))
    const run = await $.process.run(boardArgv($.plugin.root), { timeoutMs: BOARD_TIMEOUT_MS }).catch(() => undefined)
    const outcome = boardOutcome(run)
    await update($, boardAtom, view => afterFetch(view, now, outcome))
  } finally {
    memory.isBoardBusy = false
  }
}

// One refresh of every open pane. With none open, the timer stops.
async function refreshPanes($: EngineInterface, memory: PaneMemory, cadenceMs: number): Promise<void> {
  const open = new Set((await $.ui.panes()).map(pane => pane.id))
  if (!open.has(RUNS_PANE) && !open.has(BOARD_PANE)) {
    memory.timer?.cancel()
    memory.timer = undefined
    return
  }
  await Promise.all([open.has(RUNS_PANE) ? refreshRuns($, memory) : undefined, open.has(BOARD_PANE) ? refreshBoard($, memory, cadenceMs) : undefined])
}

function startRefresh($: EngineInterface, memory: PaneMemory, cadenceMs: number): void {
  memory.timer ??= $.clock.every(RUNS_REFRESH_MS, () => void refreshPanes($, memory, cadenceMs).catch(() => undefined))
}

// Whether this session gets the dev-team rules (mods/session-rules.ts). An
// environment that cannot be read sends them: losing the rules is the worse
// failure, as workbench-core rules for its own.
async function isRulesSession($: EngineInterface): Promise<boolean> {
  return $.env.get('WORKBENCH_SKIP_WARMUP').then(isRulesLane, () => true)
}

export const register: Register = (on, options) => {
  // The rows, read once: the options are fixed for this activation.
  const config = configTextOf(options)

  // The panes. Neither one writes: see refreshRuns and refreshBoard.
  const cadenceMs = cadenceMsOf(options.dispatchCadenceMinutes)
  const memory: PaneMemory = { ends: new Map(), isRunsBusy: false, isBoardBusy: false }

  const activity = new Map<string, Activity>()
  const watches = new Map<string, Watch>()
  const begin = (agentId: string | undefined): (() => void) => {
    if (agentId === undefined) return () => undefined
    const seen = activity.get(agentId) ?? { ticks: 0, inFlight: 0 }
    activity.set(agentId, seen)
    seen.ticks++
    seen.inFlight++
    return () => {
      seen.inFlight--
    }
  }

  const seat: Seat = {}

  on('session.start', async ($, e, next) => {
    void sweepFallbackFiles($).catch(() => undefined)
    await $.command.register({ name: RUNS_COMMAND, description: 'Show live and recent dev-team runs from the dispatch logs', immediate: true }).catch(() => undefined)
    await $.command.register({ name: BOARD_COMMAND, description: "Show The Index board's lanes, fetched once per dispatch cadence at most", immediate: true }).catch(() => undefined)
    const open = await $.ui.panes().catch(() => [])
    if (open.some(pane => pane.id === RUNS_PANE || pane.id === BOARD_PANE)) startRefresh($, memory, cadenceMs)
    return next(e)
  })

  on('classic.SessionStart', async ($, e, next) => {
    await markModRan($, seat, e.session_id, 'session-start')
    return next(e)
  })

  on('command.run', async ($, e, next) => {
    const pane = e.command === RUNS_COMMAND ? RUNS_PANE : e.command === BOARD_COMMAND ? BOARD_PANE : undefined
    if (pane === undefined) return next(e)
    await $.ui.open({ id: pane, title: PANE_TITLE[pane] })
    startRefresh($, memory, cadenceMs)
    void refreshPanes($, memory, cadenceMs).catch(() => undefined)
    return { text: `${PANE_TITLE[pane]} pane opened.` }
  }).catch(($, e, next) => (e.command === RUNS_COMMAND || e.command === BOARD_COMMAND ? { text: 'The dev-team pane could not open. Try the command again.' } : next(e)))

  on('ui.render', { component: 'Pane' }, async ($, e, next) => {
    if (e.requestId === RUNS_PANE) return runsTree($.ui.resolve(e), await read($, runsAtom), e.props.scroll.bodyRows)
    if (e.requestId === BOARD_PANE) return boardTree($.ui.resolve(e), await read($, boardAtom), cadenceMs)
    return next(e)
  })

  on('agent.spawn', async ($, e, next) => {
    // Only the model's own Agent calls are judged, the ones core's gate sees.
    // A plugin's $.agent.spawn is the plugin's implementation, not a handoff.
    const isModel = next.origin.plugin === 'engine'
    const isGatedCall = isModel && (await gated($, e.parentAgentId))

    // The helper rule. A spawner the mod cannot name is let through: the
    // review guard still holds every write by anything Holmes spawned.
    let input = e
    if (isModel && isHolmesMode(await spawnerTypeOf($, e.parentAgentId))) {
      const lens = lensSpawnOf(e)
      if ('deny' in lens) return lens
      input = { ...e, subagentType: lens.subagentType }
    }

    // The workspace check. git answering with no branch (not a repository, or
    // a detached HEAD) passes; git that cannot run at all refuses, since the
    // answer is then unknown, and recording a branch in Workdir: passes.
    if (isGatedCall && familyOf(input.subagentType) === 'watson' && modeTypeOf('watson', input.prompt).endsWith(':watson-direct')) {
      const workdir = workdirOf(input.prompt)
      if (workdir !== undefined && !workdir.isRecorded && workdir.path.startsWith('/')) {
        const head = await $.process
          .run(['git', '-C', workdir.path, 'symbolic-ref', '--quiet', '--short', 'HEAD'], { timeoutMs: 10_000 })
          .catch(() => undefined)
        if (head === undefined) return { deny: branchUnreadDeny(workdir.path) }
        const branch = head.stdout.trim()
        if (head.exitCode === 0 && DEFAULT_BRANCHES.includes(branch)) return { deny: branchDeny(workdir.path, branch) }
      }
    }

    // Nothing in this block calls next, so a failure here passes the dispatch
    // on unchanged, and next is called once either way.
    let routed: typeof e | undefined
    let knobs: ReturnType<typeof knobsOf> = {}
    try {
      const family = familyOf(input.subagentType)
      if (family !== undefined) {
        knobs = knobsOf(config, family)
        const subagentType = modeTypeOf(family, input.prompt)
        const configFamily = CONFIG_MODES[subagentType]
        const prompt = configFamily === undefined ? input.prompt : withConfigLine(input.prompt, configLineOf(config, configFamily))
        // A model the caller named is the caller's choice, and stands.
        const model = input.model ?? knobs.model
        routed = { ...input, subagentType, prompt, ...(model === undefined ? {} : { model }) }
      }
    } catch {
      routed = undefined
    }
    if (routed?.subagentType === DIGEST_MODE) routed = { ...routed, prompt: await withDigestNotice($, routed.prompt) }
    const spawned = routed ?? input
    const result = await next(spawned)
    if (result.agentId !== undefined) {
      if (routed !== undefined && knobs.effort !== undefined) {
        await $.state.set({ plugin: 'workbench-dev-team', key: 'effort', id: result.agentId }, knobs.effort)
      }
      if (isDevTeamType(spawned.subagentType)) {
        await $.state.set({ plugin: 'workbench-dev-team', key: 'agentType', id: result.agentId }, spawned.subagentType)
      }
    }
    return result
  }).catch(($, e, next) => (next.called ? next(e) : { deny: spawnFailedDeny() }))

  // The dev-team session rules: a shared section in the main loop's system
  // prompt, and context at a sub-agent's start.
  on('prompt.compose', async ($, e, next) => {
    const sessionId = await $.session.id().catch(() => undefined)
    if (sessionId !== undefined && seat.sessionId !== sessionId) await markModRan($, seat, sessionId, 'prompt-compose')
    const result = await next(e)
    return (await isRulesSession($)) ? { sections: withRules(result.sections) } : result
  })

  on('classic.SubagentStart', async ($, e, next) => {
    await markModRan($, seat, e.session_id, 'subagent-start')
    const result = await next(e)
    if (!isRulesSubagent(e.agent_type) || !(await isRulesSession($))) return result
    return { ...result, additionalContext: [...(result.additionalContext ?? []), RULES] }
  })

  // The config line for a top-level run of a mode that reads it. Nothing here
  // calls next, so a failure leaves the prompt as it came.
  on('prompt.submit', async ($, e, next) => {
    let line: string | undefined
    try {
      if ((await $.workbench.callerLane({})) === 'top-level-agent') {
        const family = CONFIG_MODES[(await $.env.get('CLAUDE_CODE_AGENT')) ?? '']
        if (family !== undefined) line = configLineOf(config, family)
      }
    } catch {
      line = undefined
    }
    return next(line === undefined ? e : { ...e, context: [...(e.context ?? []), line] })
  })

  on('turn.step', async function* ($, e, next) {
    const done = begin(e.agentId)
    try {
      let input = e
      if (e.agentId !== undefined) {
        const { value: effort } = await $.state.get({ plugin: 'workbench-dev-team', key: 'effort', id: e.agentId })
        if (effort !== undefined) input = { ...e, effort }
      }
      const result = yield* next(input)
      await measure($, e.agentId, result.usage).catch(() => undefined)
      if (e.agentId !== undefined) await recordWait($, seat, e.agentId, activity).catch(() => undefined)
      return result
    } finally {
      done()
    }
  })

  on('classic.SubagentStop', async ($, e, next) => {
    await markModRan($, seat, e.session_id, 'subagent-stop')
    const result = await next(e)
    if (result.block !== undefined) return result
    const block = await stopBlock($, e.agent_id, e.background_tasks ?? [], activity, watches)
    return block === undefined ? result : { ...result, block }
  })

  on('turn.complete', async ($, e, next) => {
    const result = await next(e)
    await endRun($, e.agentId).catch(() => undefined)
    return result
  })

  // The sweep runs before the engine's own end step, and its failure leaves
  // the folders where they are rather than holding the exit up.
  on('session.end', async ($, e, next) => {
    await endSession($, next.budget).catch(() => undefined)
    return next(e)
  })

  on('tool.call', async ($, e, next) => {
    const done = begin(e.agentId)
    try {
      if (e.tool === 'Bash' || e.tool === 'Edit' || e.tool === 'Write' || e.tool === 'NotebookEdit') {
        const call = e.tool === 'Bash' && typeof e.command === 'string' ? { ...e, command: await withScratch($, e.agentId, e.command) } : e
        const deny = await guard($, call)
        if (deny !== undefined) return { deny }
        const result = await next(call)
        if (e.tool === 'Bash') await recordStarted($, e.agentId, result).catch(() => undefined)
        return result
      }
      if (e.tool !== 'Agent') return next(e)
      const isModel = next.origin.plugin === 'engine'
      let call = e
      if (isModel) {
        // A set agentId is a sub-agent's call, whatever callerLane says, so a
        // sub-agent never reaches the dispatcher. Only a call with no agentId
        // asks the lane, and a lookup that fails there reads as the main session.
        const isMain = e.agentId === undefined && (await $.workbench.callerLane({}).catch(() => 'main' as const)) === 'main'
        if (isMain) {
          const itemId = indexDispatchOf(e.subagent_type, e.prompt)
          if (itemId !== undefined) return runDispatcher($, itemId, e.prompt)
          if (isForcedBackground(e.subagent_type, e.run_in_background)) call = { ...e, run_in_background: true }
        }
      }
      return await next(call)
    } finally {
      done()
    }
  }).catch(($, e, next) => (next.called || !GUARDED.has(e.tool) ? next(e) : { deny: GUARD_FAILED }))
}
