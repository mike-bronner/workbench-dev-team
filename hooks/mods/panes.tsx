// The two dev-team panes' trees, from the views hooks/register.ts keeps. Pure:
// the elements come in from the hook's $.ui.resolve(e), and nothing here
// touches `$`. Each row is a keyed Box, so a test finds it by key.

import type { Color, Elements, RenderElement, RenderSurface } from 'claude-code'

import type { BoardItem, BoardLane, BoardView, RunState, RunsView } from '../../types'

export type Draw = Pick<Elements[RenderSurface], 'Box' | 'Text'>

export const RUNS_PANE = 'dev-team-runs'
export const BOARD_PANE = 'dev-team-board'

const STATE_COLOR: Record<RunState, Color> = {
  running: 'suggestion',
  done: 'success',
  failed: 'error',
  refused: 'error',
  'budget-killed': 'warning',
  escalated: 'warning',
}

const pad = (n: number): string => String(n).padStart(2, '0')

// A time of day, HH:MM, in the host's zone.
export const clockOf = (ms: number): string => {
  const at = new Date(ms)
  return `${pad(at.getHours())}:${pad(at.getMinutes())}`
}

export function runsTree({ Box, Text }: Draw, view: RunsView, room: number): RenderElement {
  if (view.error !== undefined) {
    return (
      <Box flexDirection="column">
        <Text color="error">{view.error}</Text>
      </Box>
    )
  }
  if (view.rows.length === 0) {
    return (
      <Box flexDirection="column">
        <Text dimColor>No dispatched runs in the logs yet.</Text>
      </Box>
    )
  }
  // Two lines a run: the run, then its log.
  const rows = view.rows.slice(0, Math.max(1, Math.floor(room / 2)))
  return (
    <Box flexDirection="column">
      {rows.map((row, i) => (
        <Box key={`run-${i}`} flexDirection="column">
          <Text wrap="truncate-end">
            <Text color={STATE_COLOR[row.state]} bold>
              {row.state.padEnd(13)}
            </Text>
            {` ${row.agent.padEnd(8)} ${row.target} · started ${row.startedAt}`}
            {row.refusals > 0 ? ` · ${row.refusals} refused call${row.refusals === 1 ? '' : 's'}` : ''}
          </Text>
          <Text dimColor wrap="truncate-start">
            {`  ${row.log}`}
          </Text>
        </Box>
      ))}
    </Box>
  )
}

const LANE_TITLE = { unrefined: 'Unrefined (Lestrade)', review: 'Review (Holmes)', development: 'Development (Watson)' } as const

// How many items a lane holds: the count, or "25+" when the list came back full.
const countOf = (lane: { limit: number; items: BoardItem[] }): string => (lane.items.length >= lane.limit ? `${lane.limit}+` : String(lane.items.length))

const refOf = (item: BoardItem): string => `${item.number === null ? `item ${item.id}` : `${item.isPr ? 'PR ' : ''}#${item.number}`} ${item.repo ?? ''}`.trimEnd()

// How many items each lane lists under its count.
export const TOP_ITEMS = 3

function laneRows({ Box, Text }: Draw, name: keyof typeof LANE_TITLE, lane: BoardLane): RenderElement {
  if ('error' in lane) {
    return (
      <Box key={`lane-${name}`} flexDirection="column">
        <Text>
          <Text bold>{LANE_TITLE[name]}</Text>
          <Text color="error">{` could not list: ${lane.error}`}</Text>
        </Text>
      </Box>
    )
  }
  const claimed = name === 'development' ? lane.items.filter(item => item.claimedAt !== null).length : 0
  return (
    <Box key={`lane-${name}`} flexDirection="column">
      <Text>
        <Text bold>{LANE_TITLE[name]}</Text>
        {` ${countOf(lane)}${claimed > 0 ? ` · ${claimed} claimed` : ''}`}
      </Text>
      {lane.items.slice(0, TOP_ITEMS).map(item => (
        <Text dimColor wrap="truncate-end">
          {`  ${refOf(item)}  ${item.title ?? ''}`}
        </Text>
      ))}
    </Box>
  )
}

export function boardTree(draw: Draw, view: BoardView, cadenceMs: number): RenderElement {
  const { Box, Text } = draw
  const board = view.board
  const claimed = board && !('error' in board.development) ? board.development.items.filter(item => item.claimedAt !== null) : []
  const status =
    view.attemptedAt === 0
      ? 'Fetching the board from The Index.'
      : `${board && view.boardAt !== undefined ? `Fetched ${clockOf(view.boardAt)}` : 'Not fetched'} · next fetch after ${clockOf(view.attemptedAt + cadenceMs)}`
  return (
    <Box flexDirection="column">
      <Box key="board-status">
        <Text dimColor>{status}</Text>
      </Box>
      {view.error !== undefined && (
        <Box key="board-error">
          <Text color="error">{`The last fetch failed: ${view.error}`}</Text>
        </Box>
      )}
      {board && laneRows(draw, 'unrefined', board.unrefined)}
      {board && laneRows(draw, 'review', board.review)}
      {board && laneRows(draw, 'development', board.development)}
      {claimed.length > 0 && (
        <Box key="claimed" flexDirection="column">
          <Text bold>Claimed</Text>
          {claimed.map(item => (
            <Text wrap="truncate-end">{`  ${refOf(item)}  since ${item.claimedAt}`}</Text>
          ))}
        </Box>
      )}
      {view.escalated.length > 0 && (
        <Box key="escalated" flexDirection="column">
          <Text bold color="warning">
            Escalated by the breaker
          </Text>
          {view.escalated.map(line => (
            <Text>{`  ${line}`}</Text>
          ))}
        </Box>
      )}
    </Box>
  )
}
