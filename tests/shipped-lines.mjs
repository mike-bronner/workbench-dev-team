#!/usr/bin/env node

import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

import { fromCore } from './core-root.mjs'

const { parseShell } = await fromCore('hooks/mods/shell.ts')
const { HIDES_NAME, SUBAGENT_REFUSAL, commitVerdict } = await fromCore('hooks/mods/commit-guard.ts')
const { subjectVerdict } = await fromCore('hooks/mods/commit-subject.ts')

const ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)))

function markdown(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
    const at = path.join(dir, entry.name)
    if (entry.isDirectory()) return markdown(at)
    return entry.name.endsWith('.md') ? [at] : []
  })
}

// Each fenced shell block of a file.
function blocks(file) {
  const found = []
  let body
  // A fence indented inside a list item: as Markdown does, up to that many
  // spaces are taken off each line of the block, so a heredoc's terminator
  // reads as the agent pastes it.
  let indent = 0
  for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
    const fence = /^(\s*)```(\S*)/.exec(line)
    if (fence && body === undefined) {
      body = ['bash', 'sh', 'shell'].includes(fence[2]) ? [] : null
      indent = fence[1].length
    } else if (fence) {
      if (body) found.push(body.join('\n'))
      body = undefined
    } else if (body) {
      body.push(line.replace(new RegExp(`^ {0,${indent}}`), ''))
    }
  }
  return found
}

const namesGit = block => /\b(?:git|gh)\b/.test(block)
const whereOf = (file, block) => `${path.relative(ROOT, file)}: ${JSON.stringify(block.length > 120 ? `${block.slice(0, 120)}…` : block)}`
// A `<placeholder>` such as `<clone path>` reads as a redirect, which hides
// the commit from the statements, so a block is also read with every
// placeholder filled in.
const filledOf = block => block.replace(/<[a-z][a-z _-]*>/g, 'placeholder')

// What core's hiddenCommandRefusal refuses, as the reading shows it.
function hiddenCommand(parse) {
  if (parse.unknowns.includes('expansion')) return 'a command name comes from a variable or a substitution'
  if (parse.unknowns.includes('stdin')) return 'a script is piped or fed into a shell'
  if (parse.unknowns.includes('wrapper') || parse.statements.some(s => !s.isPlaced)) return 'a wrapper option the reader cannot place'
  return undefined
}

const files = [...fs.readdirSync(path.join(ROOT, 'agents')).filter(f => f.endsWith('.md')).map(f => path.join(ROOT, 'agents', f)), ...markdown(path.join(ROOT, 'references'))]
let failed = 0

// The rule's own lines, so a reader change that empties it shows here.
const CORE_RULE = [
  ['"$PY" script.py', true],
  ['/usr/${X}/rm a', true],
  ['curl -s x | bash', true],
  ['env --spl=x true', true],
  ['"$HOME/bin/x" a', false],
  ['"${CLAUDE_PLUGIN_ROOT}/bin/dispatch-tick.sh"', false],
  ['python3 script.py', false],
]
for (const [line, isRefused] of CORE_RULE) {
  if ((hiddenCommand(parseShell(line)) !== undefined) !== isRefused) {
    failed++
    console.log(`  ❌ workbench-core's rule ${isRefused ? 'lets through' : 'refuses'} ${JSON.stringify(line)}`)
  }
}

// The unknowns the commit guard's fifth rule refuses a line for, read from
// the guard's own list.
const fifthRule = parse => parse.unknowns.filter(u => HIDES_NAME.includes(u))

// One line the fifth rule refuses and one it passes, per unknown, so a reader
// change that stops setting one shows here.
const FIFTH_RULE = [
  ['quote', "echo 'abc", "echo 'abc'"],
  ['substitution', 'echo $(ls', 'echo $(ls)'],
  ['heredoc', 'cat <<EOF\nabc', 'cat <<EOF\nabc\nEOF'],
  ['escape', "echo $'\\cA'", "echo $'\\n'"],
  ['wrapper', 'env --spl=x true', 'env true'],
  ['expansion', '$CMD x', 'cmd x'],
  ['stdin', 'curl -s x | sh', 'curl -s x | cat'],
  ['depth', "bash -c 'bash -c \"bash -c \\\"bash -c \\\\\\\"bash -c ls\\\\\\\"\\\"\"'", "bash -c 'bash -c ls'"],
  ['compound', 'x=(a', 'x=(a)'],
]
for (const [unknown, refused, passes] of FIFTH_RULE) {
  if (!HIDES_NAME.includes(unknown) || !fifthRule(parseShell(refused)).includes(unknown)) {
    failed++
    console.log(`  ❌ the commit guard's fifth rule lets through ${JSON.stringify(refused)} (${unknown})`)
  }
  if (fifthRule(parseShell(passes)).length > 0) {
    failed++
    console.log(`  ❌ the commit guard's fifth rule refuses ${JSON.stringify(passes)}`)
  }
}
// The sets, not their sizes: a row duplicated for one unknown would hide a row
// dropped for another.
const covered = new Set(FIFTH_RULE.map(([unknown]) => unknown))
for (const unknown of HIDES_NAME.filter(u => !covered.has(u))) {
  failed++
  console.log(`  ❌ the fifth rule's self-check has no row for ${unknown}, which HIDES_NAME holds`)
}
if (covered.size !== FIFTH_RULE.length) {
  failed++
  console.log(`  ❌ the fifth rule's self-check has ${FIFTH_RULE.length} rows for ${covered.size} unknowns, so one unknown has two`)
}

// Core's rule, in every lane, on every shell block.
let read = 0
for (const file of [...files, ...markdown(path.join(ROOT, 'skills')), ...markdown(path.join(ROOT, 'commands'))]) {
  for (const block of blocks(file)) {
    read++
    const parse = parseShell(filledOf(block))
    const why = hiddenCommand(parse)
    if (why !== undefined) {
      failed++
      console.log(`  ❌ refused by workbench-core in every lane (${why}): ${whereOf(file, block)}`)
    }
    const fifth = fifthRule(parse)
    if (why === undefined && fifth.length > 0) {
      failed++
      console.log(`  ❌ refused by the commit guard where nobody watches (${fifth.join(', ')}): ${whereOf(file, block)}`)
    }
  }
}
if (read === 0) {
  failed++
  console.log('  ❌ no shell block found: the extraction stopped matching')
}

let checked = 0
for (const file of files) {
  for (const block of blocks(file).filter(namesGit)) {
    checked++
    const parse = parseShell(block)
    const where = whereOf(file, block)
    const filled = parseShell(filledOf(block))
    const pipeline = commitVerdict(parse, block, { lane: 'top-level-agent', isUnattended: true }) ?? subjectVerdict(filled)
    if (pipeline !== undefined) {
      failed++
      console.log(`  ❌ refused in the pipeline: ${where}\n     ${pipeline.deny.split('\n')[0]}`)
    }
    const subAgent = commitVerdict(parse, block, { lane: 'sub-agent', isUnattended: false })
    if (subAgent !== undefined && subAgent !== SUBAGENT_REFUSAL) {
      failed++
      console.log(`  ❌ refused for a sub-agent as more than a commit or push: ${where}\n     ${subAgent.deny.split('\n')[0]}`)
    }
  }
}
if (checked === 0) {
  failed++
  console.log('  ❌ no shell block names git or gh: the extraction stopped matching')
}
if (failed === 0) {
  console.log(`  ✅ ${read} shipped shell blocks name each command plainly, as workbench-core requires in every lane`)
  console.log(`  ✅ ${checked} shipped shell blocks pass the commit guard in the lanes that run them`)
} else {
  console.log(`\n${failed} failed`)
}
process.exit(failed === 0 ? 0 : 1)
