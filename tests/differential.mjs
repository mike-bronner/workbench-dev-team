#!/usr/bin/env node
import { spawn, spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

import { judgeWrites, reviewBash } from '../hooks/mods/review-guard.ts'
import { fromCore } from './core-root.mjs'
import { COMMIT_PASSES, REVIEW_PASSES, REVIEW_REFUSALS } from './guard-cases.ts'
import { HOSTILE, REVIEW_SUITE, REVIEW_TREE } from './guard-corpus.ts'

const { parseShell } = await fromCore('hooks/mods/shell.ts')
const { LET_THROUGH } = await fromCore('tests/commit-corpus.ts')

const HERE = path.dirname(fileURLToPath(import.meta.url))
const ORACLE = path.join(HERE, 'oracle')
const RECORD = path.join(ORACLE, 'over-counted.json')
const isUpdate = process.argv.includes('--update')
// --stricter lists the named lines a port refuses and its oracle let through.
const isStricter = process.argv.includes('--stricter')
const JOBS = Math.max(4, os.availableParallelism?.() ?? 8)

let failures = 0
const ok = message => console.log(`  ✅ ${message}`)
const bad = message => {
  failures++
  console.log(`  ❌ ${message}`)
}
const show = line => JSON.stringify(line)

// ── The oracles are the frozen bash guards ────────────────────────────────────

console.log('── the oracles ─────────────────────────────────────────────────────────')
const source = fs.readFileSync(path.join(ORACLE, 'SOURCE'), 'utf8')
for (const [, hash, file] of source.matchAll(/^([0-9a-f]{64}) (\S+)$/gm)) {
  const copy = path.join(ORACLE, path.basename(file))
  const now = createHash('sha256').update(fs.readFileSync(copy)).digest('hex')
  if (now === hash) ok(`${path.basename(file)} is the frozen ${file}`)
  else bad(`${path.basename(file)} was edited: the oracle must stay the guard it froze`)
}

// ── Lines ─────────────────────────────────────────────────────────────────────

// mulberry32: the same seed gives the same lines on every run.
function generator(seed) {
  let state = seed >>> 0
  return () => {
    state = (state + 0x6d2b79f5) >>> 0
    let t = state
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

function randomLines(tokens, seed, count) {
  const random = generator(seed)
  const pick = xs => xs[Math.floor(random() * xs.length)]
  const separators = [' ', ' ', ' ', '', '\n', ';']
  const lines = []
  for (let n = 0; n < count; n++) {
    const length = 2 + Math.floor(random() * 10)
    let line = ''
    for (let k = 0; k < length; k++) line += (k ? pick(separators) : '') + pick(tokens)
    lines.push(line)
  }
  return lines
}

const REVIEW_TOKENS = [
  'chmod', '644', 'rm', '-rf', 'README.md', 'file.txt', 'x', 'src', '@SANDBOX@/tmp/scratch/a', '@SANDBOX@/repo/a', '@SANDBOX@/home/x',
  '@SANDBOX@/tmp/link-into-tree/n', '/tmp/x', '~/x', '>', '>>', '2>&1', '>&2', '<', '|', '&&', '||', ';', '\n', '&', "'", '"', '\\',
  '$(', ')', '`', '(', '{', '}', 'sed', '-i', "''", "'s/a/b/'", "'s/=>/->/'", "'w out'", 'perl', '-pi', '-e', 'awk',
  "'{print > \"o\"}'", "'$1 > 2'", 'cp', 'mv', 'tee', 'mkdir', '-p', 'touch', 'git', 'status', 'restore', 'diff', 'log', 'stash',
  'checkout', '--', '-c', 'cat', '<<EOF', "<<'EOF'", 'EOF', 'echo', 'grep', 'xargs', 'find', '.', '-exec', '-delete', '{}', '\\;',
  'cd', 'env', 'sudo', 'nice', 'bash', 'sh', 'eval', '$x', 'x=1', '((', '))', '[[', ']]', '#', 'npx', 'prettier', '-w', 'black',
  '--check', 'tar', 'xf', 'a.tar', 'ln', '-s', 'dd', 'of=README.md', 'trap', 'EXIT', 'timeout', '5', 'parallel', ':::', 'command',
  '-v', 'exec', 'case', 'in', 'esac', 'if', 'then', 'fi', 'unbuffer', 'setsid', 'cp file.txt @SANDBOX@/tmp/scratch/',
]

const unique = lines => [...new Set(lines)]

const REPO = '@SANDBOX@/repo'
const REVIEW_NAMED = unique(
  [
    ...REVIEW_PASSES.map(line => [line, REPO]), ...REVIEW_REFUSALS.map(line => [line, REPO]), ...HOSTILE.map(line => [line, REPO]),
    ...REVIEW_SUITE, ...COMMIT_PASSES.map(line => [line, REPO]), ...LET_THROUGH.map(line => [line, REPO]),
  ].map(pair => JSON.stringify(pair)),
).map(pair => JSON.parse(pair))
const REVIEW_RANDOM = unique([1, 2, 3].flatMap(seed => randomLines(REVIEW_TOKENS, seed, 1000))).map(line => [line, REPO])

// ── The sandbox ───────────────────────────────────────────────────────────────

const WORK = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'guard-differential.')))
process.on('exit', () => fs.rmSync(WORK, { recursive: true, force: true }))

function buildTree(root) {
  fs.mkdirSync(root, { recursive: true })
  for (const [kind, rel, target] of REVIEW_TREE) {
    const at = path.join(root, rel)
    if (kind === 'd') fs.mkdirSync(at, { recursive: true })
    else if (kind === 'f') fs.writeFileSync(at, 'a\n')
    else fs.symlinkSync(target.replaceAll('@SANDBOX@', root), at)
  }
  for (const file of ['repo/README.md', 'repo/file.txt', 'repo/src/a.txt', 'repo/src/b.txt']) fs.writeFileSync(path.join(root, file), 'a\n')
}

const SANDBOX = path.join(WORK, 'sandbox')
buildTree(SANDBOX)
const ROOTS = [path.join(SANDBOX, 'home/Developer/scratchpad'), path.join(SANDBOX, 'tmp')]
const fill = text => text.replaceAll('@SANDBOX@', SANDBOX)

// The disk as review-guard.ts reads it.
const disk = {
  stat: async p => {
    try {
      fs.statSync(p)
    } catch {
      return undefined
    }
    try {
      return { realPath: fs.realpathSync(p) }
    } catch {
      return { realPath: undefined }
    }
  },
  names: async dir => {
    try {
      return fs.readdirSync(dir)
    } catch {
      return undefined
    }
  },
}

// ── Running the oracles ───────────────────────────────────────────────────────

function run(argv, input, env) {
  return new Promise(resolve => {
    const child = spawn(argv[0], argv.slice(1), { env, stdio: ['pipe', 'pipe', 'pipe'] })
    let out = ''
    child.stdout.on('data', chunk => (out += chunk))
    child.stderr.on('data', () => {})
    child.on('close', () => resolve(out))
    child.stdin.end(input)
  })
}

async function pool(items, work) {
  const results = new Array(items.length)
  let next = 0
  await Promise.all(
    Array.from({ length: JOBS }, async () => {
      while (next < items.length) {
        const i = next++
        results[i] = await work(items[i])
      }
    }),
  )
  return results
}

const isDeny = out => /"permissionDecision": *"deny"/.test(out)
const baseEnv = { ...process.env }
delete baseEnv.WORKBENCH_DEV_TEAM_PIPELINE

const reviewEnv = { ...baseEnv, HOME: path.join(SANDBOX, 'home'), TMPDIR: path.join(SANDBOX, 'tmp') }
function reviewOracle(line, cwd) {
  const payload = {
    hook_event_name: 'PreToolUse', tool_name: 'Bash', session_id: 'session-A', agent_id: 'agent-1',
    agent_type: 'workbench-dev-team:holmes-lens', tool_input: { command: line },
  }
  if (cwd) payload.cwd = cwd
  return run(['bash', path.join(ORACLE, 'local-review-guard.sh')], JSON.stringify(payload), reviewEnv).then(isDeny)
}

async function reviewPort(line, cwd) {
  const verdict = reviewBash(parseShell(line), { cwd: cwd || undefined, home: path.join(SANDBOX, 'home') })
  if ('finding' in verdict) return true
  return (await judgeWrites(verdict.writes, ROOTS, disk)) !== undefined
}

// ── Running a line for real ───────────────────────────────────────────────────

const HAS_SANDBOX = fs.existsSync('/usr/bin/sandbox-exec') && fs.existsSync('/bin/zsh')

// git's global options that take the next word, as git reads them.
const GIT_GLOBAL_VALUES = new Set(['-C', '-c', '--git-dir', '--work-tree', '--namespace', '--super-prefix', '--config-env', '--exec-path'])
// git verbs that write nothing beside their output.
const READ_VERBS = new Set([
  'status', 'diff', 'log', 'show', 'blame', 'grep', 'ls-files', 'ls-tree', 'rev-parse', 'rev-list', 'cat-file', 'describe',
  'shortlog', 'merge-base', 'name-rev', 'for-each-ref', 'show-ref', 'reflog', 'whatchanged', 'annotate', 'archive',
])

// What one recorded git call did: its verb, the words after it, and the
// configuration it was handed. A `-c alias.<verb>=<value>` is followed.
function gitCall(argv) {
  const config = []
  let i = 0
  for (; i < argv.length; i++) {
    const arg = argv[i]
    if (GIT_GLOBAL_VALUES.has(arg)) {
      if (arg === '-c') config.push(argv[i + 1] ?? '')
      i++
    } else if (arg.startsWith('-c') && arg.length > 2) config.push(arg.slice(2))
    else if (!arg.startsWith('-')) break
  }
  let verb = (argv[i] ?? '').toLowerCase()
  let rest = argv.slice(i + 1)
  const alias = config.find(c => c.toLowerCase().startsWith(`alias.${verb}=`))
  if (alias !== undefined) {
    const value = alias.slice(alias.indexOf('=') + 1).trim()
    if (value.startsWith('!')) return { verb: '!', rest, config }
    const words = value.split(/\s+/)
    verb = (words[0] ?? '').toLowerCase()
    rest = [...words.slice(1), ...rest]
  }
  return { verb, rest, config }
}

// The tree outside the scratch roots and the shim, as a map from path to what
// is there, to tell whether a run wrote to it.
function snapshot(root, skip) {
  const seen = new Map()
  const walk = dir => {
    let names
    try {
      names = fs.readdirSync(dir)
    } catch {
      return
    }
    for (const name of names) {
      const at = path.join(dir, name)
      if (skip.includes(at)) continue
      let st
      try {
        st = fs.lstatSync(at)
      } catch {
        continue
      }
      const link = st.isSymbolicLink() ? fs.readlinkSync(at) : ''
      const body = st.isFile() ? fs.readFileSync(at, 'utf8') : ''
      seen.set(at, `${st.mode}:${st.size}:${link}:${body}`)
      if (st.isDirectory()) walk(at)
    }
  }
  walk(root)
  return seen
}

const sameSnapshot = (a, b) => a.size === b.size && [...a].every(([k, v]) => b.get(k) === v)

// Shims: git and gh record their words, sudo and doas run what follows their
// options, as the real ones would after a password.
const RECORDER = record => `#!/bin/sh\n{ printf '%s' "$(basename "$0")"; for a in "$@"; do printf '\\037%s' "$a"; done; printf '\\036'; } >> '${record}'\n`
const RUNNER = `#!/bin/sh
while [ $# -gt 0 ]; do
  case "$1" in
    -u|-g|-C|-D|-h|-p|-r|-t|-U|-T|-a) shift 2 ;;
    --) shift; break ;;
    -*) shift ;;
    *) break ;;
  esac
done
[ $# -gt 0 ] && exec "$@"
`

// A git or gh the line names by an absolute path. The run puts the shim in
// its place, since only the program differs: bash and zsh exec what the line
// names. A spelling this misses runs into the sandbox's exec denial, which is
// counted as the guarded command.
const REAL_TOOL = /(?<![\w./-])\/[\w./-]*\/(git|gh)(?![\w./-])/gi

function runFor(line, cwd = '') {
  const runs = []
  for (const shell of [['/bin/bash', '-c'], ['/bin/zsh', '-f', '-c']]) {
    const facts = { git: [], wrote: false }
    runs.push(facts)
    const box = fs.realpathSync(fs.mkdtempSync(path.join(WORK, 'run.')))
    buildTree(box)
    const shim = path.join(box, '.shim')
    fs.mkdirSync(shim)
    const record = path.join(shim, 'record')
    for (const name of ['git', 'gh']) fs.writeFileSync(path.join(shim, name), RECORDER(record), { mode: 0o755 })
    for (const name of ['sudo', 'doas']) fs.writeFileSync(path.join(shim, name), RUNNER, { mode: 0o755 })
    const profile = path.join(shim, 'profile.sb')
    fs.writeFileSync(
      profile,
      [
        '(version 1)',
        '(allow default)',
        '(deny network*)',
        `(deny file-write* (require-not (require-any (subpath "${box}") (literal "/dev/null") (literal "/dev/tty") (literal "/dev/stdout") (literal "/dev/stderr") (regex #"^/dev/fd/"))))`,
        '(deny process-exec (regex #"/(git|gh|sudo|doas)(-[^/]*)?$"))',
        `(allow process-exec (subpath "${shim}"))`,
      ].join('\n'),
    )
    const scratch = [path.join(box, 'tmp'), path.join(box, 'home/Developer/scratchpad'), shim]
    const before = snapshot(box, scratch)
    const text = line.replaceAll('@SANDBOX@', box).replace(REAL_TOOL, (_, name) => path.join(shim, name.toLowerCase()))
    const result = spawnSync('/usr/bin/sandbox-exec', ['-f', profile, ...shell, text], {
      cwd: cwd ? cwd.replaceAll('@SANDBOX@', box) : path.join(box, 'repo'),
      env: { PATH: `${shim}:/usr/bin:/bin`, HOME: path.join(box, 'home'), TMPDIR: path.join(box, 'tmp'), TMPPREFIX: path.join(box, 'tmp/zsh'), LANG: 'C' },
      input: '',
      timeout: 5000,
      encoding: 'utf8',
    })
    const stderr = result.stderr ?? ''
    const calls = { git: [], gh: [] }
    for (const entry of (fs.existsSync(record) ? fs.readFileSync(record, 'utf8') : '').split('\x1e')) {
      if (entry === '') continue
      const [name, ...argv] = entry.split('\x1f')
      calls[name === 'gh' ? 'gh' : 'git'].push(argv)
    }
    facts.git.push(...calls.git)
    // A write the sandbox refused was a write outside the box.
    facts.wrote ||= /operation not permitted/i.test(stderr) || !sameSnapshot(before, snapshot(box, scratch))
    for (const argv of calls.git) {
      const { verb, rest } = gitCall(argv)
      if (!READ_VERBS.has(verb)) facts.wrote = true
      // git archive and git's --output write the file they name.
      rest.forEach((arg, i) => {
        const out = arg.startsWith('--output=') ? arg.slice(9) : arg === '--output' || (verb === 'archive' && arg === '-o') ? rest[i + 1] : undefined
        if (out === undefined) return
        const at = path.resolve(path.join(box, 'repo'), out)
        if (!scratch.slice(0, 2).some(root => at.startsWith(`${root}/`))) facts.wrote = true
      })
    }
    fs.rmSync(box, { recursive: true, force: true })
  }
  return runs
}

// ── Comparing ─────────────────────────────────────────────────────────────────

const record = fs.existsSync(RECORD) ? JSON.parse(fs.readFileSync(RECORD, 'utf8')) : { review: [] }
const next = { review: [] }

console.log('── the controls ────────────────────────────────────────────────────────')
if (await reviewOracle(`chmod 644 ${SANDBOX}/repo/README.md`, `${SANDBOX}/repo`)) ok("the review oracle refuses a reviewer's chmod")
else bad("the review oracle did not refuse a reviewer's chmod: is python3 on PATH?")
if (!(await reviewOracle('git status', `${SANDBOX}/repo`))) ok("the review oracle lets a reviewer's git status through")
else bad("the review oracle refused a reviewer's git status")

// The sandbox runs must be able to find the guarded command, or every line
// would read as an over-count.
if (HAS_SANDBOX) {
  for (const [line, want] of [['chmod 600 README.md', true], ['git restore .', true], ['echo x > @SANDBOX@/tmp/x', false], ['git status', false], ['echo x > /etc/nope', true]]) {
    const got = runFor(line).some(facts => facts.wrote)
    if (got === want) ok(`a sandbox run of ${show(line)} ${want ? 'writes' : 'does not write'} outside scratch`)
    else bad(`a sandbox run of ${show(line)} was misread`)
  }
}

async function compareReview(label, cases) {
  const filled = cases.map(([line, cwd]) => [fill(line), fill(cwd)])
  const oracle = await pool(filled, ([line, cwd]) => reviewOracle(line, cwd))
  let stricter = 0
  let lower = 0
  for (let i = 0; i < cases.length; i++) {
    const [line, cwd] = filled[i]
    const port = await reviewPort(line, cwd)
    if (oracle[i] && !port) {
      lower++
      next.review.push({ line: cases[i][0], cwd: cases[i][1] })
    }
    if (!oracle[i] && port) {
      stricter++
      if (isStricter && label.startsWith('named')) console.log(`     stricter (cwd ${cases[i][1]}): ${show(cases[i][0])}`)
    }
  }
  console.log(`  ${label}: ${cases.length} lines; the port refuses less on ${lower}, more on ${stricter}`)
}

console.log('── the review guard ────────────────────────────────────────────────────')
await compareReview('named lines (dev-team cases, hostile corpus, core reads)', REVIEW_NAMED)
await compareReview('random lines, seeds 1 to 3', REVIEW_RANDOM)

// ── Deciding the lines the port refuses less ──────────────────────────────────

console.log('── where a port refuses less, bash and zsh decide ─────────────────────')
const key = item => JSON.stringify(item)
const sort = items => [...items].sort((a, b) => (key(a) < key(b) ? -1 : 1))
next.review = sort(next.review)
if (HAS_SANDBOX) {
  let ran = 0
  for (const item of next.review) {
    if (runFor(item.line, item.cwd).some(facts => facts.wrote)) {
      ran++
      bad(`the review guard lets through a line that writes outside scratch in bash or zsh (cwd ${item.cwd}): ${show(item.line)}`)
    }
  }
  if (ran === 0) ok(`${next.review.length} lines the port refuses less were run in bash and zsh, and none wrote outside scratch`)
  if (isUpdate) {
    fs.writeFileSync(RECORD, `${JSON.stringify(next, null, 2)}\n`)
    ok('tests/oracle/over-counted.json rewritten')
  } else if (key(record) === key(next)) {
    ok('the oracles over-count exactly the lines tests/oracle/over-counted.json records')
  } else {
    const was = new Set(record.review.map(key))
    const now = new Set(next.review.map(key))
    for (const item of now) if (!was.has(item)) bad(`not in tests/oracle/over-counted.json: ${item}`)
    for (const item of was) if (!now.has(item)) bad(`recorded, but no longer over-counted: ${item}`)
    console.log('     review the lines, then run: node tests/differential.mjs --update')
  }
} else {
  console.log('  ⏭️  sandbox-exec or zsh is missing, so no line is run: each must be in the record')
  const was = new Set(record.review.map(key))
  const missing = next.review.filter(item => !was.has(key(item)))
  for (const item of missing) bad(`a port refuses less than its oracle on a line no sandbox run has decided: ${key(item)}`)
  if (missing.length === 0) ok('every line a port refuses less was decided by an earlier sandbox run')
}

console.log(`\n${failures === 0 ? 'differential green' : `${failures} failed`}`)
process.exit(failures === 0 ? 0 : 1)
