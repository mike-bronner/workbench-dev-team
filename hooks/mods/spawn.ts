// What happens when a session dispatches a dev-team agent, as pure functions:
// which mode agent a dispatch runs, what model and effort the config gives it,
// and the dispatch gate's refusal and advisory hint. hooks/register.ts holds
// every hook that touches `$` and calls these, because the engine follows `$`
// into no imported function.

import type { EngineInterface } from 'claude-code'

import type { DevTeamEffort } from '../../types'

// workbench-core's $.workbench contract, read off the noun itself: dev-team
// lists core under `dependencies`, and the engine types the noun on `$`.
type Workbench = EngineInterface['workbench']
export type BriefCheck = Awaited<ReturnType<Workbench['briefCheck']>>
export type BriefSlot = Awaited<ReturnType<Workbench['briefSlots']>>[number]
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

// What ~/.claude-workbench/dev-team-config.json gives one family's interactive
// dispatch. The file is the person's, so each value is checked before it is
// used: a model is an alias or a full id with an optional bracketed suffix
// (`claude-opus-5-5[1m]`), and an effort is a level. turn.step refuses a
// numeric effort from a hook ("a number is internal-only"), so a number is not
// one. A
// value outside that shape, a missing key, and an unreadable or malformed file
// all leave the knob unset, so the agent file's own value applies. A config
// problem never blocks a dispatch, as on the scheduled path.
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

// Whether the dispatch gate judges a dispatch: a main-session dispatch while
// orchestrator mode is on, as hooks/agent-dispatch-gate.sh decides it. A
// sub-agent's dispatch and a top-level `--agent` run's are exempt.
export const isGated = (lane: CallerLane, isOn: boolean): boolean => lane === 'main' && isOn

// The refusal for a brief missing slots: the gate's human line, then what it
// tells the model, from the same slot records the check read.
export function denyOf(missing: readonly string[], slots: readonly BriefSlot[]): string {
  const catalogue = slots.map(slot => `${slot.header} (${slot.description})`).join(', ')
  return [
    `🛑 Blocked: an Agent dispatch without a complete brief. Missing: ${missing.join(', ')}.`,
    '',
    `Dispatch gate (${PLUGIN}). Every Agent dispatch from the main session uses the six-slot brief, research included. ` +
      `Slots: ${catalogue}. Add the missing slots and dispatch again. ` +
      'The dev-team specialists and the brief they expect are in /workbench-dev-team:orchestrate. ' +
      'To dispatch without the brief in this session, the human can run /orchestrator off.',
  ].join('\n')
}

// The refusal when the gate judges a dispatch but cannot check its brief:
// workbench-core's briefCheck rejected or the gate itself failed. Core is a
// declared dependency, so that is a fault, and the gate fails closed.
// /orchestrator off stands the gate down, so the refusal never locks the
// human out.
export function uncheckedDeny(): string {
  return [
    '🛑 Blocked: an Agent dispatch whose brief could not be checked.',
    '',
    `Dispatch gate (${PLUGIN}). The gate judges this dispatch, and workbench-core's brief check did not answer, so the gate refuses rather than let an unchecked brief through. ` +
      'Dispatch again. If the check keeps failing, workbench-core needs repair. ' +
      'To dispatch without the brief check in this session, the human can run /orchestrator off.',
  ].join('\n')
}

// The advisory note on a complete brief that dictates method: a fenced block, a
// shell command on its own line, or three or more numbered steps. It never
// blocks. Each pattern is the bash gate's, line by line, over its five ASCII
// whitespace characters.
const WS = ' \\t\\r\\v\\f'
const FENCE = new RegExp(`^[${WS}]*\`\`\``)
const COMMAND = new RegExp(
  `^[${WS}]*(\\$[${WS}]+)?(git|gh|npm|npx|yarn|pnpm|composer|php|python3?|pytest|cargo|rustc|bash|zsh|sed|awk|grep|rg|jq|cp|mv|rm|mkdir|chmod|ln|curl|docker)[${WS}]+[^${WS}]`,
)
const STEP = new RegExp(`^[${WS}]{0,3}[0-9]+[.)][${WS}]+[^${WS}]`)

export function hintOf(check: BriefCheck, prompt: string): string | undefined {
  if (check.shape !== 'brief' || !check.isComplete) return undefined
  const lines = prompt.split('\n')
  const markers: string[] = []
  if (lines.some(line => FENCE.test(line))) markers.push('a fenced code block')
  if (lines.some(line => COMMAND.test(line))) markers.push('a shell command on its own line')
  const steps = lines.filter(line => STEP.test(line)).length
  if (steps >= 3) markers.push(`${steps} numbered steps`)
  if (markers.length === 0) return undefined
  return (
    `📐 Dispatch hint (advisory, nothing was blocked): this brief carries ${markers.join(', ')}. ` +
    'A brief states the outcome and lets the sub-agent pick the method. The sub-agent has the repo in front of it and you do not. ' +
    'Prefer moving that detail into Done when: as an observable result, or into Constraints: as a hard limit. ' +
    'Send it as-is if the detail is genuinely a constraint rather than a recipe.'
  )
}
