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
  watson: ['watson', 'watson-direct', 'watson-index', 'watson-external'],
  holmes: ['holmes', 'holmes-local', 'holmes-index', 'holmes-external'],
  lestrade: ['lestrade', 'lestrade-item', 'lestrade-sweep', 'lestrade-external'],
}

export function familyOf(subagentType: string | undefined): Family | undefined {
  if (typeof subagentType !== 'string') return undefined
  const [plugin, name] = subagentType.split(':')
  if (plugin !== PLUGIN || name === undefined) return undefined
  return (Object.keys(FAMILIES) as Family[]).find(family => FAMILIES[family].includes(name))
}

const SPACE = '[ \\t\\r\\v\\f]*'
const ITEM_ID = new RegExp(`^${SPACE}Item ID:${SPACE}[0-9]+${SPACE}$`)
const BARE_INTEGER = new RegExp(`^${SPACE}[0-9]+${SPACE}$`)
const BARE_ID = new RegExp(
  `^${SPACE}(?:[0-9]+|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}|PVTI_[A-Za-z0-9_-]+)${SPACE}$`,
)
const REPO_SWEEP = new RegExp(`^${SPACE}Repo sweep:${SPACE}[^ \\t\\r\\v\\f/]+/[^ \\t\\r\\v\\f/]+${SPACE}$`)
const external = (kind: string): RegExp => new RegExp(`^${SPACE}External ${kind}:${SPACE}[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[1-9][0-9]*${SPACE}$`)
const EXTERNAL_ISSUE = external('issue')
const EXTERNAL_REVIEW = external('review')
const EXTERNAL_CRITERIA = external('criteria')
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
      if (isWhole(prompt, EXTERNAL_ISSUE)) return `${PLUGIN}:watson-external`
      return `${PLUGIN}:${isWhole(prompt, ITEM_ID, BARE_ID) ? 'watson-index' : 'watson-direct'}`
    case 'holmes':
      if (isWhole(prompt, EXTERNAL_REVIEW)) return `${PLUGIN}:holmes-external`
      return `${PLUGIN}:${isWhole(prompt, ITEM_ID, BARE_ID) ? 'holmes-index' : 'holmes-local'}`
    case 'lestrade':
      if (isWhole(prompt, ITEM_ID, BARE_INTEGER)) return `${PLUGIN}:lestrade-item`
      if (isWhole(prompt, REPO_SWEEP)) return `${PLUGIN}:lestrade-sweep`
      if (isWhole(prompt, EXTERNAL_CRITERIA)) return `${PLUGIN}:lestrade-external`
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

export const CONFIG_MODES: Readonly<Record<string, Family>> = {
  [`${PLUGIN}:holmes-local`]: 'holmes',
  [`${PLUGIN}:holmes-index`]: 'holmes',
  [`${PLUGIN}:holmes-external`]: 'holmes',
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

const HOLMES_MODE = /(^|[:/])holmes(-local|-index|-external)?$/iu
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

export const BRIEF_SLOTS: readonly string[] = ['Workdir:', 'Goal:', 'Context:', 'Constraints:', 'Acceptance:', 'Done when:']

const escape = (text: string): string => text.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&')
const LABELS = BRIEF_SLOTS.map(slot => new RegExp(`^[#*_\`\\s]*${escape(slot.slice(0, -1))}[*_\`\\s]*:[*_\`]*`, 'iu'))
const UNIT = /^[#*_` \t\r\v\f]*Unit[*_` \t\r\v\f]*:[*_`]*/iu
const labelOf = (slot: string): RegExp => LABELS[BRIEF_SLOTS.indexOf(slot)] ?? /$^/u
const BULLET = /^(?:[-*+]|\d+[.)]|AC\d+:)\s/iu

type Block = { head: string; items: string[] }

type Builder = { block: Block; indent: number; target: number; resume: number | undefined }

const builderOf = (head: string): Builder => ({ block: { head, items: head === '' ? [] : [head] }, indent: Number.POSITIVE_INFINITY, target: head === '' ? -1 : 0, resume: undefined })

function addLine(current: Builder, raw: string): void {
  const line = raw.trim()
  const { items } = current.block
  if (UNIT.test(raw)) {
    current.resume ??= current.target
    current.target = items.push(line) - 1
    return
  }
  if (current.resume !== undefined && (line === '' || BULLET.test(line))) {
    if (current.resume !== -1 || line !== '') current.target = current.resume
    current.resume = undefined
  }
  if (line === '') return
  const indent = raw.length - raw.trimStart().length
  if (current.target === -1 || (BULLET.test(line) && indent <= current.indent)) {
    current.target = items.push(line) - 1
    if (BULLET.test(line)) current.indent = indent
  } else items[current.target] += ` ${line}`
}

function blocksOf(prompt: string, slot: string): Block[] {
  const label = labelOf(slot)
  const blocks: Block[] = []
  let current: Builder | undefined
  for (const raw of prompt.split('\n')) {
    if (label.test(raw)) {
      current = builderOf(raw.replace(label, '').trim())
      blocks.push(current.block)
      continue
    }
    if (LABELS.some(other => other.test(raw))) {
      current = undefined
      continue
    }
    if (current !== undefined) addLine(current, raw)
  }
  return blocks
}

function messageItemsOf(message: string): string[] {
  const current = builderOf('')
  let isAfterBlank = false
  for (const raw of message.split('\n')) {
    const isBlank = raw.trim() === ''
    const isUnderBullet = BULLET.test(current.block.items[current.target] ?? '') && raw.length - raw.trimStart().length > current.indent
    if (isAfterBlank && !isBlank && !isUnderBullet) current.target = -1
    isAfterBlank = isBlank
    addLine(current, raw)
  }
  return current.block.items
}

export function missingSlotsOf(prompt: string): string[] {
  const missing = BRIEF_SLOTS.filter(slot => blocksOf(prompt, slot).length === 0)
  const context = blocksOf(prompt, 'Context:')[0]?.head
  if (context !== undefined && (context === '' || /^none\.?$/i.test(context))) missing.push('Context: (it reads "none" or is empty)')
  return missing
}

export function briefDeny(missing: readonly string[]): string {
  return [
    `🛑 Blocked: a Holmes Local-mode dispatch whose brief lacks ${missing.join(', ')}.`,
    '',
    `Brief contract (${PLUGIN}). Every Holmes Local review takes the six-slot brief: Workdir:, Goal:, Context:, Constraints:, Acceptance:, and Done when:. ` +
      'Constraints: carries the exact line "Run no mutation testing of any kind.", and Context: may not read "none". Nothing was spawned. Add every missing slot and dispatch again.',
  ].join('\n')
}

export const NO_MUTATION_LINE = '- Run no mutation testing of any kind.'

const LEAD = /^[\s\-*+_`"'()]+/u
const NO_MUTATION = /^run no mutation testing of any kind(?![\w-])/iu
const EXCEPTION = /\b(?:except|but|unless|other than)\b/iu
const MUTATION = /(?<![a-z0-9])muta[nt]/iu
const REMOVAL = /(?<![a-z0-9])(?:(?:remov|delet|revert|restor|invert|undo|drop|disabl)\w*|comment\w*[\s-]+out\b)/iu
const FAILURE = /(?<![a-z0-9])(?:(?:fail|brok|break|redden)\w*|(?:go|goes|going|went|gone|turn|turns|turning|turned)\s+(?:\S+\s+){0,3}?red\b)/iu
const BANNED_SLOTS: readonly string[] = ['Goal:', 'Acceptance:', 'Done when:']
const REPEAT_JUDGED_SLOTS: readonly string[] = ['Workdir:', 'Context:', 'Constraints:']
const QUOTED_MAX = 200

function afterNoMutationLine(item: string): string | undefined {
  const text = item.replace(LEAD, '').replace(/^\d+[.)]/u, '').replace(LEAD, '')
  const match = NO_MUTATION.exec(text)
  return match === null ? undefined : text.slice(match[0].length)
}

function isNoMutationLine(item: string): boolean {
  const rest = afterNoMutationLine(item)
  return rest !== undefined && !EXCEPTION.test(rest)
}

const judgedTextOf = (item: string): string => (isNoMutationLine(item) ? (afterNoMutationLine(item) ?? '') : item)

function voidingItemsOf(items: readonly string[]): string[] | undefined {
  const at = items.findIndex(isNoMutationLine)
  return at === -1 ? undefined : items.slice(at + 1).filter(item => EXCEPTION.test(item))
}

const proseOf = (text: string): string => text.replace(/`[^`]*`/gu, '')

const isBanned = (item: string): boolean => {
  const prose = proseOf(item)
  return MUTATION.test(prose) || (REMOVAL.test(prose) && FAILURE.test(prose))
}

function unitsAfter(items: readonly string[], at: number): string[] {
  const rest = items.slice(at + 1)
  const end = rest.findIndex(next => !UNIT.test(next))
  return end === -1 ? rest : rest.slice(0, end)
}

function bannedItemsOf(slot: string, items: readonly string[], isJudged: boolean): { slot: string; item: string }[] {
  return items.flatMap((item, at) => {
    if (UNIT.test(item)) {
      if (at > 0 && UNIT.test(items[at - 1] ?? '')) return []
      const run = [item, ...unitsAfter(items, at)].map(unit => unit.replace(UNIT, '').trim()).join(' ')
      return isBanned(run) ? [{ slot: 'Unit:', item: run }] : []
    }
    if (!isJudged) return []
    const text = judgedTextOf(item)
    if (isBanned(text)) return [{ slot, item }]
    const units = unitsAfter(items, at)
    return units.length > 0 && REMOVAL.test(proseOf(text)) && FAILURE.test(proseOf([text, ...units].join(' '))) ? [{ slot, item: [item, ...units].join(' ') }] : []
  })
}

export type MutationFindings = { missingSlots: string[]; lacksNoMutationLine: boolean; voidingItems: string[]; bannedItems: { slot: string; item: string }[] }

export function mutationFindingsOf(prompt: string): MutationFindings {
  const constraints = blocksOf(prompt, 'Constraints:')
  const criteria = blocksOf(prompt, 'Acceptance:')
  const voiding = constraints.map(block => voidingItemsOf(block.items))
  return {
    missingSlots: [...(constraints.length === 0 ? ['Constraints:'] : []), ...(criteria.length === 0 ? ['Acceptance:'] : [])],
    lacksNoMutationLine: voiding.includes(undefined),
    voidingItems: voiding.flatMap(items => items ?? []),
    bannedItems: [
      ...BANNED_SLOTS.map(slot => [slot, blocksOf(prompt, slot), 0] as const),
      ...REPEAT_JUDGED_SLOTS.map(slot => [slot, blocksOf(prompt, slot), 1] as const),
    ].flatMap(([slot, blocks, firstJudged]) => blocks.flatMap((block, at) => bannedItemsOf(slot, block.items, at >= firstJudged))),
  }
}

const quoted = (item: string): string => (item.length > QUOTED_MAX ? `${item.slice(0, QUOTED_MAX)}…` : item)

export function mutationDeny(mode: string, findings: MutationFindings): string {
  const fixes = [
    ...findings.missingSlots.map(slot => `- ${slot} could not be found. Write it as a label at the start of its own line, such as "${slot}".`),
    ...(findings.lacksNoMutationLine ? [`- A Constraints: block carries no no-mutation line. Add this exact bullet as the last item of every Constraints: block: "${NO_MUTATION_LINE}"`] : []),
    ...findings.voidingItems.map(
      item =>
        `- The Constraints: item "${quoted(item)}" comes after the no-mutation line and holds except, but, unless or other than, so the gate reads it as an exception and the line does not count. ` +
        `Put the exact line "${NO_MUTATION_LINE}" last in its Constraints: block, after every other item.`,
    ),
    ...findings.bannedItems.map(
      ({ slot, item }) =>
        `- ${slot} "${quoted(item)}" mentions mutation, or holds both a removal word and a failure word. Rephrase it to state what the test covers instead, for example "a test covers <the behavior>". ` +
        'If the item must quote such words, as in "a test covers the GraphQL `mutation` endpoint", put them in backticks, which the gate does not read.',
    ),
  ]
  return [
    `🛑 Blocked: a ${mode} dispatch whose brief does not rule out mutation testing.`,
    '',
    `No-mutation rule (${PLUGIN}). The human ruled out mutation testing of any kind. Every Watson and Holmes brief carries the exact line "${NO_MUTATION_LINE.slice(2)}" as the last item of every Constraints: block, with no exception after it in that block. No item in Goal:, Acceptance: or Done when:, in a repeated Workdir:, Context: or Constraints: block, or on a Unit: line in any block, mentions mutation or says a test fails when something is removed. ` +
      'Nothing was spawned. Make each fix below and dispatch again.',
    ...fixes,
  ].join('\n')
}

const MUTATION_GATED: Readonly<Record<string, string>> = {
  [`${PLUGIN}:watson-direct`]: 'Watson Direct-mode',
  [`${PLUGIN}:holmes-local`]: 'Holmes Local-mode',
}

export function mutationRefusalOf(subagentType: string, prompt: string): string | undefined {
  const mode = MUTATION_GATED[subagentType]
  if (mode === undefined) return undefined
  const findings = mutationFindingsOf(prompt)
  return findings.missingSlots.length > 0 || findings.lacksNoMutationLine || findings.voidingItems.length > 0 || findings.bannedItems.length > 0
    ? mutationDeny(mode, findings)
    : undefined
}

export const UNIT_CRITERIA_LIMIT = 6

export const UNIT_GATED = `${PLUGIN}:watson-direct`

export type UnitCheck = { shape: string; criteria?: number; unit?: string }

export function unitDeny(criteria: number): string {
  return [
    `🛑 Blocked: a Watson Direct-mode dispatch whose brief carries ${criteria} acceptance criteria and names no unit.`,
    '',
    `Unit rule (${PLUGIN}). A Watson brief with more than ${UNIT_CRITERIA_LIMIT} acceptance criteria delivers one unit of the work per dispatch, named on a Unit: line. ` +
      `workbench-core counted ${criteria} criteria in Acceptance:, one per top-level list item, or one per non-blank line when the slot holds no list. ` +
      'Nothing was spawned. Make one fix below and dispatch again.',
    `- Cut the work into units of at most ${UNIT_CRITERIA_LIMIT} criteria. Keep the full list for context if it helps, and add a Unit: line that names the one step this dispatch delivers and the criteria it meets, such as "Unit: 2 of 4, the focus ring. Meets AC3, AC4."`,
    '- If Acceptance: is prose wrapped over several lines, each line counts as one criterion. Write each criterion as a bullet, so it counts once.',
  ].join('\n')
}

export function unitRefusalOf(subagentType: string, check: UnitCheck): string | undefined {
  if (subagentType !== UNIT_GATED || check.shape !== 'brief') return undefined
  if (typeof check.criteria !== 'number' || !Number.isInteger(check.criteria)) return spawnFailedDeny()
  return check.unit === undefined && check.criteria > UNIT_CRITERIA_LIMIT ? unitDeny(check.criteria) : undefined
}

export type ResumeFindings = { voidingItems: string[]; bannedItems: string[] }

export function resumeFindingsOf(message: string): ResumeFindings {
  return {
    voidingItems: blocksOf(message, 'Constraints:').flatMap(block => voidingItemsOf(block.items) ?? []),
    bannedItems: bannedItemsOf('', messageItemsOf(message), true).map(({ item }) => item),
  }
}

export type ResumedAgent = 'Watson' | 'Holmes' | 'Watson or Holmes'

export function resumedAgentOf(subagentType: string | undefined): ResumedAgent | undefined {
  const family = familyOf(subagentType)
  return family === 'watson' ? 'Watson' : family === 'holmes' ? 'Holmes' : undefined
}

export const resumedAgentOfRead = (read: Promise<string | undefined>, fallback: string | undefined): Promise<ResumedAgent | undefined> =>
  read.then(
    value => resumedAgentOf(value ?? fallback),
    (): ResumedAgent => 'Watson or Holmes',
  )

export function resumeDeny(agent: ResumedAgent, findings: ResumeFindings): string {
  const fixes = [
    ...findings.bannedItems.map(
      item =>
        `- The item "${quoted(item)}" mentions mutation, or holds both a removal word and a failure word. Rephrase it to state what the test covers instead. ` +
        'If it must quote such words, put them in backticks, which the gate does not read.',
    ),
    ...findings.voidingItems.map(
      item => `- The Constraints: item "${quoted(item)}" comes after the no-mutation line and holds except, but, unless or other than, so the gate reads it as an exception to the line. Remove it, or move it above the line.`,
    ),
  ]
  return [
    `🛑 Blocked: a message to a ${agent} that does not rule out mutation testing.`,
    '',
    `No-mutation rule (${PLUGIN}). The human ruled out mutation testing of any kind. The message was not delivered, and no agent resumed. ` +
      "A message to a Watson or Holmes carries a correction to the agent's own brief, which keeps its no-mutation line, so it needs no Constraints: or Acceptance: block. " +
      'No item of it may mention mutation or say a test fails when something is removed, and it may add no exception to the no-mutation line. Make each fix below and send the message again.',
    ...fixes,
  ].join('\n')
}

export function resumeRefusalOf(agent: ResumedAgent | undefined, message: string): string | undefined {
  if (agent === undefined) return undefined
  const findings = resumeFindingsOf(message)
  return findings.bannedItems.length > 0 || findings.voidingItems.length > 0 ? resumeDeny(agent, findings) : undefined
}
