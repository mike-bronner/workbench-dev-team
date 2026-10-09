#!/usr/bin/env node
// Every shell block the agents and their references ship must pass the commit
// guard in the lanes that run it. Run: node tests/shipped-lines.mjs
// (tests/test-shipped-lines.sh runs it in the suite).
//
// The differential (tests/differential.mjs) fails only where a guard refuses
// less than the bash guard it replaced, so it cannot see a guard that refuses
// a line dev-team's own agents run. This test reads every ```bash, ```sh and
// ```shell block in agents/*.md and references/**/*.md that names git or gh,
// and holds it to two lanes:
//   - the pipeline (a top-level `claude -p --agent` run, unattended), where
//     Watson and Holmes run their Index-mode lines: it must pass, and so must
//     the subject of every commit it makes (hooks/mods/commit-subject.ts);
//   - a sub-agent, where Holmes's helpers and the Direct-mode agents run: it
//     must pass, or be refused only as the commit or push it is.
// No agent merges, so a block refused as a merge fails in both lanes.
// A block is judged whole, as an agent pastes it.
//
// workbench-core refuses, in every lane and ahead of any plugin guard, a line
// whose command its reader cannot name (hiddenCommandRefusal in core's
// hooks/mods/guards.ts, since 4e83554): a command word with an expansion in
// it, a wrapper it cannot place, or a script piped or fed into a shell. So
// every shell block in agents/, references/, skills/ and commands/, git or
// not, is also held to that rule, read through the same copy of core's reader.
//
// The commit guard's fifth rule also refuses, in those two lanes, a line
// with any unknown in its HIDES_NAME list, which holds every unknown the
// reader can set. So every shell block is held to that list as well, read
// from the guard itself.
//
// Needs node 22.18 or later (type stripping).

import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

import { HIDES_NAME, SUBAGENT_REFUSAL, commitVerdict } from '../hooks/mods/commit-guard.ts'
import { subjectVerdict } from '../hooks/mods/commit-subject.ts'
import { parseShell } from './core/hooks/mods/shell.ts'

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
  ['"${CLAUDE_PLUGIN_ROOT}/scripts/x.sh"', false],
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
if (FIFTH_RULE.length !== HIDES_NAME.length) {
  failed++
  console.log(`  ❌ the fifth rule's self-check covers ${FIFTH_RULE.length} unknowns, and HIDES_NAME holds ${HIDES_NAME.length}`)
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
