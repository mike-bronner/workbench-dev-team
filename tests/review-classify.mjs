#!/usr/bin/env node
// The review guard's verdict on documentation: one command per stdin line, each
// refused line printed with its reason, exit 1 when any line is refused.
// Run: node tests/review-classify.mjs < commands.txt
//
// agents/lint-holmes-local-mode.sh feeds it the fenced blocks of
// references/holmes/local-review.md, so the reference is held to the rule the
// guard enforces (hooks/mods/review-guard.ts) rather than to a second copy of
// it. A line is read as documentation: with no scratch root and no working
// directory, every file write is refused, redirects are not judged, and what
// the shell reader cannot read in prose (an apostrophe, a stray quote) is
// passed over. It reads lines through workbench-core's shell reader, copied
// into tests/core/.
//
// Needs node 22.18 or later (type stripping).

import fs from 'node:fs'

import { reviewBash } from '../hooks/mods/review-guard.ts'
import { parseShell } from './core/hooks/mods/shell.ts'

let refused = 0
for (const line of fs.readFileSync(0, 'utf8').split('\n')) {
  if (line.trim() === '') continue
  const verdict = reviewBash(parseShell(line), { cwd: undefined, home: undefined, isDocs: true })
  const reason = 'finding' in verdict ? verdict.finding.reason : verdict.writes.length > 0 ? `\`${verdict.writes[0].writer}\` writes a file.` : undefined
  if (reason === undefined) continue
  refused++
  console.log(`${line.trim()} — ${reason}`)
}
process.exit(refused === 0 ? 0 : 1)
