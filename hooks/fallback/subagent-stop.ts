import { statSync, writeFileSync } from 'node:fs'

import { waitFileOf } from '../mods/fallback.ts'
import { activeSession, hookInput, readIfAny } from './gate.ts'

const sizeOf = (path: string): number | undefined => {
  try {
    return statSync(path).size
  } catch {
    return undefined
  }
}

const input = await hookInput()
const home = process.env.HOME
const sessionId = activeSession(home, input)
const agentId = typeof input.agent_id === 'string' ? input.agent_id : ''
const snapshot = sessionId === undefined ? undefined : waitFileOf(home, sessionId, agentId, 'snapshot')
const watchesFile = sessionId === undefined ? undefined : waitFileOf(home, sessionId, agentId, 'watches')
const text = snapshot === undefined ? undefined : readIfAny(snapshot)
if (text !== undefined && watchesFile !== undefined) {
  const { inFlightOf, stopBlockOf, waitStateFrom, watchesFrom, watchesText } = await import('../mods/helper-wait.ts')
  const state = waitStateFrom(text)
  if (state !== undefined) {
    const watches = watchesFrom(readIfAny(watchesFile))
    const progress = { helper: (id: string) => state.activity.get(id), outputSize: sizeOf }
    const block = stopBlockOf(agentId, state.agents, state.started, inFlightOf(input.background_tasks), progress, watches)
    writeFileSync(watchesFile, watchesText(watches))
    if (block !== undefined) process.stdout.write(JSON.stringify({ decision: 'block', reason: block }))
  }
}
