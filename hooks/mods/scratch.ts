import type { ShellParse, Statement } from './review-guard'

const FLAGS = /^-[dqu]+$|^--(directory|quiet|dry-run)$/
const VALUED = /^-[dqu]*([tp])(.*)$/

export function isBareMktemp(statement: Statement): boolean {
  if (statement.name !== 'mktemp') return false
  const { args } = statement
  const templates: string[] = []
  let folder: string | undefined
  for (let i = 0; i < args.length; i++) {
    const arg = args[i] ?? ''
    const valued = VALUED.exec(arg)
    if (arg === '--') {
      templates.push(...args.slice(i + 1))
      break
    }
    if (arg === '--tmpdir') folder = ''
    else if (arg.startsWith('--tmpdir=')) folder = arg.slice('--tmpdir='.length)
    else if (FLAGS.test(arg)) continue
    else if (valued !== null) {
      const value = valued[2] === '' ? (args[++i] ?? '') : (valued[2] ?? '')
      if (valued[1] === 'p') folder = value
    } else if (arg.startsWith('-')) return false
    else templates.push(arg)
  }
  if (templates.length === 0) return !folder
  return folder === '' && templates.some(template => !template.startsWith('/'))
}

export const hasBareMktemp = (parse: ShellParse): boolean => parse.statements.some(isBareMktemp)

export const templateOf = (folder: string): string => `${folder}/tmp.XXXXXXXX`

export const scratchContextOf = (folder: string): string =>
  `Your scratch folder for this run is ${folder}. Make a temporary folder with \`mktemp -d '${templateOf(folder)}'\`, and a temporary file with \`mktemp '${templateOf(folder)}'\`. The dev-team mod refuses a bare \`mktemp\`, and deletes this folder when your run ends.`

export const mktempDeny = (folder: string | undefined): string =>
  folder === undefined
    ? 'A bare `mktemp` lands in $TMPDIR, outside every scratch root, so the dev-team mod refuses it. The mod could not make a scratch folder for this run. Make the folder with an explicit template under the session scratchpad or ~/Developer/scratchpad, such as `mktemp -d \'<root>/tmp.XXXXXXXX\'`, and delete it before you report, with `rm -rf` and its literal path, as a command of its own.'
    : `A bare \`mktemp\` lands in $TMPDIR, outside your scratch folder, so the dev-team mod refuses it. Your scratch folder is ${folder}. Make a temporary folder with \`mktemp -d '${templateOf(folder)}'\`, and a temporary file with \`mktemp '${templateOf(folder)}'\`. The mod deletes the folder when your run ends.`

const PLAIN_PATH = /^\/[A-Za-z0-9._@+\/-]+$/

// The scratch root an agent's folder goes in: the first of core's roots that
// is not ~/.claude/plans, so the session scratchpad when there is one, and
// ~/Developer/scratchpad when there is not, as the agents' prose orders them.
export const rootOf = (roots: readonly string[]): string | undefined => roots.find(root => !root.endsWith('/.claude/plans'))

// The folder's name prefix: the agent's bare type (`watson-direct`), in plain
// characters.
export const prefixOf = (type: string): string => (type.split(':').pop() ?? 'agent').replace(/[^A-Za-z0-9_-]/g, '') || 'agent'

// The statuses of a loop that is not over: not started, in a turn, held, or
// between turns until a message wakes it.
const LIVE: ReadonlySet<string> = new Set(['pending', 'running', 'waiting', 'idle'])

// Whether a run still has a live child: an agent its loop spawned (for the
// top-level `run`, one with no parent) that is not over. A child may read the
// run's folder, as Holmes's helpers read his checkout, so the folder stays.
export const hasLiveChild = (agents: readonly { parentId?: string; status: string }[], agentId: string | undefined): boolean =>
  agents.some(agent => agent.parentId === agentId && LIVE.has(agent.status))

// Whether `folder` may be deleted: a folder directly or deeper inside one of
// the scratch roots, never a root itself.
export const isDeletable = (folder: string, roots: readonly string[]): boolean =>
  PLAIN_PATH.test(folder) && !folder.split('/').includes('..') && roots.some(root => folder.startsWith(`${root}/`) && folder.length > root.length + 1)

// What leaves room for the engine's own end step out of the end's budget, and
// the most the sweep's rm may take of it.
const END_MARGIN_MS = 150
const END_RM_CAP_MS = 1_000

// The session end's sweep: the recorded folders one rm may delete, the ones
// under a scratch root, and the time it may take, or undefined when there is
// nothing to delete or too little time left. A folder left out stays recorded.
export function sweepOf(folders: readonly string[], roots: readonly string[], remainingMs: number): { doomed: string[]; timeoutMs: number } | undefined {
  const doomed = folders.filter(folder => isDeletable(folder, roots))
  const timeoutMs = Math.min(remainingMs, END_RM_CAP_MS) - END_MARGIN_MS
  return doomed.length === 0 || timeoutMs <= 0 ? undefined : { doomed, timeoutMs }
}
