// Each dev-team agent's own scratch folder, as pure functions. hooks/register.ts
// holds the hooks: tool.call points a bare mktemp at the folder, and
// turn.complete deletes the folder when the agent's run ends.
//
// A bare mktemp is one with no template and no directory option (`mktemp`,
// `mktemp -d`, `mktemp -dq`), which lands in $TMPDIR, outside every scratch
// root, and outlives the run. The rewrite adds a template inside the agent's
// folder, so the folder holds every temporary file and folder the run made.
//
// Only a dev-team agent's line is pointed: a sub-agent of a dev-team type
// (holmes-lens included), and the top-level loop of a `claude -p --agent` run
// of one. The main session and every other agent keep mktemp as they wrote it.
//
// The rewrite is checked, never trusted. The line is read again after it, and
// the rewrite stands only when every statement reads exactly as before, apart
// from each bare mktemp gaining the one template word. Anything else (a mktemp
// the text match missed, or one it found inside a quoted string or a heredoc)
// leaves the line as it was written, which is how it ran before the mod.

import type { ShellParse, Statement } from './commit-guard'

// mktemp's no-value options. -t, -p and --tmpdir name a directory, so a line
// with any of them is not bare.
const FLAGS = /^-[dqu]+$/

export const isBareMktemp = (statement: Statement): boolean =>
  statement.name === 'mktemp' &&
  statement.nameAt === 0 &&
  statement.wrappers.length === 0 &&
  statement.assignments.length === 0 &&
  statement.args.every(arg => FLAGS.test(arg))

export const hasBareMktemp = (parse: ShellParse): boolean => parse.statements.some(isBareMktemp)

// The template a bare mktemp gains: the folder, quoted, and mktemp's X run.
export const templateOf = (folder: string): string => `${folder}/tmp.XXXXXXXX`

// A bare mktemp in the text: the name at a command boundary, its no-value
// options, and then the end of the command, or a `#` comment after a space.
const BARE = /(^|[\s;&|(`])mktemp((?:[ \t]+-[dqu]+)*)(?=[ \t]*(?:$|[;&|)`\n])|[ \t]+#)/gm

// A folder the rewrite can quote: an absolute path of plain characters.
const PLAIN_PATH = /^\/[A-Za-z0-9._@+\/-]+$/

// The line with every bare mktemp the text match finds pointed at `folder`, or
// undefined when there is nothing to point or the folder cannot be quoted.
// The caller reads the result again and keeps it only when readsAsPointed.
export function pointMktemp(line: string, folder: string): string | undefined {
  if (!PLAIN_PATH.test(folder)) return undefined
  const rewritten = line.replace(BARE, (_, lead: string, flags: string) => `${lead}mktemp${flags} '${templateOf(folder)}'`)
  return rewritten === line ? undefined : rewritten
}

// Whether the rewritten line reads exactly as the line did, apart from each
// bare mktemp gaining the template word: the same statements, the same words,
// redirects, heredocs and unknowns, in the same order.
export function readsAsPointed(before: ShellParse, after: ShellParse, folder: string): boolean {
  const template = templateOf(folder)
  if (!hasBareMktemp(before) || JSON.stringify(after.unknowns) !== JSON.stringify(before.unknowns)) return false
  if (after.statements.length !== before.statements.length) return false
  const expected = before.statements.map(s => (isBareMktemp(s) ? { ...s, words: [...s.words, template], args: [...s.args, template] } : s))
  return after.statements.every((s, i) => JSON.stringify(s) === JSON.stringify(expected[i]))
}

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
