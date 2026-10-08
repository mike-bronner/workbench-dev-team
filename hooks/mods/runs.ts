// The runs pane's logic, as pure functions. hooks/register.ts holds the hooks
// and reads the disk; hooks/mods/panes.tsx draws the rows.
//
// bin/dispatch-agent.sh writes one log per run in ~/.claude-workbench/dev-team-logs:
//   <agent>-<item id>-<YYYYMMDD-HHMMSS>.log     an item run
//   lestrade-sweep-<owner>-<repo>-<stamp>.log  a blocker sweep ("/" written as "-")
// beside <agent>-<id>.lock (the run's pid) and <agent>-<id>.escalated (the
// breaker escalated the item after its last run). The pane reads the newest
// RUN_LIMIT logs only, and each one again only when its size or mtime changed.
// It reads them with one awk (bin/scan-run-logs.awk) over the changed files,
// and finds the live runs with one ps. It writes nothing.

export const LOG_DIR = '.claude-workbench/dev-team-logs'

// The most runs the pane shows.
export const RUN_LIMIT = 8

// How often the runs pane reads the logs while it is open.
export const RUNS_REFRESH_MS = 15_000

// The view types live in the type contract, types/index.d.ts, which
// `claude plugin validate` holds every $.state value to.
import type { DevTeamAgent as Agent, RunRow, RunState } from '../../types'

// What a run's log name says: its agent, what it ran on, when it started, and
// the pair the lock, the marker and the dispatcher's command line name.
export type RunLog = { name: string; agent: Agent; target: string; pair: string; startedAt: string }

// The end of a log, as the breaker reads it: its last three lines that are not
// permission refusals, and how many refusals it holds.
export type LogEnd = { tail: string[]; refusals: number }

const ITEM_LOG = /^(lestrade|holmes|watson)-([0-9]+)-([0-9]{8})-([0-9]{6})\.log$/
const SWEEP_LOG = /^lestrade-sweep-(.+)-([0-9]{8})-([0-9]{6})\.log$/
const MARKER = /^(lestrade|holmes|watson)-([0-9]+)\.escalated$/

const stampOf = (day: string, time: string): string =>
  `${day.slice(0, 4)}-${day.slice(4, 6)}-${day.slice(6)} ${time.slice(0, 2)}:${time.slice(2, 4)}:${time.slice(4)}`

// The run a log file name records, or undefined for any other file:
// dispatch-tick.log, a lock, a marker.
export function runLogOf(name: string): RunLog | undefined {
  const item = ITEM_LOG.exec(name)
  if (item) {
    const [, agent, id, day, time] = item as unknown as [string, Agent, string, string, string]
    return { name, agent, target: `item ${id}`, pair: `${agent}-${id}`, startedAt: stampOf(day, time) }
  }
  const sweep = SWEEP_LOG.exec(name)
  if (sweep) {
    const [, slug, day, time] = sweep as unknown as [string, string, string, string]
    return { name, agent: 'lestrade', target: `sweep ${slug}`, pair: `lestrade-sweep-${slug}`, startedAt: stampOf(day, time) }
  }
  return undefined
}

export type Entry = { name: string; kind: string; mtimeMs: number; size: number }
export type NewestRun = RunLog & { mtimeMs: number; size: number }

// The newest `limit` run logs in a listing, newest first.
export function newestRuns(entries: readonly Entry[], limit = RUN_LIMIT): NewestRun[] {
  const runs: NewestRun[] = []
  for (const entry of entries) {
    const log = entry.kind === 'file' ? runLogOf(entry.name) : undefined
    if (log) runs.push({ ...log, mtimeMs: entry.mtimeMs, size: entry.size })
  }
  return runs.sort((a, b) => b.mtimeMs - a.mtimeMs || (a.name < b.name ? 1 : -1)).slice(0, limit)
}

// The pairs whose item the breaker escalated: one <agent>-<id>.escalated each.
export function markersOf(entries: readonly Entry[]): string[] {
  return entries.flatMap(entry => {
    const marker = MARKER.exec(entry.name)
    return marker ? [`${marker[1]}-${marker[2]}`] : []
  })
}

// The pairs a live dispatcher runs, read from `ps -axo command=`. The
// dispatcher's run is its wrapper subshell, whose command line is the
// dispatcher's own: `bash …/dispatch-agent.sh <agent> <target>`. A `--check` or
// `--mark-escalated` call puts its flag before the agent, so it never matches.
export function livePairsOf(ps: string): Set<string> {
  const live = new Set<string>()
  for (const line of ps.split('\n')) {
    const run = /dispatch-agent\.sh\s+(lestrade|holmes|watson)\s+(\S+)\s*$/.exec(line)
    if (!run) continue
    const [, agent, target] = run as unknown as [string, Agent, string]
    if (/^[0-9]+$/.test(target)) live.add(`${agent}-${target}`)
    else if (agent === 'lestrade' && target.includes('/')) live.add(`lestrade-sweep-${target.replaceAll('/', '-')}`)
  }
  return live
}

// The awk program that reads the end of the logs, shipped beside the scripts
// so bin/test-scan-run-logs.sh runs the real thing.
export const scanArgv = (root: string, logs: readonly string[]): string[] => ['awk', '-f', `${root}/bin/scan-run-logs.awk`, ...logs]

// The awk run's output, by path. A path that printed nothing is absent.
export function endsOf(stdout: string): Map<string, LogEnd> {
  const ends = new Map<string, LogEnd>()
  let current: LogEnd | undefined
  for (const line of stdout.split('\n')) {
    if (line.startsWith('\u001e')) {
      const tab = line.indexOf('\t')
      current = { tail: [], refusals: Number(line.slice(1, tab)) || 0 }
      ends.set(line.slice(tab + 1), current)
    } else if (current !== undefined && current.tail.length < 3) {
      current.tail.push(line)
    }
  }
  // The output's own last newline is no line of the log.
  for (const end of ends.values()) while (end.tail.length > 0 && end.tail[end.tail.length - 1] === '') end.tail.pop()
  return ends
}

// A run's state. Only the newest run of a pair can be the one running, or the
// one the breaker escalated after; an older run of the pair has ended. The end
// is read as the breaker reads it, from the last lines that are not refusals.
export function stateOf(facts: { isNewest: boolean; isLive: boolean; isEscalated: boolean; end: LogEnd }): RunState {
  if (facts.isNewest && facts.isLive) return 'running'
  if (facts.isNewest && facts.isEscalated) return 'escalated'
  const tail = facts.end.tail
  if (tail.some(line => /content filtering policy/i.test(line))) return 'refused'
  if (tail.some(line => line.includes('Exceeded USD budget'))) return 'budget-killed'
  if (tail.some(line => /^(API Error|Execution error|Error:)/i.test(line))) return 'failed'
  return 'done'
}

// The pane's rows, newest first.
export function rowsOf(dir: string, runs: readonly NewestRun[], ends: ReadonlyMap<string, LogEnd>, live: ReadonlySet<string>, markers: readonly string[]): RunRow[] {
  const seen = new Set<string>()
  return runs.map(run => {
    const isNewest = !seen.has(run.pair)
    seen.add(run.pair)
    const log = `${dir}/${run.name}`
    const end = ends.get(log) ?? { tail: [], refusals: 0 }
    const state = stateOf({ isNewest, isLive: live.has(run.pair), isEscalated: markers.includes(run.pair), end })
    return { agent: run.agent, target: run.target, startedAt: run.startedAt, state, refusals: end.refusals, log }
  })
}
