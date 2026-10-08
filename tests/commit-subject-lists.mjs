#!/usr/bin/env node
// The commit subject check's two lists match the git-commit skill's references,
// both ways. Run: node tests/commit-subject-lists.mjs
// (tests/test-commit-subject-lists.sh runs it in the suite).
//
// hooks/mods/commit-subject.ts holds a gitmoji list and a type list, because
// the hooks module cannot read the skill's files at run time without a path
// into the installed plugin. This test reads both references and fails when an
// emoji or a type is in one place and not the other, so an edit to either
// reference that the check does not follow goes red.
//
// Needs node 22.18 or later (type stripping).

import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

import { GITMOJI, TYPES } from '../hooks/mods/commit-subject.ts'

const ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)))
const REFS = path.join(ROOT, 'skills', 'git-commit', 'references')

// The first cell of each table row, past the header and its rule.
const cells = file =>
  fs
    .readFileSync(path.join(REFS, file), 'utf8')
    .split('\n')
    .filter(line => /^\| /.test(line))
    .map(line => line.split('|')[1]?.trim() ?? '')
    .filter(cell => cell !== '' && !/^-+$/.test(cell) && !/^(Emoji|Type)$/.test(cell))

const emoji = cells('gitmoji.md')
const types = cells('conventional-commits.md')
  .filter(cell => /^`[a-z]+`$/.test(cell))
  .map(cell => cell.slice(1, -1))

let failed = 0
const compare = (label, shipped, listed) => {
  const missing = listed.filter(x => !shipped.includes(x))
  const extra = shipped.filter(x => !listed.includes(x))
  if (listed.length === 0) {
    failed++
    console.log(`  ❌ no ${label} read from the reference: the extraction stopped matching`)
  }
  for (const x of missing) {
    failed++
    console.log(`  ❌ ${label} ${x} is in the reference and not in commit-subject.ts`)
  }
  for (const x of extra) {
    failed++
    console.log(`  ❌ ${label} ${x} is in commit-subject.ts and not in the reference`)
  }
  if (missing.length === 0 && extra.length === 0 && listed.length > 0) console.log(`  ✅ the ${listed.length} ${label}s match the reference`)
}
compare('gitmoji', GITMOJI, emoji)
compare('type', TYPES, types)
process.exit(failed === 0 ? 0 : 1)
