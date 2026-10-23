#!/usr/bin/env node
import fs from 'node:fs'
import { registerHooks } from 'node:module'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const NEEDS = ['hooks/mods/shell.ts', 'hooks/mods/prompt-rules.ts', 'hooks/mods/destructive-scope.ts', 'hooks/mods/commit-guard.ts', 'hooks/mods/commit-subject.ts', 'tests/commit-corpus.ts', 'scripts/omit-claude-md-check.py']

const holdsCore = dir => NEEDS.every(file => fs.existsSync(path.join(dir, file)))

const fail = why => {
  console.error(`❌ workbench-core not found: ${why}. Set WORKBENCH_CORE_DIR to a workbench-core checkout.`)
  process.exit(1)
}

const version = name => name.split(/[.+-]/).slice(0, 3).map(Number)
const newer = (a, b) => {
  const [x, y] = [version(a), version(b)]
  for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return (y[i] ?? 0) - (x[i] ?? 0)
  return 0
}

function cached() {
  const cache = path.join(os.homedir(), '.claude', 'plugins', 'cache')
  const found = []
  for (const marketplace of fs.existsSync(cache) ? fs.readdirSync(cache) : []) {
    const plugin = path.join(cache, marketplace, 'workbench-core')
    if (!fs.existsSync(plugin)) continue
    for (const name of fs.readdirSync(plugin)) if (/^\d+\.\d+\.\d+/.test(name)) found.push([name, path.join(plugin, name)])
  }
  return found.sort(([a], [b]) => newer(a, b)).map(([, dir]) => dir).find(holdsCore)
}

export function coreRoot() {
  const named = process.env.WORKBENCH_CORE_DIR
  if (named) return holdsCore(named) ? path.resolve(named) : fail(`WORKBENCH_CORE_DIR=${named} lacks one of ${NEEDS.join(', ')}`)
  const beside = path.resolve(HERE, '..', '..', 'workbench-core')
  if (holdsCore(beside)) return beside
  return cached() ?? fail(`WORKBENCH_CORE_DIR is unset, ${beside} holds no core, and ~/.claude/plugins/cache holds no workbench-core`)
}

let isHooked = false
const hookExtensionless = () => {
  if (isHooked) return
  isHooked = true
  registerHooks({
    resolve(specifier, context, next) {
      if (!/^\.\.?\//.test(specifier) || path.extname(specifier) !== '' || !context.parentURL?.endsWith('.ts')) return next(specifier, context)
      try {
        return next(specifier, context)
      } catch {
        return next(`${specifier}.ts`, context)
      }
    },
  })
}

export const fromCore = file => {
  hookExtensionless()
  return import(pathToFileURL(path.join(coreRoot(), file)).href)
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) console.log(coreRoot())
