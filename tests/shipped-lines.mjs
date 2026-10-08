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
//     Watson and Holmes run their Index-mode lines: it must pass;
//   - a sub-agent, where Holmes's helpers and the Direct-mode agents run: it
//     must pass, or be refused only as the commit or push it is.
// No agent merges, so a block refused as a merge fails in both lanes.
// A block is judged whole, as an agent pastes it.
//
// Needs node 22.18 or later (type stripping).

import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

import { SUBAGENT_REFUSAL, commitVerdict } from '../hooks/mods/commit-guard.ts'
import { parseShell } from './core/hooks/mods/shell.ts'

const ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)))

function markdown(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
    const at = path.join(dir, entry.name)
    if (entry.isDirectory()) return markdown(at)
    return entry.name.endsWith('.md') ? [at] : []
  })
}

// Each fenced shell block of a file that names git or gh.
function blocks(file) {
  const found = []
  let body
  for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
    const fence = /^\s*```(\S*)/.exec(line)
    if (fence && body === undefined) {
      body = ['bash', 'sh', 'shell'].includes(fence[1]) ? [] : null
    } else if (fence) {
      if (body && body.some(l => /\b(?:git|gh)\b/.test(l))) found.push(body.join('\n'))
      body = undefined
    } else if (body) {
      body.push(line)
    }
  }
  return found
}

const files = [...fs.readdirSync(path.join(ROOT, 'agents')).filter(f => f.endsWith('.md')).map(f => path.join(ROOT, 'agents', f)), ...markdown(path.join(ROOT, 'references'))]
let checked = 0
let failed = 0
for (const file of files) {
  for (const block of blocks(file)) {
    checked++
    const parse = parseShell(block)
    const where = `${path.relative(ROOT, file)}: ${JSON.stringify(block.length > 120 ? `${block.slice(0, 120)}…` : block)}`
    const pipeline = commitVerdict(parse, block, { lane: 'top-level-agent', isUnattended: true })
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
console.log(failed === 0 ? `  ✅ ${checked} shipped shell blocks pass the commit guard in the lanes that run them` : `\n${failed} failed`)
process.exit(failed === 0 ? 0 : 1)
