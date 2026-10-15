#!/usr/bin/env node
import { BUILT_REFUSAL, PLAIN_REFUSAL, commitVerdict } from '../hooks/mods/commit-guard.ts'
import { subjectVerdict } from '../hooks/mods/commit-subject.ts'
import { judgeWrites, refusalOf, reviewBash, reviewEdit } from '../hooks/mods/review-guard.ts'
import { hasBareMktemp, pointMktemp, readsAsPointed } from '../hooks/mods/scratch.ts'
import { coreRoot, fromCore } from './core-root.mjs'
import { COMMIT_MAIN_PASSES, COMMIT_PASSES, COMMIT_REFUSALS, GREP_READS, GREP_WRITES, REVIEW_PASSES, REVIEW_REFUSALS } from './guard-cases.ts'

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

const CALLERS = {
  main: { lane: 'main', isUnattended: false },
  'sub-agent': { lane: 'sub-agent', isUnattended: false },
  pipeline: { lane: 'top-level-agent', isUnattended: true },
}
const LANES = ['main', 'sub-agent', 'pipeline']
const verdictOf = (line, caller) => {
  const parse = parseShell(line)
  return commitVerdict(parse, line, caller) ?? subjectVerdict(parse)
}

section('commit guard: the spellings review rounds found stay refused')
for (const [line, lanes] of COMMIT_REFUSALS) {
  for (const lane of LANES) {
    const verdict = verdictOf(line, CALLERS[lane])
    const want = lanes.includes(lane)
    check(want ? verdict?.deny.includes('Commit guard (workbench-dev-team)') : verdict === undefined, `${want ? 'refused' : 'passes'} [${lane}]: ${show(line)}`)
  }
}
close()

section('commit guard: the false positives pass')
for (const line of [...COMMIT_PASSES, ...GREP_READS]) {
  for (const lane of LANES) check(verdictOf(line, CALLERS[lane]) === undefined, `passes [${lane}]: ${show(line)}`)
}
for (const line of COMMIT_MAIN_PASSES) check(verdictOf(line, CALLERS.main) === undefined, `passes [main]: ${show(line)}`)
for (const line of GREP_WRITES) check(verdictOf(line, CALLERS['sub-agent']) !== undefined, `a search whose output can run is refused [sub-agent]: ${show(line)}`)
close()

section('commit guard: each refusal names its rule')
for (const [line, lane, words] of [
  ['git push --force', 'main', 'forces or deletes'],
  ['gh pr merge 5', 'sub-agent', 'does not merge'],
  ['gh pr merge 5', 'pipeline', 'does not merge'],
  ['git commit -m x', 'sub-agent', 'a sub-agent does not commit or push'],
  ['HUSKY=0 git commit -m x', 'main', 'as a plain line'],
  ['"$PY" script.py', 'pipeline', 'a command name the guard cannot read'],
]) {
  check(verdictOf(line, CALLERS[lane])?.deny.includes(words), `${lane}: ${line} names "${words}"`)
}
check(verdictOf('"$PY" script.py', { lane: 'main', isUnattended: true })?.deny.includes('a command name the guard cannot read'), 'an unattended main loop refuses a built command name')
check(verdictOf('"$PY" script.py', { lane: 'top-level-agent', isUnattended: false }) === undefined, 'an attended top-level run does not meet the built-name rule')
check(verdictOf('"$PY" script.py', CALLERS.main) === undefined, 'an attended main loop does not meet the built-name rule')
check(verdictOf('g$(echo it) com$(echo mit) -m x', CALLERS.main) === undefined, 'an attended main loop leaves a built git to core')
check(verdictOf('git commit -m "fix: 🐛 Fix x."', { lane: 'main', isUnattended: true }) === undefined, 'an unattended main loop still commits plainly')
close()

section('both guards: a statement not placed is refused even with no unknown')
const unplaced = line => {
  const parse = parseShell(line)
  return { ...parse, unknowns: [], statements: parse.statements.map(s => ({ ...s, isPlaced: false })) }
}
const REVIEW_CONTEXT = { cwd: '/SB/repo', home: '/SB/home' }
check(JSON.stringify(commitVerdict(unplaced('sudo -s git push'), 'sudo -s git push', CALLERS.main)) === JSON.stringify(PLAIN_REFUSAL), 'the commit guard reads it as a hidden push')
check('finding' in reviewBash(unplaced('sudo -s rm x'), REVIEW_CONTEXT), 'the review guard refuses it')
close()

section('both guards: an open array or case, and the other unknowns, are refused')
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b)
for (const line of ['x=(a $(echo b)', 'case x in\n a) ls ;;']) {
  check(same(parseShell(line).unknowns, ['compound']), `the reader marks it: ${show(line)}`)
  check(same(commitVerdict(parseShell(line), line, CALLERS['sub-agent']), BUILT_REFUSAL), `refused for a sub-agent: ${show(line)}`)
  check(same(commitVerdict(parseShell(line), line, CALLERS.pipeline), BUILT_REFUSAL), `refused in the pipeline: ${show(line)}`)
  check(commitVerdict(parseShell(line), line, CALLERS.main) === undefined, `left to core in the main loop: ${show(line)}`)
  const verdict = reviewBash(parseShell(line), REVIEW_CONTEXT)
  check('finding' in verdict && JSON.stringify(verdict.finding).includes('compound'), `the review guard refuses it: ${show(line)}`)
}
check(same(commitVerdict(parseShell('case x in\n a) git push ;;'), 'case x in\n a) git push ;;', CALLERS.main), PLAIN_REFUSAL), 'a push inside an open case is hidden, in every lane')
const deep = "bash -c 'bash -c \"bash -c \\\"bash -c \\\\\\\"bash -c ls\\\\\\\"\\\"\"'"
check(same(parseShell(deep).unknowns, ['depth']), 'scripts nested past four levels set depth')
check(same(commitVerdict(parseShell(deep), deep, CALLERS['sub-agent']), BUILT_REFUSAL) && same(commitVerdict(parseShell(deep), deep, CALLERS.pipeline), BUILT_REFUSAL), 'rule 5 refuses depth where nobody watches')
for (const [line, unknowns] of [
  ['x=ech; y=o; echo $[ "1 ]; $x$y MARK', ['quote']],
  ['echo $(( 1 + "1 )); $x$y MARK', ['quote', 'substitution']],
  ["cat <<$'EOF'\nhi\nEOF\n$x$y MARK", ['expansion']],
  ["cat <<$'E\\cAOF'\nhi\nEOF\n$x$y MARK", ['heredoc']],
]) {
  check(same(parseShell(line).unknowns, unknowns), `the reader marks ${unknowns.join(', ')}: ${show(line)}`)
  check(same(commitVerdict(parseShell(line), line, CALLERS['sub-agent']), BUILT_REFUSAL) && same(commitVerdict(parseShell(line), line, CALLERS.pipeline), BUILT_REFUSAL), `refused where nobody watches: ${show(line)}`)
}
for (const line of ['x=(a b) ; ls', 'case x in\n a) ls ;;\nesac']) {
  check(parseShell(line).unknowns.length === 0 && commitVerdict(parseShell(line), line, CALLERS['sub-agent']) === undefined, `a closed array or case is not refused: ${show(line)}`)
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
    const refused = commitVerdict(parse, call.command, CALLERS['sub-agent']) ?? subjectVerdict(parse)
    if (refused !== undefined) return refused.deny
    verdict = reviewBash(parse, context)
  } else verdict = reviewEdit(call.tool, call.path ?? '', context)
  if ('finding' in verdict) return refusalOf(verdict.finding, roots)
  const finding = await judgeWrites(verdict.writes, roots, disk)
  return finding === undefined ? undefined : refusalOf(finding, roots)
}
const bash = command => ({ tool: 'Bash', command })

for (const line of REVIEW_REFUSALS) {
  const refusal = await reviewRefusal(bash(fill(line)))
  check(/A Holmes reviewer writes only in scratch|a command name the guard cannot read/.test(refusal ?? ''), `refused: ${show(line)}`)
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

section('commit subject: a subject that breaks the format is refused')
for (const [line, why] of [
  ['git commit -m x', 'does not start with a type and a colon'],
  ['git commit -m "fix: x"', '"x" is not a gitmoji'],
  ['git commit -m "fix: 🐛 Fix x"', 'does not end with a period'],
  ['git commit -m "fix(api): 🐛 Fix x."', 'it has a scope, (api)'],
  ['git commit -m "feature: ✨ Add x."', '"feature" is not a type'],
  ['git commit -m "fix:🐛 Fix x."', 'not followed by exactly one space'],
  ['git commit -m "fix:  🐛 Fix x."', 'not followed by exactly one space'],
  ['git commit -m "fix: 🐛  Fix x."', 'one space and a description'],
  ['git commit -m "fix: 🐛 ."', undefined],
  ['git commit -m "fix: 🦄 Fix x."', '"🦄" is not a gitmoji'],
  ['git commit -m "Fix: 🐛 Fix x."', '"Fix" is not a type'],
  ['git commit -am "fix: Fix x."', 'is not a gitmoji'],
  ['git commit --message "fix: 🐛 Fix x"', 'does not end with a period'],
  ['git commit --message="fix: 🐛 Fix x"', 'does not end with a period'],
  ['git commit -m"fix: 🐛 Fix x"', 'does not end with a period'],
  ['git -C /repo commit -m "wip"', 'does not start with a type'],
  ['git commit --amend -m "wip"', 'does not start with a type'],
  ['git add . && git commit -m "wip" && git push', 'does not start with a type'],
  ['git commit -unormal -m "wip"', 'does not start with a type'],
  ['git commit -Sabc123 -m "wip"', 'does not start with a type'],
  ['git commit -m "wip" -m "feat: ✨ Add x."', 'does not start with a type'],
  ["git commit -m \"$(cat <<'EOF'\nfix: 🐛 Fix x\n\nBody.\nEOF\n)\"", 'does not end with a period'],
]) {
  for (const lane of ['main', 'pipeline']) {
    const deny = verdictOf(line, CALLERS[lane])?.deny ?? ''
    const parts = ['a commit subject that breaks the git-commit format', '"<type>: <gitmoji> <Description>."', 'Commit guard (workbench-dev-team)', ...(why === undefined ? [] : [why])]
    check(parts.every(part => deny.includes(part)), `refused [${lane}]: ${show(line)}`)
  }
}
for (const line of [
  'git commit -m "fix: 🐛 Fix x."',
  'git commit -m "feat!: 💥 Drop the old endpoint."',
  'git commit -m "refactor: ♻️ Extract the service."',
  'git commit -m "refactor: ♻ Extract the service."',
  'git commit -m "perf: ⚡ Cache the parse."',
  'git commit -m "chore: 🧑‍💻 Improve the dev loop."',
  'git commit -m "fix: 🐛 Fix x.  "',
  'git commit -m "fix: 🐛 Fix x." -m "Body without a period"',
  'git commit -m "fix: 🐛 Fix x.\n\nBody line."',
  "git commit -m \"$(cat <<'EOF'\nfix: 🐛 Fix x.\n\nBody.\nEOF\n)\"",
  'git -c user.name=x commit -m "docs: 📝 Document x."',
  'git commit -unormal -m "feat: ✨ Add x."',
  'git commit -uall -m "feat: ✨ Add x."',
  'git commit -Sabc123 -m "feat: ✨ Add x."',
  'git commit -aS -m "feat: ✨ Add x."',
  'git commit -aSmine -m "feat: ✨ Add x."',
  'git commit -u -m "feat: ✨ Add x."',
  'git commit -F msg.txt',
  'git commit --file=msg.txt',
  'git commit -m "wip" -F msg.txt',
  'git commit -C HEAD',
  'git commit --fixup=abc123',
  'git commit --squash abc123 -m "wip"',
  'git commit',
  'git commit --amend --no-edit',
  'git commit -m "$MSG"',
  'git commit -m "$(cat msg.txt)"',
  'git commit -m "fix: 🐛 Fix $X"',
  "git commit -m \"$(sed -n 1p <<'EOF'\nwip\nEOF\n)\"",
  'git log -m --oneline',
  'echo "git commit -m wip"',
  'git merge -m "wip" feat/x',
]) {
  for (const lane of ['main', 'pipeline']) check(verdictOf(line, CALLERS[lane]) === undefined, `passes [${lane}]: ${show(line)}`)
}
check(subjectVerdict(parseShell('git commit -m "fix: 🐛 A." && git commit -m b'))?.deny !== undefined, 'a line with two commits is refused for the one that breaks the format')
check(subjectVerdict(parseShell('git commit -m "fix: 🐛 A." && git commit -m "fix: 🐛 B."')) === undefined, 'a line with two good commits passes the subject check')
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
const forced = pointed('D=$(mktemp -d) && git -C "$D" push --force')
check(commitVerdict(parseShell(forced), forced, CALLERS['sub-agent']) !== undefined, 'the guards judge the pointed line')
const echoed = 'echo "a; mktemp -d; b"'
check(pointMktemp(echoed, FOLDER) !== undefined && !readsAsPointed(parseShell(echoed), parseShell(pointMktemp(echoed, FOLDER) ?? ''), FOLDER), 'a quoted mktemp the text match reaches does not read back as pointed')
const mixed = 'mktemp -d && echo "then mktemp -d; done"'
check(!readsAsPointed(parseShell(mixed), parseShell(pointMktemp(mixed, FOLDER) ?? ''), FOLDER), 'a real mktemp beside a quoted one is left as written')
check(readsAsPointed(parseShell('mktemp -d'), parseShell(pointMktemp('mktemp -d', FOLDER) ?? ''), FOLDER), 'a plain bare mktemp reads back as pointed')
close()

console.log()
console.log(`${passed} passed, ${failed} failed`)
process.exit(failed === 0 ? 0 : 1)
