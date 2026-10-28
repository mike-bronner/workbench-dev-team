import { existsSync, readFileSync } from 'node:fs'

import { sessionDirOf } from '../mods/fallback.ts'

export type HookInput = { session_id?: unknown; agent_id?: unknown; agent_type?: unknown; background_tasks?: unknown }

export const readIfAny = (path: string): string | undefined => {
  try {
    return existsSync(path) ? readFileSync(path, 'utf8') : undefined
  } catch {
    return undefined
  }
}

export async function hookInput(): Promise<HookInput> {
  process.stdin.setEncoding('utf8')
  let text = ''
  for await (const chunk of process.stdin) text += String(chunk)
  try {
    const parsed = JSON.parse(text) as unknown
    return typeof parsed === 'object' && parsed !== null ? (parsed as HookInput) : {}
  } catch {
    return {}
  }
}

export function activeSession(home: string | undefined, input: HookInput): string | undefined {
  const sessionId = typeof input.session_id === 'string' ? input.session_id : ''
  const dir = sessionDirOf(home, sessionId)
  return dir === undefined || existsSync(dir) ? undefined : sessionId
}

export function emit(hookEventName: string, additionalContext: string): void {
  process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName, additionalContext } }))
}
