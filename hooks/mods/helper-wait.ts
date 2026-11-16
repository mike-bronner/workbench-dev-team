import type { ShellParse } from './review-guard'

export type Child = { id: string; type: string; status: string; parentId?: string; name?: string; description: string }

export type InFlight = { id: string; command?: string; description: string }

export type Started = { id: string; output?: string }

export type Activity = { ticks: number; inFlight: number }

export type Watch = { mark: string; unchanged: number; isReleased: boolean }

export type Progress = { helper: (id: string) => Activity | undefined; outputSize: (path: string) => number | undefined }

export const STUCK_AFTER = 2

const OUTSTANDING: ReadonlySet<string> = new Set(['pending', 'running', 'waiting'])

const clip = (text: string): string => (text.length > 120 ? `${text.slice(0, 117)}...` : text)

export const withStarted = (started: readonly Started[], entry: Started): Started[] => [...started.filter(kept => kept.id !== entry.id), entry]

export function outputOf(id: string, text: unknown): string | undefined {
  if (typeof text !== 'string') return undefined
  const match = /Output is being written to: (\/\S+?)\.?(?:\s|$)/.exec(text)
  const path = match?.[1]
  return path !== undefined && path.endsWith(`/${id}.output`) ? path : undefined
}

export const watchKey = (agentId: string, itemKey: string): string => `${agentId}\u0000${itemKey}`

export type WaitSnapshot = { agents: Child[]; started: Started[]; activity: [string, Activity][]; handedBack: boolean }

export type WaitState = { agents: Child[]; started: Started[]; activity: ReadonlyMap<string, Activity>; handedBack: boolean }

const childOf = ({ id, type, status, parentId, name, description }: Child): Child => ({
  id,
  type,
  status,
  description,
  ...(parentId === undefined ? {} : { parentId }),
  ...(name === undefined ? {} : { name }),
})

export function snapshotOf(agentId: string, agents: readonly Child[], started: readonly Started[], activity: (id: string) => Activity | undefined, handedBack = false): WaitSnapshot {
  const children = agents.filter(agent => agent.parentId === agentId).map(childOf)
  return {
    agents: children,
    started: [...started],
    activity: children.flatMap(child => {
      const seen = activity(child.id)
      return seen === undefined ? [] : [[child.id, { ticks: seen.ticks, inFlight: seen.inFlight }] as [string, Activity]]
    }),
    handedBack,
  }
}

type Fields = Record<string, unknown>

const isFields = (value: unknown): value is Fields => typeof value === 'object' && value !== null && !Array.isArray(value)
const isText = (value: unknown): value is string => typeof value === 'string'
const isCount = (value: unknown): value is number => typeof value === 'number' && Number.isFinite(value)
const isOptionalText = (value: unknown): boolean => value === undefined || isText(value)

const asChild = (value: unknown): Child | undefined =>
  isFields(value) && isText(value.id) && isText(value.type) && isText(value.status) && isText(value.description) && isOptionalText(value.parentId) && isOptionalText(value.name)
    ? childOf(value as Child)
    : undefined

const asStarted = (value: unknown): Started | undefined =>
  isFields(value) && isText(value.id) && isOptionalText(value.output) ? { id: value.id, ...(isText(value.output) ? { output: value.output } : {}) } : undefined

const asActivity = (value: unknown): Activity | undefined => (isFields(value) && isCount(value.ticks) && isCount(value.inFlight) ? { ticks: value.ticks, inFlight: value.inFlight } : undefined)

const asWatch = (value: unknown): Watch | undefined =>
  isFields(value) && isText(value.mark) && isCount(value.unchanged) && typeof value.isReleased === 'boolean' ? { mark: value.mark, unchanged: value.unchanged, isReleased: value.isReleased } : undefined

const asInFlight = (value: unknown): InFlight | undefined =>
  isFields(value) && isText(value.id) && isText(value.description) && isOptionalText(value.command)
    ? { id: value.id, description: value.description, ...(isText(value.command) ? { command: value.command } : {}) }
    : undefined

function everyOf<T>(value: unknown, as: (item: unknown) => T | undefined): T[] | undefined {
  if (!Array.isArray(value)) return undefined
  const items: T[] = []
  for (const item of value) {
    const read = as(item)
    if (read === undefined) return undefined
    items.push(read)
  }
  return items
}

function pairsOf<T>(value: unknown, as: (item: unknown) => T | undefined): Map<string, T> | undefined {
  const pairs = everyOf(value, pair => {
    if (!Array.isArray(pair) || pair.length !== 2 || !isText(pair[0])) return undefined
    const read = as(pair[1])
    return read === undefined ? undefined : ([pair[0], read] as [string, T])
  })
  return pairs === undefined ? undefined : new Map(pairs)
}

function parsed(text: string): unknown {
  try {
    return JSON.parse(text) as unknown
  } catch {
    return undefined
  }
}

export function waitStateFrom(text: string): WaitState | undefined {
  const raw = parsed(text)
  if (!isFields(raw)) return undefined
  const agents = everyOf(raw.agents, asChild)
  const started = everyOf(raw.started, asStarted)
  const activity = pairsOf(raw.activity, asActivity)
  return agents === undefined || started === undefined || activity === undefined ? undefined : { agents, started, activity, handedBack: raw.handedBack === true }
}

export const watchesFrom = (text: string | undefined): Map<string, Watch> => (text === undefined ? undefined : pairsOf(parsed(text), asWatch)) ?? new Map()

export const watchesText = (watches: ReadonlyMap<string, Watch>): string => JSON.stringify([...watches])

export const inFlightOf = (value: unknown): InFlight[] => (Array.isArray(value) ? value.flatMap(item => asInFlight(item) ?? []) : [])

const WAIT_PART = /^(sleep( +[0-9.]+[smhd]?)+|true|:|date( +\S+)?|(echo|printf)( .*)?)$/

export function isTimer(command: string | undefined): boolean {
  if (command === undefined) return false
  const parts = command.split(/&&|\|\||;|\n/).map(part => part.trim()).filter(part => part !== '')
  return parts.some(part => /^sleep /.test(part)) && parts.every(part => !/[$`<>|&(){}\\[\]]/.test(part) && WAIT_PART.test(part))
}

export const isBackgroundAsked = (value: unknown): boolean => value !== undefined && value !== false && value !== 'false'

const SELF_BACKGROUND: ReadonlySet<string> = new Set(['nohup', 'setsid', 'disown'])

export const BACKGROUND_HINT = /&|nohup|setsid|disown/i

export type Probe<T> = { separator: T; statement: T }

export function probeLinesOf(line: string): Probe<string>[] {
  const probes: Probe<string>[] = []
  let quote: string | undefined
  let depth = 0
  for (let i = 0; i < line.length; i++) {
    const c = line[i]
    if (quote === "'") {
      if (c === "'") quote = undefined
      continue
    }
    if (c === '\\') {
      i++
      continue
    }
    if (c === '$' && line[i + 1] === '{') {
      depth++
      i++
      continue
    }
    if (depth > 0) {
      if (c === '{') depth++
      else if (c === '}') depth--
      continue
    }
    if (c === '"') quote = quote === '"' ? undefined : '"'
    else if (c === "'" && quote === undefined) quote = "'"
    if (c !== '&' || /[&|<>;]/.test(line[i - 1] ?? '') || /[&>]/.test(line[i + 1] ?? '')) continue
    probes.push({ separator: `${line.slice(0, i)};${line.slice(i + 1)}`, statement: `${line.slice(0, i)};:;${line.slice(i + 1)}` })
  }
  return probes
}

const isSameReading = (a: ShellParse, b: ShellParse): boolean => JSON.stringify(a) === JSON.stringify(b)

export function backgroundsItself(parse: ShellParse, probes: readonly Probe<ShellParse>[]): boolean {
  if (parse.statements.some(s => SELF_BACKGROUND.has(s.name) || s.wrappers.some(wrapper => SELF_BACKGROUND.has(wrapper)))) return true
  return probes.some(probe => isSameReading(probe.separator, parse) && !isSameReading(probe.statement, parse))
}

export const backgroundDeny = [
  '🛑 Refused: a dev-team agent runs every Bash command in the foreground, so the dev-team mod refuses `run_in_background`, a background `&`, `nohup`, `setsid` and `disown`.',
  '',
  'workbench-dev-team. Your run is already apart from the session that started it, so a background command of your own gains nothing, and it can outlive your run and hold it open.',
  'Run the command again in the foreground, with none of those, and set `timeout` up to 600000 ms, the foreground limit.',
  'If the command needs longer than that, split it into parts that each finish within the limit, such as one test file, one directory or one filter per call.',
].join('\n')

export type CommandState = { id: string; pids?: string[] }

export const holdersArgv = (output: string): string[] => ['lsof', '-t', '-w', '--', output]

export function pidsOf(answer: { exitCode: number | null; stdout: string; stderr: string } | undefined): string[] | undefined {
  if (answer === undefined) return undefined
  const pids = answer.stdout.split(/\s+/).filter(word => word !== '')
  if (answer.exitCode === 0 && pids.length > 0 && pids.every(pid => /^[0-9]+$/.test(pid))) return pids
  return answer.exitCode === 1 && pids.length === 0 && answer.stderr.trim() === '' ? [] : undefined
}

export function handbackRefusalOf(agentId: string, states: readonly CommandState[], refusedOnce: Set<string>): string | undefined {
  const live = states.filter(state => state.pids !== undefined && state.pids.length > 0)
  const unsure = states.filter(state => state.pids === undefined && !refusedOnce.has(watchKey(agentId, state.id)))
  for (const state of unsure) refusedOnce.add(watchKey(agentId, state.id))
  if (live.length === 0 && unsure.length === 0) return undefined
  return [
    '🛑 Refused: you cannot hand back while a background command you started may still be running.',
    '',
    'workbench-dev-team. A hand-back ends your run, and a command that still runs keeps the run open with nothing left to close it.',
    ...live.map(state => `- background command ${state.id}: still running as process ${(state.pids ?? []).join(', ')}`),
    ...unsure.map(state => `- background command ${state.id}: the mod cannot tell whether it still runs`),
    '',
    'Wait for its completion notice: each tool call delivers the notices that wait for you. Or stop it with `kill` and its process ids in a foreground Bash call.',
    "If the command's completion notice already arrived, a process it left behind still holds the run open: stop the listed processes with `kill` rather than wait.",
    'Then call SubagentHandback again with your report.',
    ...(unsure.length > 0 ? ['A command the mod cannot check refuses one hand-back only, so if you know it ended, hand back again.'] : []),
  ].join('\n')
}

type Item = { key: string; line: string; mark: string; isBusy: boolean }

export function stopBlockOf(
  agentId: string,
  agents: readonly Child[],
  started: readonly Started[],
  inFlight: readonly InFlight[],
  progress: Progress,
  watches: Map<string, Watch>,
): string | undefined {
  const helpers: Item[] = agents
    .filter(agent => agent.parentId === agentId && OUTSTANDING.has(agent.status))
    .map(agent => {
      const activity = progress.helper(agent.id) ?? { ticks: 0, inFlight: 0 }
      const line = `- helper ${agent.id} (${agent.type.split(':').pop()}, ${agent.status}): ${clip(agent.name ?? agent.description)}`
      return { key: `helper:${agent.id}`, line, mark: String(activity.ticks), isBusy: activity.inFlight > 0 }
    })
  const commands: Item[] = inFlight.flatMap(task => {
    const own = started.find(entry => entry.id === task.id)
    if (own === undefined || isTimer(task.command)) return []
    const size = own.output === undefined ? undefined : progress.outputSize(own.output)
    return [{ key: `command:${task.id}`, line: `- background command ${task.id}: ${clip(task.command ?? task.description)}`, mark: String(size), isBusy: false }]
  })
  const items = [...helpers, ...commands].filter(item => !watches.get(watchKey(agentId, item.key))?.isReleased)
  if (items.length === 0) return undefined
  const stuck = items.filter(item => {
    const key = watchKey(agentId, item.key)
    const seen = watches.get(key)
    const unchanged = seen !== undefined && !item.isBusy && item.mark === seen.mark ? seen.unchanged + 1 : 0
    watches.set(key, { mark: item.mark, unchanged, isReleased: false })
    return unchanged >= STUCK_AFTER
  })
  if (stuck.length === items.length) {
    for (const item of stuck) watches.set(watchKey(agentId, item.key), { mark: item.mark, unchanged: STUCK_AFTER, isReleased: true })
    return [
      '⚠️ These made no progress across your last two attempts to end your turn, so they no longer hold it:',
      ...stuck.map(item => item.line),
      '',
      'workbench-dev-team. A helper made no model request or tool call, and a background command wrote no new output. Name each one in your report as work that looked stuck, with what it was meant to do, and then end your turn. Your next turn end is allowed.',
    ].join('\n')
  }
  return [
    '🛑 Blocked: you cannot end your turn while work you started has not reported.',
    '',
    'workbench-dev-team. Still outstanding:',
    ...items.map(item => item.line),
    '',
    'A sub-agent that ends its turn is never woken by a notice, so these reports would never reach you.',
    'Wait for their completion notices. Do the work that does not need their reports, one tool call at a time, because each tool call delivers the notices that wait for you. When no work is left, make one quick foreground call, such as `date`, and look for a new notice after it.',
    'Never start a background command or a `sleep` just to wait. A sleep of a plain duration delivers no report, so it never holds your turn.',
    'A helper or background command that makes no progress across two of your attempts to end your turn stops holding it, and you are told which one.',
  ].join('\n')
}
