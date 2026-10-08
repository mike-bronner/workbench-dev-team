// The board pane's logic, as pure functions. hooks/register.ts holds the hooks;
// hooks/mods/panes.tsx draws the lanes.
//
// The pane reaches The Index only through `bin/dispatch-tick.sh --board`, run
// from this plugin's own folder. That mode uses the tick's cached token only
// (it never mints, never reads the Keychain, and writes nothing), calls the
// three list tools and nothing else, and prints the lanes as JSON. So no token
// or secret ever reaches this module. The pane runs
// it when it opens and then once per dispatch cadence at most, counting every
// attempt, a failed one included.

// The view types live in the type contract, types/index.d.ts.
import type { Board, BoardItem, BoardLane, BoardView } from '../../types'

export const LANES = ['unrefined', 'review', 'development'] as const

export const EMPTY_BOARD: BoardView = { attemptedAt: 0, escalated: [] }

// The dispatch cadence's default, as in .claude-plugin/plugin.json.
export const DEFAULT_CADENCE_MINUTES = 20

// How long a board fetch may take: three list calls of up to 120 s each in the
// tick's own client.
export const BOARD_TIMEOUT_MS = 400_000

// The cadence in milliseconds, from the /config row. A value that is not a
// number of at least one minute reads as the default, so a bad row never
// makes the pane call The Index more often.
export function cadenceMsOf(minutes: unknown): number {
  const value = typeof minutes === 'number' && Number.isFinite(minutes) && minutes >= 1 ? minutes : DEFAULT_CADENCE_MINUTES
  return value * 60_000
}

// Whether the pane may fetch the board now: never fetched, or the last attempt
// started a whole cadence ago.
export const isDue = (view: BoardView, now: number, cadenceMs: number): boolean => view.attemptedAt === 0 || now - view.attemptedAt >= cadenceMs

export const boardArgv = (root: string): string[] => ['bash', `${root}/bin/dispatch-tick.sh`, '--board']

const isObject = (value: unknown): value is Record<string, unknown> => typeof value === 'object' && value !== null && !Array.isArray(value)
const text = (value: unknown): string | null => (typeof value === 'string' ? value : null)

function itemOf(value: unknown): BoardItem | undefined {
  if (!isObject(value) || typeof value.id !== 'number') return undefined
  return {
    id: value.id,
    number: typeof value.number === 'number' ? value.number : null,
    isPr: value.isPr === true,
    repo: text(value.repo),
    title: text(value.title),
    claimedAt: text(value.claimedAt),
  }
}

function laneOf(value: unknown): BoardLane | undefined {
  if (!isObject(value)) return undefined
  if (typeof value.error === 'string') return { error: value.error.slice(0, 300) }
  if (typeof value.limit !== 'number' || !Array.isArray(value.items)) return undefined
  const items = value.items.map(itemOf)
  return items.every(item => item !== undefined) ? { limit: value.limit, items: items as BoardItem[] } : undefined
}

// The board the client printed, or undefined when its output is anything else.
// Only the named fields are kept, each of its own type.
export function boardOf(stdout: string): Board | undefined {
  let parsed: unknown
  try {
    parsed = JSON.parse(stdout)
  } catch {
    return undefined
  }
  if (!isObject(parsed) || !isObject(parsed.lanes)) return undefined
  const lanes = parsed.lanes
  const [unrefined, review, development] = LANES.map(lane => laneOf(lanes[lane]))
  return unrefined && review && development ? { unrefined, review, development } : undefined
}

// What one run of the client means: the board, or why there is none. The
// client prints its reason as the last line on stderr, and never a token.
export function boardOutcome(run: { exitCode: number; stdout: string; stderr: string } | undefined): { board: Board } | { error: string } {
  if (run === undefined) return { error: 'the board client could not run' }
  const board = run.exitCode === 0 ? boardOf(run.stdout) : undefined
  if (board !== undefined) return { board }
  const why = run.stderr.split('\n').findLast(line => line.trim() !== '')?.trim()
  if (run.exitCode === 0) return { error: 'the board client printed something that is not a board' }
  return { error: (why ?? `the board client exited ${run.exitCode}`).slice(0, 300) }
}

// The view after a fetch that started at `startedAt`. A failed fetch keeps the
// last board, so the pane still shows it, with its age.
export function afterFetch(view: BoardView, startedAt: number, outcome: { board: Board } | { error: string }): BoardView {
  if ('board' in outcome) return { attemptedAt: startedAt, board: outcome.board, boardAt: startedAt, escalated: view.escalated }
  const { board, boardAt } = view
  return { attemptedAt: startedAt, ...(board ? { board, boardAt } : {}), error: outcome.error, escalated: view.escalated }
}

// "watson item 42" for each escalated pair "watson-42".
export const escalatedOf = (markers: readonly string[]): string[] =>
  markers.map(pair => {
    const dash = pair.lastIndexOf('-')
    return `${pair.slice(0, dash)} item ${pair.slice(dash + 1)}`
  })
