#!/usr/bin/env node
import { judgeWrites, refusalOf, reviewBash, reviewEdit } from '../hooks/mods/review-guard.ts'
import { hasBareMktemp, pointMktemp, readsAsPointed } from '../hooks/mods/scratch.ts'
import { coreRoot, fromCore } from './core-root.mjs'
import { REVIEW_PASSES, REVIEW_REFUSALS } from './guard-cases.ts'

const { parseShell } = await fromCore('hooks/mods/shell.ts')

let passed = 0
let failed = 0
const check = (isGood, what) => {
  if (isGood) passed++
  else {
    failed++
    console.log(`  ❌ ${what}`)
  }
}
const show = line => JSON.stringify(line.length > 90 ? `${line.slice(0, 90)}…` : line)
const section = title => console.log(`── ${title} ${'─'.repeat(Math.max(4, 66 - title.length))}`)
const close = () => console.log(`  ${passed} passed, ${failed} failed so far`)

console.log(`workbench-core: ${coreRoot()}`)

section('review guard: a statement not placed is refused even with no unknown')
const unplaced = line => {
  const parse = parseShell(line)
  return { ...parse, unknowns: [], statements: parse.statements.map(s => ({ ...s, isPlaced: false })) }
}
const REVIEW_CONTEXT = { cwd: '/SB/repo', home: '/SB/home' }
check('finding' in reviewBash(unplaced('sudo -s rm x'), REVIEW_CONTEXT), 'the review guard refuses it')
close()

section('review guard: an open array or case, and the other unknowns, are refused')
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b)
for (const line of ['x=(a $(echo b)', 'case x in\n a) ls ;;']) {
  check(same(parseShell(line).unknowns, ['compound']), `the reader marks it: ${show(line)}`)
  const verdict = reviewBash(parseShell(line), REVIEW_CONTEXT)
  check('finding' in verdict && JSON.stringify(verdict.finding).includes('compound'), `the review guard refuses it: ${show(line)}`)
}
close()

section('review guard: a reviewer writes nothing outside scratch')
const SB = '/SB'
const DISK = {
  [SB]: 'dir',
  [`${SB}/repo`]: 'dir',
  [`${SB}/repo/README.md`]: 'file',
  [`${SB}/repo/file.txt`]: 'file',
  [`${SB}/repo/src`]: 'dir',
  [`${SB}/repo/src/a.txt`]: 'file',
  [`${SB}/repo/src/b.txt`]: 'file',
  [`${SB}/repo/link-out`]: { link: `${SB}/tmp/scratch/target.txt` },
  [`${SB}/tmp`]: 'dir',
  [`${SB}/tmp/scratch`]: 'dir',
  [`${SB}/tmp/scratch/target.txt`]: 'file',
  [`${SB}/tmp/link-into-tree`]: { link: `${SB}/repo/src` },
  [`${SB}/tmp/dangling`]: { link: `${SB}/repo/new.txt` },
  [`${SB}/home`]: 'dir',
  [`${SB}/home/Developer`]: 'dir',
  [`${SB}/home/Developer/scratchpad`]: 'dir',
}
function walk(path, hops = 0) {
  if (hops > 32) return undefined
  let at = ''
  for (const part of path.split('/').filter(p => p !== '' && p !== '.')) {
    if (part === '..') {
      at = at.slice(0, at.lastIndexOf('/'))
      continue
    }
    const next = `${at}/${part}`
    const entry = DISK[next]
    if (entry === undefined) return undefined
    if (typeof entry === 'object') {
      const landed = walk(entry.link.startsWith('/') ? entry.link : `${at}/${entry.link}`, hops + 1)
      if (landed === undefined) return undefined
      at = landed
    } else at = next
  }
  return at === '' ? '/' : at
}
const disk = {
  stat: async path => {
    const realPath = walk(path)
    return realPath === undefined ? undefined : { realPath }
  },
  names: async dir => (DISK[dir.replace(/\/+$/, '')] === 'dir' ? Object.keys(DISK).filter(p => p.slice(0, p.lastIndexOf('/')) === dir.replace(/\/+$/, '')).map(p => p.slice(p.lastIndexOf('/') + 1)) : undefined),
}
const ROOTS = [`${SB}/home/Developer/scratchpad`, `${SB}/tmp`]
const fill = line => line.replaceAll('@SANDBOX@', SB)

async function reviewRefusal(call, options = {}) {
  const { roots = ROOTS } = options
  const context = { cwd: 'cwd' in options ? options.cwd : `${SB}/repo`, home: `${SB}/home` }
  let verdict
  if (call.tool === 'Bash') {
    const parse = parseShell(call.command)
    verdict = reviewBash(parse, context)
  } else verdict = reviewEdit(call.tool, call.path ?? '', context)
  if ('finding' in verdict) return refusalOf(verdict.finding, roots)
  const finding = await judgeWrites(verdict.writes, roots, disk)
  return finding === undefined ? undefined : refusalOf(finding, roots)
}
const bash = command => ({ tool: 'Bash', command })

for (const line of REVIEW_REFUSALS) {
  const refusal = await reviewRefusal(bash(fill(line)))
  check(/A Holmes reviewer writes only in scratch/.test(refusal ?? ''), `refused: ${show(line)}`)
}
for (const line of REVIEW_PASSES) check((await reviewRefusal(bash(fill(line)))) === undefined, `passes: ${show(line)}`)
close()

section('review guard: paths are judged on the disk')
for (const [what, call, isRefused] of [
  ['a write through a scratch link into the tree', bash(`touch ${SB}/tmp/link-into-tree/new.txt`), true],
  ['a link in the tree removed where it lives, though it points into scratch', bash(`rm ${SB}/repo/link-out`), true],
  ['a write through a link that leads nowhere', bash(`echo x > ${SB}/tmp/dangling`), true],
  ['a write to a root itself', bash(`rm -rf ${SB}/tmp`), true],
  ['a new path several folders deep in scratch', bash(`mkdir -p ${SB}/tmp/a/b/c`), false],
  ['a path that climbs out of scratch', bash(`touch ${SB}/tmp/../repo/x`), true],
  ['a path with .. below what exists', bash(`touch ${SB}/tmp/new/../../repo/x`), true],
  ['$TMPDIR as a root', bash(`touch ${SB}/tmp/probe`), false],
  ["core's scratch root", bash(`touch ${SB}/home/Developer/scratchpad/probe`), false],
  ['~ expanded to HOME', bash('touch ~/Developer/scratchpad/probe'), false],
  ['a relative path in the tree', bash('touch new.txt'), true],
  ['a relative path after cd', bash(`cd ${SB}/tmp && touch new.txt`), true],
  ['a write to a variable', bash('touch "$DIR/x"'), true],
  ['an Edit in the tree', { tool: 'Edit', path: `${SB}/repo/README.md` }, true],
  ['an Edit in scratch', { tool: 'Edit', path: `${SB}/tmp/scratch/target.txt` }, false],
  ['a Write by a relative path in the tree', { tool: 'Write', path: 'notes.md' }, true],
  ['a Write with no path', { tool: 'Write' }, true],
  ['a NotebookEdit in scratch', { tool: 'NotebookEdit', path: `${SB}/tmp/n.ipynb` }, false],
  ['a NotebookEdit in the tree', { tool: 'NotebookEdit', path: `${SB}/repo/n.ipynb` }, true],
]) {
  check(((await reviewRefusal(call)) !== undefined) === isRefused, `${isRefused ? 'refused' : 'passes'}: ${what}`)
}
check((await reviewRefusal(bash(`touch ${SB}/tmp/probe`), { roots: [] }))?.includes('no scratch root was found'), 'with no scratch root at all, every write is refused')
check((await reviewRefusal(bash(`echo x >! ${SB}/repo/README.md`), { cwd: `${SB}/tmp` }))?.includes('cannot be resolved'), "zsh's >! takes the next word as its target")
check((await reviewRefusal(bash(`echo x >>!${SB}/repo/README.md`), { cwd: `${SB}/tmp` }))?.includes('outside the scratch roots'), "zsh's >>! writes outside scratch")
check((await reviewRefusal(bash(`echo x >!${SB}/tmp/probe`), { cwd: `${SB}/tmp` })) === undefined, "zsh's >! into scratch passes")
check((await reviewRefusal(bash('touch x'), { cwd: undefined }))?.includes('cannot be resolved'), 'with no working directory, a relative path is refused')
const named = (await reviewRefusal(bash(`chmod 644 ${SB}/repo/README.md`))) ?? ''
check(named.includes(`\`${SB}/home/Developer/scratchpad\`, \`${SB}/tmp\``), 'the refusal names the roots')
check(named.includes('Validate by running the existing tests in place and reading them.') && named.includes('copy no repository'), 'the refusal sends the reviewer to the tests in place')
check(!/runs on a copy|probe copy/.test(named), 'the refusal never offers a copy')
close()

section("scratch: a dev-team agent's bare mktemp is pointed at its folder")
const FOLDER = '/scratch/session/watson-direct.abc123'
const TEMPLATE = `'${FOLDER}/tmp.XXXXXXXX'`
const pointed = line => {
  if (!line.includes('mktemp')) return line
  const before = parseShell(line)
  if (!hasBareMktemp(before)) return line
  const after = pointMktemp(line, FOLDER)
  if (after === undefined) return line
  return readsAsPointed(before, parseShell(after), FOLDER) ? after : line
}
for (const [line, want] of [
  ['mktemp -d', `mktemp -d ${TEMPLATE}`],
  ['mktemp', `mktemp ${TEMPLATE}`],
  ['mktemp -dq', `mktemp -dq ${TEMPLATE}`],
  ['mktemp -d   # prints <checkout path>', `mktemp -d '${FOLDER}/tmp.XXXXXXXX'   # prints <checkout path>`],
  ['mktemp -d # a\necho b', `mktemp -d '${FOLDER}/tmp.XXXXXXXX' # a\necho b`],
  ['D=$(mktemp -d) && cd "$D"', `D=$(mktemp -d ${TEMPLATE}) && cd "$D"`],
  ['cp -R src "$(mktemp -d)"', `cp -R src "$(mktemp -d ${TEMPLATE})"`],
  ['A=$(mktemp -d); B=$(mktemp)', `A=$(mktemp -d ${TEMPLATE}); B=$(mktemp ${TEMPLATE})`],
]) {
  check(pointed(line) === want, `pointed: ${show(line)}`)
}
for (const line of [
  'mktemp -d -t probe',
  'mktemp -d /scratch/session/x.XXXXXX',
  'mktemp -p /tmp',
  'echo "run mktemp -d; then cd"',
  'mktemp -d && echo "then mktemp -d; done"',
  "cat <<'EOF'\nmktemp -d\nEOF",
  'env mktemp -d',
  'TMPDIR=/x mktemp -d',
  'if mktemp -d; then :; fi',
  'git status',
]) {
  check(pointed(line) === line, `runs as written: ${show(line)}`)
}
const echoed = 'echo "a; mktemp -d; b"'
check(pointMktemp(echoed, FOLDER) !== undefined && !readsAsPointed(parseShell(echoed), parseShell(pointMktemp(echoed, FOLDER) ?? ''), FOLDER), 'a quoted mktemp the text match reaches does not read back as pointed')
const mixed = 'mktemp -d && echo "then mktemp -d; done"'
check(!readsAsPointed(parseShell(mixed), parseShell(pointMktemp(mixed, FOLDER) ?? ''), FOLDER), 'a real mktemp beside a quoted one is left as written')
check(readsAsPointed(parseShell('mktemp -d'), parseShell(pointMktemp('mktemp -d', FOLDER) ?? ''), FOLDER), 'a plain bare mktemp reads back as pointed')
close()

console.log()
console.log(`${passed} passed, ${failed} failed`)
process.exit(failed === 0 ? 0 : 1)
