#!/usr/bin/env node
import { SECTION, withRules } from '../hooks/mods/session-rules.ts'
import { coreRoot, fromCore } from './core-root.mjs'
import { placeShared } from './placement.ts'

const { withShared } = await fromCore('hooks/mods/prompt-rules.ts')

console.log(`workbench-core: ${coreRoot()}`)
const CORE = [
  { id: 'workbench-core:rules', text: 'Workbench gates.', scope: 'shared' },
  { id: 'workbench-core:memory', text: 'Memory routing.', scope: 'shared' },
]
const LISTS = [
  [],
  [{ id: 'intro', text: 'a', scope: 'shared' }],
  [{ id: 'intro', text: 'a\n\n', scope: 'shared' }],
  [{ id: 'intro', text: 'a\n \n', scope: 'shared' }, { id: 'env', text: 'd', scope: 'session' }],
  [{ id: 'env', text: 'd', scope: 'session' }],
  [{ id: 'intro', text: 'a', scope: 'shared' }, { id: 'env', text: 'd', scope: 'session' }, { id: 'workbench-core:status', text: 's\n\n', scope: 'session' }],
  [{ id: 'intro', text: 'a', scope: 'shared' }, SECTION, { id: 'other:rules', text: 'b\n\n', scope: 'shared' }, { id: 'env', text: 'd', scope: 'session' }],
  [...CORE, { id: 'env', text: 'd', scope: 'session' }],
]
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b)
let failed = 0
const check = (isGood, what) => {
  console.log(`  ${isGood ? '✅' : '❌'} ${what}`)
  if (!isGood) failed++
}
for (const [i, list] of LISTS.entries()) {
  check(same(withRules(list), withShared(list, [SECTION])), `dev-team's withRules places its section as core's withShared does (list ${i + 1})`)
  check(same(placeShared(list, CORE), withShared(list, CORE)), `the test stand-in places core's sections as core's withShared does (list ${i + 1})`)
  check(same(placeShared(list, [SECTION]), withShared(list, [SECTION])), `the test stand-in places one section as core's withShared does (list ${i + 1})`)
}
console.log(`${LISTS.length * 3 - failed} passed, ${failed} failed`)
process.exit(failed === 0 ? 0 : 1)
