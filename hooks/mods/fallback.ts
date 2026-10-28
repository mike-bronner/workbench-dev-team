export type ModHook = 'session-start' | 'subagent-start' | 'subagent-stop' | 'prompt-compose'

export type WaitFile = 'snapshot' | 'watches'

export const STALE_DAYS = 7

const isId = (id: string): boolean => /^[A-Za-z0-9][A-Za-z0-9_-]*$/.test(id)

const folderOf = (home: string | undefined, name: string): string | undefined =>
  home && home.startsWith('/') ? `${home.replace(/\/+$/, '')}/.claude-workbench/${name}` : undefined

export const modRanDirOf = (home: string | undefined): string | undefined => folderOf(home, 'dev-team-mod-ran')

export const helperWaitDirOf = (home: string | undefined): string | undefined => folderOf(home, 'dev-team-helper-wait')

export function sessionDirOf(home: string | undefined, sessionId: string): string | undefined {
  const root = modRanDirOf(home)
  return root === undefined || !isId(sessionId) ? undefined : `${root}/${sessionId}`
}

export function markerOf(home: string | undefined, sessionId: string, hook: ModHook): string | undefined {
  const dir = sessionDirOf(home, sessionId)
  return dir === undefined ? undefined : `${dir}/${hook}`
}

export function waitFileOf(home: string | undefined, sessionId: string, agentId: string, kind: WaitFile): string | undefined {
  const root = helperWaitDirOf(home)
  return root === undefined || !isId(sessionId) || !isId(agentId) ? undefined : `${root}/${sessionId}/${agentId}.${kind}.json`
}

export function sweepArgvsOf(home: string | undefined): string[][] {
  const roots = [modRanDirOf(home), helperWaitDirOf(home)].filter((root): root is string => root !== undefined)
  if (roots.length === 0) return []
  return [
    ['find', ...roots, '-mindepth', '2', '-type', 'f', '-mtime', `+${STALE_DAYS}`, '-delete'],
    ['find', ...roots, '-mindepth', '1', '-type', 'd', '-empty', '-delete'],
  ]
}
