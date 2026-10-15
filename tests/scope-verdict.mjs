#!/usr/bin/env node
import fs from 'node:fs'
import os from 'node:os'

import { fromCore } from './core-root.mjs'

const { parseShell } = await fromCore('hooks/mods/shell.ts')
const { needsScope, scopeVerdict } = await fromCore('hooks/mods/destructive-scope.ts')

const [cwd, ...files] = process.argv.slice(2)
const context = { cwd, home: os.homedir(), roots: [cwd], tmp: '/tmp', markers: undefined }
for (const file of files) {
  const line = fs.readFileSync(file, 'utf8')
  const parse = parseShell(line)
  const verdict = needsScope(line, parse) ? scopeVerdict(line, parse, context, () => null) : { kind: 'none' }
  console.log(`${file}\t${verdict.kind}\t${(verdict.reason ?? '').replace(/\s+/g, ' ')}`)
}
