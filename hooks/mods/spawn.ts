import type { EngineInterface } from 'claude-code'

import type { DevTeamEffort } from '../../types'

// workbench-core's $.workbench contract, read off the noun itself: dev-team
// lists core under `dependencies`, and the engine types the noun on `$`.
type Workbench = EngineInterface['workbench']
export type CallerLane = Awaited<ReturnType<Workbench['callerLane']>>

export const PLUGIN = 'workbench-dev-team'

export type Family = 'watson' | 'holmes' | 'lestrade'

// The agent types a family answers to: the public type, and each mode type
// bin/compose-agents.sh builds from it. A dispatch of any of them is routed by
// its token, so a mode type dispatched by name still runs the mode its prompt
// calls for.
const FAMILIES: Readonly<Record<Family, readonly string[]>> = {
  watson: ['watson', 'watson-direct', 'watson-index'],
  holmes: ['holmes', 'holmes-local', 'holmes-index'],
  lestrade: ['lestrade', 'lestrade-item', 'lestrade-sweep'],
}

export function familyOf(subagentType: string | undefined): Family | undefined {
  if (typeof subagentType !== 'string') return undefined
  const [plugin, name] = subagentType.split(':')
  if (plugin !== PLUGIN || name === undefined) return undefined
  return (Object.keys(FAMILIES) as Family[]).find(family => FAMILIES[family].includes(name))
}

// The tokens. A token picks a mode only when it is the whole prompt: one
// non-blank line, and that line the token, which is how workbench-core's
// briefCheck reads the `item-id` and `repo-sweep` shapes. A brief that only
// mentions `Item ID: 9`, in its Context or anywhere else, is a brief, so it
// runs the off-board mode and the agent's own rule that a mention is not a
// dispatch token still applies. Watson and Holmes take `Item ID: <n>` or one
// bare id (a plain integer, a UUID, or a PVTI_ id) for The Index mode. Lestrade
// takes `Item ID: <n>` or a bare integer for Item mode, and
// `Repo sweep: <owner/repo>` for Sweep mode. Whitespace is the five ASCII
// characters core's check uses, so an exotic space makes a line no token.
const SPACE = '[ \\t\\r\\v\\f]*'
const ITEM_ID = new RegExp(`^${SPACE}Item ID:${SPACE}[0-9]+${SPACE}$`)
const BARE_INTEGER = new RegExp(`^${SPACE}[0-9]+${SPACE}$`)
const BARE_ID = new RegExp(
  `^${SPACE}(?:[0-9]+|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}|PVTI_[A-Za-z0-9_-]+)${SPACE}$`,
)
const REPO_SWEEP = new RegExp(`^${SPACE}Repo sweep:${SPACE}[^ \\t\\r\\v\\f/]+/[^ \\t\\r\\v\\f/]+${SPACE}$`)
const NONBLANK = /[^ \t\r\v\f\n]/

// Whether the whole prompt is one token: a single non-blank line it matches.
function isWhole(prompt: string, ...tokens: RegExp[]): boolean {
  const lines = prompt.split('\n').filter(line => NONBLANK.test(line))
  return lines.length === 1 && tokens.some(token => token.test(lines[0] ?? ''))
}

// The item id of a prompt that is the whole token `Item ID: <n>`, or undefined.
export function itemIdOf(prompt: string): string | undefined {
  if (!isWhole(prompt, ITEM_ID)) return undefined
  return /[0-9]+/.exec(prompt.split('\n').find(line => NONBLANK.test(line)) ?? '')?.[0]
}

// The mode agent a dispatch runs, as a full type. Anything but a whole-prompt
// token is Direct mode for Watson and Local mode for Holmes, as their files
// say. Lestrade has no prose mode, so a prompt that is no token stays on the
// public type, which decides for itself.
export function modeTypeOf(family: Family, prompt: string): string {
  switch (family) {
    case 'watson':
      return `${PLUGIN}:${isWhole(prompt, ITEM_ID, BARE_ID) ? 'watson-index' : 'watson-direct'}`
    case 'holmes':
      return `${PLUGIN}:${isWhole(prompt, ITEM_ID, BARE_ID) ? 'holmes-index' : 'holmes-local'}`
    case 'lestrade':
      if (isWhole(prompt, ITEM_ID, BARE_INTEGER)) return `${PLUGIN}:lestrade-item`
      if (isWhole(prompt, REPO_SWEEP)) return `${PLUGIN}:lestrade-sweep`
      return `${PLUGIN}:lestrade`
  }
}

// What the /config rows give one family's interactive dispatch, read through
// configTextOf. The values are the person's, so each is checked before it is
// used: a model is an alias or a full id with an optional bracketed suffix
// (`claude-opus-5-5[1m]`), and an effort is a level. turn.step refuses a
// numeric effort from a hook ("a number is internal-only"), so a number is not
// one. A value outside that shape, and a missing one, leave the knob unset, so
// the agent file's own value applies. A bad value never blocks a dispatch, as
// on the scheduled path.
export type Knobs = { model?: string; effort?: DevTeamEffort }

const MODEL = /^[A-Za-z0-9][A-Za-z0-9._-]*(?:\[[A-Za-z0-9]+\])?$/
const LEVELS: readonly string[] = ['low', 'medium', 'high', 'xhigh', 'max']

export function knobsOf(configText: string | undefined, family: Family): Knobs {
  if (configText === undefined) return {}
  let config: unknown
  try {
    config = JSON.parse(configText)
  } catch {
    return {}
  }
  const entry = (config as { agents?: Record<string, unknown> } | null)?.agents?.[family]
  if (entry === null || typeof entry !== 'object') return {}
  const { model, effort } = entry as { model?: unknown; effort?: unknown }
  const knobs: Knobs = {}
  if (typeof model === 'string' && MODEL.test(model)) knobs.model = model
  if (typeof effort === 'string' && LEVELS.includes(effort.toLowerCase())) knobs.effort = effort.toLowerCase() as DevTeamEffort
  return knobs
}

// The knobs the review agents read at run time: whether Holmes and Lestrade
// fan out to helpers, and the model the helpers run on. The mod adds them to
// the prompt of the three modes that read them, so no agent reads the file:
// at spawn for an interactive dispatch, and on prompt.submit for the top-level
// run bin/dispatch-agent.sh starts, which raises no agent.spawn.
export const CONFIG_MODES: Readonly<Record<string, Family>> = {
  [`${PLUGIN}:holmes-local`]: 'holmes',
  [`${PLUGIN}:holmes-index`]: 'holmes',
  [`${PLUGIN}:lestrade-item`]: 'lestrade',
}

// The plugin's /config rows, as the config text knobsOf and configLineOf read:
// one entry per agent, keyed as the old config file keyed it, so
// `watsonModel` is `agents.watson.model`. A row with no value is left out.
const ROW_KNOBS = ['model', 'effort', 'fanout', 'lensModel'] as const
export function configTextOf(options: Readonly<Record<string, unknown>> | undefined): string {
  const entry = (family: Family) =>
    Object.fromEntries(
      ROW_KNOBS.map(knob => [knob, options?.[`${family}${knob.charAt(0).toUpperCase()}${knob.slice(1)}`]] as const).filter(([, value]) => value !== undefined),
    )
  return JSON.stringify({ agents: Object.fromEntries((Object.keys(FAMILIES) as Family[]).map(family => [family, entry(family)])) })
}

// The line's label, which the agents' prose names.
export const CONFIG_LABEL = 'Dev-team config:'

// The line the mod adds for one family, from the config's text. Only a
// `false` turns the fan-out off, so a missing or malformed value leaves it on,
// as the agents' default is. A lensModel outside the model shape is unset, and
// the helpers then run on the agent's own model.
export function configLineOf(configText: string | undefined, family: Family): string {
  let entry: unknown
  try {
    entry = (JSON.parse(configText ?? '') as { agents?: Record<string, unknown> } | null)?.agents?.[family]
  } catch {
    entry = undefined
  }
  const { fanout, lensModel } = entry !== null && typeof entry === 'object' ? (entry as { fanout?: unknown; lensModel?: unknown }) : {}
  const model = typeof lensModel === 'string' && MODEL.test(lensModel) ? lensModel : undefined
  return `${CONFIG_LABEL} fanout ${fanout === false ? 'off' : 'on'}; lensModel ${model ?? 'unset'}.`
}

// The prompt with the config line added once, after a blank line.
export const withConfigLine = (prompt: string, line: string): string =>
  prompt.includes(CONFIG_LABEL) ? prompt : `${prompt.replace(/\s+$/, '')}\n\n${line}`

// ── Holmes's helpers run on holmes-lens ──────────────────────────────────────

export const LENS_TYPE = `${PLUGIN}:holmes-lens`

// Holmes in any mode: the public type and its two mode types, by full or bare
// name. Not holmes-lens, which holds no Agent tool.
const HOLMES_MODE = /(^|[:/])holmes(-local|-index)?$/iu
export const isHolmesMode = (type: string | undefined): boolean => type !== undefined && HOLMES_MODE.test(type.trim())

// The type a Holmes spawn runs as: holmes-lens, whatever the call named, or a
// refusal for a fork or a teammate, which cannot be retyped.
export function lensSpawnOf(e: { subagentType: string; fork: boolean; isTeammate?: true }): { subagentType: string } | { deny: string } {
  if (e.subagentType === LENS_TYPE) return { subagentType: LENS_TYPE }
  if (e.fork || e.isTeammate) return { deny: lensDeny(e.fork ? 'a fork' : 'a teammate') }
  return { subagentType: LENS_TYPE }
}

export function lensDeny(what: string): string {
  return [
    `🛑 Blocked: Holmes spawned ${what}.`,
    '',
    `Helper rule (${PLUGIN}). Every helper Holmes spawns runs on ${LENS_TYPE}, the read-only helper, and ${what} cannot be retyped to it. ` +
      `Dispatch the helper with subagent_type "${LENS_TYPE}".`,
  ].join('\n')
}

// Whether a type is one of the dev-team's agents, the helper included: the
// types the mod gives a scratch folder and a context budget.
export const isDevTeamType = (type: string | undefined): boolean => type !== undefined && (familyOf(type) !== undefined || type === LENS_TYPE)

// ── The default-branch check ─────────────────────────────────────────────────

export const DEFAULT_BRANCHES: readonly string[] = ['main', 'master', 'trunk']

// A brief's Workdir: the path, and whether the slot records a workspace
// decision. The path runs to the first " (", and the slot records a decision
// when the text after the path names a branch or a worktree, as
// `/repo (branch: main, Mike chose main)` does. Undefined when the brief has
// no Workdir line.
export function workdirOf(prompt: string): { path: string; isRecorded: boolean } | undefined {
  const line = prompt.split('\n').find(l => /^[ \t]*Workdir:/.test(l))
  if (line === undefined) return undefined
  const value = line.replace(/^[ \t]*Workdir:/, '').trim()
  const cut = value.indexOf(' (')
  const path = (cut === -1 ? value : value.slice(0, cut)).trim()
  return { path, isRecorded: /\b(branch|worktree)\b/i.test(value.slice(path.length)) }
}

export function branchDeny(path: string, branch: string): string {
  return [
    `🛑 Blocked: a Watson Direct-mode dispatch onto ${branch}, with no branch recorded in Workdir:.`,
    '',
    `Workspace check (${PLUGIN}). The repo at ${path} is on its default branch, ${branch}, and the brief's Workdir: names only the path. ` +
      'Ask the human which branch the work goes on, through AskUserQuestion, and propose a branch name. ' +
      `Then record the answer beside the path, for example "Workdir: ${path} (branch: fix/short-name)", or "(branch: ${branch}, <who> chose to work on ${branch})" when the human picks ${branch}, and dispatch again.`,
  ].join('\n')
}

export function branchUnreadDeny(path: string): string {
  return [
    '🛑 Blocked: a Watson Direct-mode dispatch whose branch could not be read.',
    '',
    `Workspace check (${PLUGIN}). git did not answer for ${path}, so the check cannot tell whether the repo is on its default branch. ` +
      'Ask the human which branch the work goes on, record it beside the path in Workdir:, for example "(branch: fix/short-name)", and dispatch again.',
  ].join('\n')
}

export const isGated = (lane: CallerLane, isOn: boolean): boolean => lane === 'main' && isOn

export function spawnFailedDeny(): string {
  return [
    '🛑 Blocked: an Agent dispatch the dev-team spawn rules could not judge.',
    '',
    `Spawn rules (${PLUGIN}). The helper rule or the workspace check failed while reading this dispatch, so it is refused rather than let through unjudged. ` +
      'Dispatch again. If it keeps failing, report it to the human as a defect in workbench-dev-team.',
  ].join('\n')
}
