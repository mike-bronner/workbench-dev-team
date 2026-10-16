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
    if (own === undefined) return []
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
    'Keep making short tool calls, such as `sleep 20`, until each one reports. Each tool call delivers the notices that wait for you.',
    'A helper or background command that makes no progress across two of your attempts to end your turn stops holding it, and you are told which one.',
  ].join('\n')
}
