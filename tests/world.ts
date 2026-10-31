// The world beneath workbench-dev-team's hooks module in `claude plugin test`.
// The test's hooks stand for the engine and for workbench-core: they add a
// stand-in $.workbench noun, answer every spawn, model request and Agent call
// the module passes on, and record what reached them.
//
// The disk the guards stat is a map of paths, links included.

import { mock } from 'claude-code/testing'
import type { On } from 'claude-code'

import type { ShellParse, Statement } from '../hooks/mods/review-guard'

const UNPLAIN = /[$`\\(){}<\n#*?!]|(?<!&)&(?!&)|^\s*(?:if|then|for|while|until|case|do|function)\b/
const UNPLACED = new Set(['env', 'sudo', 'doas', 'nice', 'nohup', 'timeout', 'time', 'command', 'builtin', 'exec', 'xargs', 'stdbuf', 'caffeinate', 'noglob', 'bash', 'sh', 'zsh', 'eval', 'source', '.'])
const ASSIGNMENT = /^[A-Za-z_][A-Za-z0-9_]*=/
const VALUED: Record<string, ReadonlySet<string>> = {
  git: new Set(['-C', '-c', '--git-dir', '--work-tree', '--namespace']),
  gh: new Set(['-R', '--repo']),
}

function subcommandOf(name: string, args: readonly string[]): number {
  const valued = VALUED[name]
  if (valued === undefined) return -1
  for (let i = 0; i < args.length; i++) {
    const arg = args[i] ?? ''
    if (valued.has(arg)) i++
    else if (!arg.startsWith('-')) return i
  }
  return -1
}

function statementOf(tokens: readonly string[], isCertain: boolean): Statement {
  const words: string[] = []
  const redirects: { op: string; fd: string; target: string; isReal: boolean }[] = []
  for (let i = 0; i < tokens.length; i++) {
    const redirect = /^([0-9]*)(>>?)$/.exec(tokens[i] ?? '')
    if (redirect === null) words.push(tokens[i] ?? '')
    else redirects.push({ op: redirect[2] ?? '>', fd: redirect[1] ?? '', target: tokens[++i] ?? '', isReal: true })
  }
  const nameAt = words.findIndex(word => !ASSIGNMENT.test(word))
  const name = nameAt < 0 ? '' : (words[nameAt]?.split('/').pop() ?? '').toLowerCase()
  if (UNPLACED.has(name)) throw new Error(`the stand-in reader does not place ${name}: test this line in tests/guards.mjs`)
  const args = nameAt < 0 ? [] : words.slice(nameAt + 1)
  return {
    words,
    nameAt,
    name,
    args,
    assignments: nameAt < 0 ? words : words.slice(0, nameAt),
    wrappers: [],
    subcommandAt: subcommandOf(name, args),
    isPlaced: true,
    escaped: [],
    isCertain,
    redirects,
    heredocs: [],
    source: 'line',
    depth: 0,
  } as Statement
}

export function readPlain(line: string): ShellParse {
  if (UNPLAIN.test(line)) throw new Error(`the stand-in reader reads plain lines only: test ${JSON.stringify(line)} in tests/guards.mjs`)
  const statements: Statement[] = []
  let tokens: string[] = []
  let word: string | undefined
  let isCertain = true
  const endWord = () => {
    if (word !== undefined) tokens.push(word)
    word = undefined
  }
  const endStatement = () => {
    endWord()
    if (tokens.length > 0) statements.push(statementOf(tokens, isCertain))
    tokens = []
  }
  for (let i = 0; i < line.length; i++) {
    const c = line[i] ?? ''
    if (c === "'" || c === '"') {
      const close = line.indexOf(c, i + 1)
      if (close < 0) throw new Error(`the stand-in reader found an open quote in ${JSON.stringify(line)}`)
      word = (word ?? '') + line.slice(i + 1, close)
      i = close
    } else if (c === ' ' || c === '\t') {
      endWord()
    } else if (c === ';' || c === '|' || c === '&') {
      endStatement()
      if (c !== ';' && line[i + 1] === c) {
        isCertain = false
        i++
      }
    } else if (c === '>') {
      const fd = word !== undefined && /^[0-9]+$/.test(word) ? word : ''
      if (fd === '') endWord()
      word = undefined
      const op = line[i + 1] === '>' ? '>>' : '>'
      i += op.length - 1
      tokens.push(`${fd}${op}`)
    } else {
      word = (word ?? '') + c
    }
  }
  endStatement()
  return { statements, unknowns: [] } as ShellParse
}

export const HOME = '/Users/tester'
export const SESSION_ID = 's-1'
export const CONFIG_PATH = `${HOME}/.claude-workbench/dev-team-config.json`

export const BRIEF = [
  'Workdir: /tmp/repo',
  'Goal: Fix the parser.',
  'Context: It drops a field.',
  'Constraints: none',
  'Acceptance:',
  '- AC1: the field survives',
  'Done when: the test passes.',
].join('\n')

type Lane = 'main' | 'sub-agent' | 'top-level-agent'

export type World = {
  // What callerLane answers, by the agentId it is asked about. An Error rejects.
  lane: (agentId: string | undefined) => Lane | Error
  isOn: boolean | Error
  files: Map<string, string>
  // Each spawn that reached the engine: its type, model and prompt.
  spawned: { subagentType: string; model?: string; prompt: string }[]
  // Each model request that reached the engine: its loop and effort.
  steps: { agentId?: string; effort?: unknown }[]
  // What the engine answers to an Agent call.
  agentCall: 'ok' | 'error'
  nextAgentId: number
  // Each tool call that reached the engine: its tool and command or path.
  ran: string[]
  // Each tool call that reached the engine, as its whole input.
  calls: Record<string, unknown>[]
  // Each $.process.run the module made, as its argv.
  runs: string[][]
  // Each $.process.run's timeoutMs, in the same order as runs.
  timeouts: (number | undefined)[]
  // Folders the stand-in mktemp made and rm has not removed.
  made: Set<string>
  // Makes scratchRoots reject, from the moment a test sets it.
  rootsFail: boolean
  // Each toast and transcript line the module showed.
  shown: string[]
  // Each model request's usage, in order, as the stand-in engine reports it.
  usage: ({ input_tokens: number; output_tokens: number; cache_read_input_tokens: number; cache_creation_input_tokens: number; model: string } | null)[]
  background: string[]
  sizes: Map<string, number>
  writeRejects?: (path: string) => boolean
}

// What a stand-in process.run answers.
export type RunAnswer = { exitCode: number; stdout: string; stderr: string } | Error

// A disk entry: a directory, a file, or a symbolic link to a path.
export type Entry = 'dir' | 'file' | { link: string }

// What the guard tests set in the world beneath the module.
export type GuardOptions = {
  // The environment $.env.get answers.
  env?: Record<string, string>
  // What scratchRoots answers.
  roots?: string[]
  // What $.agent.list() answers: each loop's id, type and parent. An Error rejects.
  // A loop's status is running unless the entry names one.
  agents?: { id: string; type: string; parentId?: string; status?: string }[] | Error
  // What $.session.cwd() answers.
  cwd?: string
  sessionId?: string
  // The disk, by absolute path.
  disk?: Record<string, Entry>
  // Makes parseShell reject.
  parseFails?: boolean
  // Answers $.process.run. Return undefined to take the default: git exits
  // 128 (not a repository), mktemp makes `<template with XXXXXX as abc123>`,
  // and anything else exits 0 with no output.
  run?: (argv: readonly string[]) => RunAnswer | undefined
  tools?: (input: Record<string, unknown>) => { text?: string; isError?: boolean; result?: unknown } | undefined
}

// Where `path` lands on `disk`, every link followed, or undefined when it
// leads nowhere.
function walk(disk: Record<string, Entry>, path: string, hops = 0): string | undefined {
  if (hops > 32) return undefined
  const parts = path.split('/').filter(part => part !== '' && part !== '.')
  let at = ''
  for (let i = 0; i < parts.length; i++) {
    const part = parts[i] ?? ''
    if (part === '..') {
      at = at.slice(0, at.lastIndexOf('/'))
      continue
    }
    const next = `${at}/${part}`
    const entry = disk[next]
    if (entry === undefined) return undefined
    if (typeof entry === 'object') {
      const target = entry.link.startsWith('/') ? entry.link : `${at}/${entry.link}`
      const landed = walk(disk, target, hops + 1)
      if (landed === undefined) return undefined
      at = landed
    } else {
      at = next
    }
  }
  return at === '' ? '/' : at
}

export function world(
  on: On,
  options: Partial<Pick<World, 'lane' | 'isOn'>> & { config?: string; envFails?: boolean; isHomeUnset?: boolean } & GuardOptions = {},
): World {
  const w: World = {
    lane: options.lane ?? (agentId => (agentId === undefined ? 'main' : 'sub-agent')),
    isOn: options.isOn ?? true,
    files: new Map(options.config === undefined ? [] : [[CONFIG_PATH, options.config]]),
    spawned: [],
    steps: [],
    agentCall: 'ok',
    nextAgentId: 1,
    ran: [],
    calls: [],
    runs: [],
    timeouts: [],
    made: new Set(),
    rootsFail: false,
    shown: [],
    usage: [],
    background: [],
    sizes: new Map(),
  }
  const disk: Record<string, Entry> = { ...(options.disk ?? {}) }
  if (options.envFails) {
    on('env.get', async () => {
      throw new Error('env unreadable')
    })
  } else {
    mock.env(on, { ...(options.isHomeUnset ? {} : { HOME }), ...(options.env ?? {}) })
  }

  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    const answer = <T>(value: T | Error): Promise<T> => (value instanceof Error ? Promise.reject(value) : Promise.resolve(value))
    return {
      ...built,
      workbench: {
        scratchRoots: async () => (w.rootsFail ? Promise.reject(new Error('no roots')) : (options.roots ?? [])),
        orchestratorIsOn: async () => answer(w.isOn),
        callerLane: async (args: { agentId?: string }) => answer(w.lane(args.agentId)),
        parseShell: async (line: string) => (options.parseFails ? Promise.reject(new Error('unreadable')) : readPlain(line)),
      },
    } as never
  })

  on('fs.read', async ($, e) => {
    const text = w.files.get(e.path)
    if (text === undefined) throw new Error(`ENOENT: ${e.path}`)
    return { value: text }
  })

  on('fs.stat', async ($, e) => {
    const size = w.sizes.get(e.path)
    if (size !== undefined) return { value: { kind: 'file', size, mtimeMs: 0, isLink: false } } as never
    const landed = walk(disk, e.path)
    if (landed === undefined) throw new Error(`ENOENT: ${e.path}`)
    const own = disk[e.path.replace(/\/+$/, '')]
    return { value: { kind: landed === '/' || disk[landed] === 'dir' ? 'dir' : 'file', size: 0, mtimeMs: 0, isLink: typeof own === 'object', ...(e.resolve ? { realPath: landed } : {}) } } as never
  })

  on('fs.list', async ($, e) => {
    const dir = e.path.replace(/\/+$/, '')
    if (dir !== '' && disk[dir] !== 'dir') throw new Error(`ENOTDIR: ${e.path}`)
    const names = Object.keys(disk).filter(p => p.slice(0, p.lastIndexOf('/')) === dir).map(p => p.slice(p.lastIndexOf('/') + 1))
    return { value: names.map(name => ({ name, kind: 'other', size: 0, mtimeMs: 0 })) } as never
  })

  on('agent.list', async () => {
    if (options.agents instanceof Error) throw options.agents
    return { value: (options.agents ?? []).map(a => ({ description: 'a task', status: 'running', ...a })) } as never
  })

  on('process.run', async ($, e) => {
    w.runs.push([...e.argv])
    w.timeouts.push(e.init?.timeoutMs)
    const answer = options.run?.(e.argv) ?? defaultRun(w, e.argv)
    if (answer instanceof Error) throw answer
    return { value: { ...answer, isStdoutTruncated: false, isStderrTruncated: false } }
  })

  on('fs.exists', async ($, e) => ({ value: w.made.has(e.path) || disk[e.path] !== undefined }))

  on('fs.write', async ($, e) => {
    if (w.writeRejects?.(e.path)) throw new Error(`EACCES: ${e.path}`)
    w.files.set(e.path, e.text)
    return { value: undefined }
  })

  on('session.id', async () => ({ value: options.sessionId ?? SESSION_ID }))

  on('ui.toast', async ($, e) => {
    w.shown.push(`toast: ${e.text}`)
    return { value: undefined }
  })

  on('ui.log', async ($, e) => {
    w.shown.push(`${e.to}: ${e.text}`)
    return { value: undefined }
  })

  on('session.cwd', async () => {
    if (options.cwd === undefined) throw new Error('no cwd')
    return { value: options.cwd }
  })

  on('agent.spawn', async ($, e) => {
    w.spawned.push({ subagentType: e.subagentType, model: e.model, prompt: e.prompt })
    return { model: e.model ?? 'inherit', agentId: `agent-${w.nextAgentId++}` }
  })

  on('turn.step', async function* ($, e) {
    w.steps.push({ agentId: e.agentId, effort: e.effort })
    const usage = w.usage.shift() ?? null
    yield { kind: 'stop' as const, stopReason: 'end_turn' as const, usage }
    return { turnId: e.turnId, index: e.index, answer: '', toolUses: [], stopReason: 'end_turn' as const, usage }
  })

  on('turn.complete', async ($, e) => ({ text: e.answer }))

  on('session.end', async ($, e) => ({ sessionId: e.sessionId }))

  on('tool.call', async ($, e) => {
    const input = e as { tool: string; command?: unknown; file_path?: unknown; notebook_path?: unknown }
    w.ran.push(`${input.tool}: ${String(input.command ?? input.file_path ?? input.notebook_path ?? '')}`)
    w.calls.push({ ...(e as Record<string, unknown>) })
    if (w.agentCall === 'error') return { isError: true, result: 'boom', text: 'boom' } as never
    const answered = options.tools?.(e as Record<string, unknown>)
    if (answered !== undefined) return answered as never
    const backgroundTaskId = input.tool === 'Bash' ? w.background.shift() : undefined
    const text = `Command running in background with ID: ${backgroundTaskId}. Output is being written to: /tasks/${backgroundTaskId}.output. You will be notified when it completes.`
    if (backgroundTaskId !== undefined) return { result: { stdout: '', stderr: '', interrupted: false, backgroundTaskId }, text } as never
    return { result: { status: 'completed' } } as never
  })

  return w
}

// The stand-in host: git finds no repository, mktemp makes its folder with
// abc123 for the X run, rm removes what mktemp made, and anything else exits 0.
function defaultRun(w: World, argv: readonly string[]): RunAnswer {
  if (argv[0] === 'git') return { exitCode: 128, stdout: '', stderr: 'fatal: not a git repository' }
  if (argv[0] === 'mktemp') {
    const folder = (argv[argv.length - 1] ?? '').replace(/X+$/, 'abc123')
    w.made.add(folder)
    return { exitCode: 0, stdout: `${folder}\n`, stderr: '' }
  }
  if (argv[0] === 'rm') for (const path of argv.slice(argv.indexOf('--') + 1)) w.made.delete(path)
  return { exitCode: 0, stdout: '', stderr: '' }
}

// The input of agent.spawn as the Agent tool's call site passes it.
export function spawnInput(subagentType: string, prompt: string, extra: Record<string, unknown> = {}) {
  return {
    tool_use_id: `toolu_${subagentType}`,
    prompt,
    description: 'a task',
    subagentType,
    provider: { plugin: 'workbench-dev-team', tier: 'user' },
    parentModel: 'claude-opus-5-5[1m]',
    background: true,
    fork: false,
    ...extra,
  } as never
}

// One model request in the loop `agentId` names (main when undefined), read to
// its end as the engine would.
export async function step($: { turn: { step: (e: never) => AsyncGenerator<unknown, unknown> } }, agentId?: string, effort?: string): Promise<void> {
  const stream = $.turn.step({ turnId: 't', index: 0, model: 'm', messageCount: 1, agentId, effort } as never)
  let read = await stream.next()
  while (!read.done) read = await stream.next()
}

// The end of a run in the loop `agentId` names (main when undefined).
export async function complete($: { turn: { complete: (e: never) => Promise<unknown> } }, agentId?: string): Promise<void> {
  await $.turn.complete({ answer: '', durationMs: 0, isAborted: false, turnId: 't', reason: 'answer', ...(agentId === undefined ? {} : { agentId }) } as never)
}

// The end of the session, as the engine raises it on exit.
export async function endSession($: { session: { end: (e: never) => Promise<unknown> } }): Promise<void> {
  await $.session.end({ reason: 'prompt_input_exit', sessionId: 's-1', resume: { id: 's-1' } } as never)
}

// A request's usage whose working context is `tokens`, most of it cached.
export const usageOf = (tokens: number) => ({
  input_tokens: 10,
  output_tokens: 100,
  cache_read_input_tokens: tokens - 1010,
  cache_creation_input_tokens: 1000,
  model: 'claude-opus-5-5',
})
