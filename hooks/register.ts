// workbench-dev-team's hooks module, beside the command hooks in hooks.json.
// It builds on workbench-core's $.workbench noun (dependencies in plugin.json).
//
//   agent.spawn    one dispatch of an agent, in order:
//                  1. the dispatch gate: a main-session dispatch whose brief
//                     lacks a slot is refused, as hooks/agent-dispatch-gate.sh
//                     in workbench-core refuses it, and so is one whose brief
//                     cannot be checked
//                  2. the helper rule: a spawn Holmes makes, in any mode, runs
//                     on holmes-lens whatever type it named, and a fork or a
//                     teammate of his is refused
//                  3. the workspace check: a gated Watson Direct-mode brief
//                     whose Workdir: is a bare path, on a repo on main, master
//                     or trunk, is refused with an ask-for-a-branch reason
//                  4. routing: a dispatch of watson, holmes or lestrade runs the
//                     mode agent its token picks (bin/compose-agents.sh builds
//                     them), so the public names keep working
//                  5. model and effort from the plugin's /config rows (its
//                     options), and for holmes-local, holmes-index and
//                     lestrade-item the config line (fanout, lensModel) added
//                     to the prompt
//                  Each dev-team agent's type is kept by its agentId.
//   prompt.submit  the config line, as context, for the top-level loop of a
//                  `claude -p --agent` run of those three modes: the run
//                  bin/dispatch-agent.sh starts raises no agent.spawn
//   turn.step      applies the effort step 5 recorded, to that sub-agent's
//                  loop, and measures each dev-team request's working context
//                  against the budget, notifying the human once per run
//   turn.complete  deletes the run's scratch folder unless a child it spawned is
//                  still live, and resets its budget notice
//   session.end    deletes every scratch folder the mod still records, within
//                  the end's short time budget: a run whose last turn ended
//                  with a live child, and was never resumed, left one
//   session.start  registers /dev-team-runs and /dev-team-board, and restarts
//                  the panes' refresh timer when a reload finds a pane open
//   command.run    those two commands open their pane (mods/panes.tsx)
//   ui.render      draws the two panes, each read-only:
//                  - runs: the newest dispatch logs (mods/runs.ts), read again
//                    every 15 s while the pane is open
//                  - board: The Index's three lanes from bin/dispatch-tick.sh
//                    --board (mods/board.ts), fetched when the pane opens and
//                    then once per dispatch cadence at most, and the items the
//                    breaker escalated, from the log folder
//   tool.call      on Bash, Edit, Write and NotebookEdit, before the call:
//                  1. scratch: a dev-team agent's bare mktemp is pointed at a
//                     folder of its own under a scratch root (mods/scratch.ts)
//                  2. the commit guard (mods/commit-guard.ts), on every Bash
//                     line in every lane: a forced or deleting push, a merge by
//                     an agent or the pipeline, a sub-agent's commit or push,
//                     and a commit, push or merge the ask rules cannot see
//                  3. the commit subject check (mods/commit-subject.ts) on
//                     every commit the guard lets through
//                  4. the review guard (mods/review-guard.ts): a Holmes
//                     reviewer, or anything he spawned, writes only in scratch
//                  The guards read the line through $.workbench.parseShell,
//                  take the lane from $.workbench.callerLane and isUnattended,
//                  and refuse the call when they throw.
//                  On Agent, from the main session (mods/dispatch.ts): a Watson
//                  `Item ID: <n>` call runs bin/dispatch-agent.sh in its place
//                  and answers with the dispatcher's first line, and a dev-team
//                  call that did not ask for the foreground runs in the
//                  background. After the call ran: the gate's advisory hint on
//                  a complete brief that dictates method.
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
import { commitVerdict } from './mods/commit-guard'
import type { ShellParse } from './mods/commit-guard'
import { subjectVerdict } from './mods/commit-subject'
import { DISPATCH_CONTEXT, dispatchDeny, dispatcherArgv, dispatchOutcome, dispatchResult, indexDispatchOf, isForcedBackground } from './mods/dispatch'
import type { Disk } from './mods/review-guard'
import { isReviewerType, judgeWrites, refusalOf, reviewBash, reviewEdit } from './mods/review-guard'
import { BOARD_PANE, RUNS_PANE, boardTree, runsTree } from './mods/panes'
import type { LogEnd } from './mods/runs'
import { LOG_DIR, RUNS_REFRESH_MS, endsOf, livePairsOf, markersOf, newestRuns, rowsOf, scanArgv } from './mods/runs'
import { hasBareMktemp, hasLiveChild, isDeletable, pointMktemp, prefixOf, readsAsPointed, rootOf, sweepOf } from './mods/scratch'
import type { CallerLane } from './mods/spawn'
import {
  CONFIG_MODES,
  DEFAULT_BRANCHES,
  branchDeny,
  branchUnreadDeny,
  configLineOf,
  configTextOf,
  denyOf,
  familyOf,
  hintOf,
  isDevTeamType,
  isGated,
  isHolmesMode,
  knobsOf,
  lensSpawnOf,
  modeTypeOf,
  uncheckedDeny,
  withConfigLine,
  workdirOf,
} from './mods/spawn'

// Whether the dispatch gate judges a call made in the loop `agentId` names.
// The lane rejects while it is unknown; a gate then reads it as the main
// session, so the brief is still checked. orchestratorIsOn already fails toward
// on, and its .catch does the same.
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

// ── The guards ───────────────────────────────────────────────────────────────

const GUARDED: ReadonlySet<string> = new Set(['Bash', 'Edit', 'Write', 'NotebookEdit'])

const GUARD_FAILED =
  '🛑 Blocked: a call the guards could not judge.\n\nworkbench-dev-team. The commit guard or the review guard failed while reading this call, so it is refused rather than let an unread commit, push, merge, or write through. Report this to the human as a guard defect. Do not try another spelling.'

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

// The guards on one call: the commit guard and the subject check on a Bash line
// in every lane, then the review guard when a reviewer makes the call, or when
// who makes it cannot be told and the call writes outside scratch.
async function guard($: EngineInterface, e: GuardInput): Promise<string | undefined> {
  const lane = await $.workbench.callerLane(e.agentId === undefined ? {} : { agentId: e.agentId }).catch(() => undefined)
  let parse: ShellParse | undefined
  if (e.tool === 'Bash') {
    const line = typeof e.command === 'string' ? e.command : ''
    parse = await $.workbench.parseShell(line)
    const isUnattended = await $.workbench.isUnattended().catch(() => true)
    const refused = commitVerdict(parse, line, { lane, isUnattended }) ?? subjectVerdict(parse)
    if (refused !== undefined) return refused.deny
  }
  const reviewer = await isReviewer($, e.agentId, lane)
  if (reviewer === false) return undefined
  const deny = await reviewDeny($, e, parse)
  if (deny === undefined || reviewer) return deny
  return `${deny}\n\nThe guard could not tell which agent made this call, so it held the call to the reviewer's rule. Report this to the human as a guard defect.`
}

// ── The panes ────────────────────────────────────────────────────────────────

// Both panes only read. The runs pane lists the log folder and runs awk and
// ps. The board pane runs the tick's board mode, which uses the cached token
// only: it never mints, never reads the Keychain, and writes nothing.

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

export const register: Register = (on, options) => {
  // The rows, read once: the options are fixed for this activation.
  const config = configTextOf(options)

  // The panes. Neither one writes: see refreshRuns and refreshBoard.
  const cadenceMs = cadenceMsOf(options.dispatchCadenceMinutes)
  const memory: PaneMemory = { ends: new Map(), isRunsBusy: false, isBoardBusy: false }

  on('session.start', async ($, e, next) => {
    await $.command.register({ name: RUNS_COMMAND, description: 'Show live and recent dev-team runs from the dispatch logs', immediate: true }).catch(() => undefined)
    await $.command.register({ name: BOARD_COMMAND, description: "Show The Index board's lanes, fetched once per dispatch cadence at most", immediate: true }).catch(() => undefined)
    const open = await $.ui.panes().catch(() => [])
    if (open.some(pane => pane.id === RUNS_PANE || pane.id === BOARD_PANE)) startRefresh($, memory, cadenceMs)
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

  // The gate fails closed: a dispatch it judges whose brief cannot be checked
  // is refused, and so is one whose gate throws before next is called.
  // workbench-core is a declared dependency, so a check that rejects is a
  // fault, and /orchestrator off is the way past it. The helper rule and the
  // workspace check are refusals too, and each says how it fails below. What
  // follows them (the config, the routing) is not a guard: when it fails, the
  // dispatch goes on unchanged, unrouted and on the agent file's own model,
  // which is how the public type runs without this module.
  on('agent.spawn', async ($, e, next) => {
    // Only the model's own Agent calls are judged, the ones the bash gate sees.
    // A plugin's $.agent.spawn is the plugin's implementation, not a handoff.
    const isModel = next.origin.plugin === 'engine'
    const isGatedCall = isModel && (await gated($, e.parentAgentId))
    if (isGatedCall) {
      const check = await $.workbench.briefCheck(e.prompt).catch(() => undefined)
      if (check === undefined) return { deny: uncheckedDeny() }
      if (!check.isComplete) {
        const slots = await $.workbench.briefSlots().catch(() => [])
        return { deny: denyOf(check.missing, slots) }
      }
    }

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
  }).catch(($, e, next) => (next.called ? next(e) : { deny: uncheckedDeny() }))

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
    let input = e
    if (e.agentId !== undefined) {
      const { value: effort } = await $.state.get({ plugin: 'workbench-dev-team', key: 'effort', id: e.agentId })
      if (effort !== undefined) input = { ...e, effort }
    }
    const result = yield* next(input)
    await measure($, e.agentId, result.usage).catch(() => undefined)
    return result
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

  // One tool.call hook, since a plugin registers each event once. A guard that
  // throws refuses the call (fail closed), a scratch rewrite that fails leaves
  // the line as written, and the hint's failure leaves the call as it ran.
  on('tool.call', async ($, e, next) => {
    if (e.tool === 'Bash' || e.tool === 'Edit' || e.tool === 'Write' || e.tool === 'NotebookEdit') {
      const call = e.tool === 'Bash' && typeof e.command === 'string' ? { ...e, command: await withScratch($, e.agentId, e.command) } : e
      const deny = await guard($, call)
      return deny === undefined ? next(call) : { deny }
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
    const result = await next(call)
    if (result.deny !== undefined || result.isError || !isModel) return result
    if (typeof e.prompt !== 'string' || !(await gated($, e.agentId))) return result
    const check = await $.workbench.briefCheck(e.prompt).catch(() => undefined)
    const hint = check === undefined ? undefined : hintOf(check, e.prompt)
    return hint === undefined ? result : { ...result, context: [...(result.context ?? []), hint] }
  }).catch(($, e, next) => (next.called || !GUARDED.has(e.tool) ? next(e) : { deny: GUARD_FAILED }))
}
