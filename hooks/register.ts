// workbench-dev-team's hooks module, beside the command hooks in hooks.json.
// It builds on workbench-core's $.workbench noun (dependencies in plugin.json).
//
//   agent.spawn  one dispatch of a dev-team agent, in order:
//                1. the dispatch gate: a main-session dispatch whose brief
//                   lacks a slot is refused, as hooks/agent-dispatch-gate.sh
//                   in workbench-core refuses it, and so is one whose brief
//                   cannot be checked
//                2. routing: a dispatch of watson, holmes or lestrade runs the
//                   mode agent its token picks (bin/compose-agents.sh builds
//                   them), so the public names keep working
//                3. model and effort from ~/.claude-workbench/dev-team-config.json
//   turn.step    applies the effort step 3 recorded, to that sub-agent's loop
//   tool.call    on Bash, Edit, Write and NotebookEdit, before the call:
//                1. the commit guard (mods/commit-guard.ts), on every Bash
//                   line in every lane: a forced or deleting push, a merge by
//                   an agent or the pipeline, a sub-agent's commit or push,
//                   and a commit, push or merge the ask rules cannot see
//                2. the review guard (mods/review-guard.ts): a Holmes
//                   reviewer, or anything he spawned, writes only in scratch
//                Both read the line through $.workbench.parseShell, take the
//                lane from $.workbench.callerLane and isUnattended, and refuse
//                the call when they throw.
//                On Agent, after the call ran: the gate's advisory hint on a
//                complete brief that dictates method
//
// The logic is pure and lives in mods/spawn.ts, mods/commit-guard.ts and
// mods/review-guard.ts. Every hook that touches `$`
// lives in this file, because the engine follows `$` into no imported function,
// and a plugin registers each event once.
//
// The scheduled path never reaches this module's routing or knobs: it starts
// the mode type directly (`claude -p --agent workbench-dev-team:watson-index`),
// and bin/dispatch-agent.sh passes the config's model and effort as flags.

import type { EngineInterface, Register } from 'claude-code'

import { commitVerdict } from './mods/commit-guard'
import type { ShellParse } from './mods/commit-guard'
import type { Disk } from './mods/review-guard'
import { isReviewerType, judgeWrites, refusalOf, reviewBash, reviewEdit } from './mods/review-guard'
import type { CallerLane } from './mods/spawn'
import { denyOf, familyOf, hintOf, isGated, knobsOf, modeTypeOf, uncheckedDeny } from './mods/spawn'

const CONFIG = '.claude-workbench/dev-team-config.json'

// Whether the dispatch gate judges a call made in the loop `agentId` names.
// The lane rejects while it is unknown; a gate then reads it as the main
// session, so the brief is still checked. orchestratorIsOn already fails toward
// on, and its .catch does the same.
async function gated($: EngineInterface, agentId: string | undefined): Promise<boolean> {
  const lane = await $.workbench.callerLane(agentId === undefined ? {} : { agentId }).catch(() => 'main' as const)
  const isOn = await $.workbench.orchestratorIsOn().catch(() => true)
  return isGated(lane, isOn)
}

// The config's text, or undefined when it cannot be read.
async function configText($: EngineInterface): Promise<string | undefined> {
  const home = await $.env.get('HOME')
  if (!home) return undefined
  return $.fs.read(`${home}/${CONFIG}`).catch(() => undefined)
}

// ── The guards ───────────────────────────────────────────────────────────────

const GUARDED: ReadonlySet<string> = new Set(['Bash', 'Edit', 'Write', 'NotebookEdit'])

const GUARD_FAILED =
  '🛑 Blocked: a call the guards could not judge.\n\nworkbench-dev-team. The commit guard or the review guard failed while reading this call, so it is refused rather than let an unread commit, push, merge, or write through. Report this to the human as a guard defect. Do not try another spelling.'

// The input fields the guards read. The engine types them per tool; these are
// read as unknown, so a field of the wrong type is judged as absent.
type GuardInput = { tool: string; agentId?: string; command?: unknown; file_path?: unknown; notebook_path?: unknown }

// Whether a call comes from a Holmes reviewer, or from anything a reviewer
// spawned: true, false, or undefined when it cannot be told. A top-level
// `--agent` run names its type in CLAUDE_CODE_AGENT, and every loop in it is
// held. A sub-agent's type, and its parents', come from $.agent.list().
async function isReviewer($: EngineInterface, agentId: string | undefined, lane: CallerLane | undefined): Promise<boolean | undefined> {
  if (isReviewerType(await $.env.get('CLAUDE_CODE_AGENT').catch(() => undefined))) return true
  if (lane === 'main' || lane === 'top-level-agent') return false
  if (lane === undefined || agentId === undefined) return undefined
  const agents = await $.agent.list().catch(() => undefined)
  if (agents === undefined) return undefined
  const seen = new Set<string>()
  for (let id: string | undefined = agentId; id !== undefined && !seen.has(id); ) {
    seen.add(id)
    const agent = agents.find(a => a.id === id)
    if (agent === undefined) return undefined
    if (isReviewerType(agent.type)) return true
    id = agent.parentId
  }
  return false
}

// The scratch roots: core's, and $TMPDIR, each a physical directory.
async function scratchRootsOf($: EngineInterface): Promise<string[]> {
  const roots = [...(await $.workbench.scratchRoots().catch(() => []))]
  const tmp = await $.env.get('TMPDIR').catch(() => undefined)
  const real = tmp ? (await $.fs.stat(tmp, { resolve: true }).catch(() => undefined))?.realPath : undefined
  if (real !== undefined && (await $.fs.stat(real).catch(() => undefined))?.kind === 'dir') roots.push(real)
  return roots
}

// The review guard's refusal for a reviewer's call, or undefined.
async function reviewDeny($: EngineInterface, e: GuardInput, parse: ShellParse | undefined): Promise<string | undefined> {
  const cwd = await $.session.cwd().catch(() => undefined)
  const context = { cwd, home: await $.env.get('HOME').catch(() => undefined) }
  let verdict
  if (e.tool === 'Bash') {
    if (parse === undefined) return undefined
    verdict = reviewBash(parse, context)
  } else {
    const raw = e.tool === 'NotebookEdit' ? e.notebook_path : e.file_path
    verdict = reviewEdit(e.tool, typeof raw === 'string' ? raw : '', context)
  }
  const roots = await scratchRootsOf($)
  if ('finding' in verdict) return refusalOf(verdict.finding, roots)
  const disk: Disk = {
    stat: path => $.fs.stat(path, { resolve: true }).then(stat => ({ realPath: stat.realPath }), () => undefined),
    names: dir => $.fs.list(dir).then(entries => entries.map(entry => entry.name), () => undefined),
  }
  const finding = await judgeWrites(verdict.writes, roots, disk)
  return finding === undefined ? undefined : refusalOf(finding, roots)
}

// Both guards on one call: the commit guard on a Bash line in every lane, then
// the review guard when a reviewer makes the call, or when who makes it cannot
// be told and the call writes outside scratch.
async function guard($: EngineInterface, e: GuardInput): Promise<string | undefined> {
  const lane = await $.workbench.callerLane(e.agentId === undefined ? {} : { agentId: e.agentId }).catch(() => undefined)
  let parse: ShellParse | undefined
  if (e.tool === 'Bash') {
    const line = typeof e.command === 'string' ? e.command : ''
    parse = await $.workbench.parseShell(line)
    const isUnattended = await $.workbench.isUnattended().catch(() => true)
    const refused = commitVerdict(parse, line, { lane, isUnattended })
    if (refused !== undefined) return refused.deny
  }
  const reviewer = await isReviewer($, e.agentId, lane)
  if (reviewer === false) return undefined
  const deny = await reviewDeny($, e, parse)
  if (deny === undefined || reviewer) return deny
  return `${deny}\n\nThe guard could not tell which agent made this call, so it held the call to the reviewer's rule. Report this to the human as a guard defect.`
}

export const register: Register = on => {
  // The gate fails closed: a dispatch it judges whose brief cannot be checked
  // is refused, and so is one whose gate throws before next is called.
  // workbench-core is a declared dependency, so a check that rejects is a
  // fault, and /orchestrator off is the way past it. What follows the gate
  // (the config, the routing) is not a guard: when it fails, the dispatch goes
  // on unchanged, unrouted and on the agent file's own model, which is how the
  // public type runs without this module.
  on('agent.spawn', async ($, e, next) => {
    // Only the model's own Agent calls are gated, the ones the bash gate sees.
    // A plugin's $.agent.spawn is the plugin's implementation, not a handoff.
    if (next.origin.plugin === 'engine' && (await gated($, e.parentAgentId))) {
      const check = await $.workbench.briefCheck(e.prompt).catch(() => undefined)
      if (check === undefined) return { deny: uncheckedDeny() }
      if (!check.isComplete) {
        const slots = await $.workbench.briefSlots().catch(() => [])
        return { deny: denyOf(check.missing, slots) }
      }
    }

    // Nothing in this block calls next, so a failure here passes the dispatch
    // on unchanged, and next is called once either way.
    let routed: typeof e | undefined
    let knobs: ReturnType<typeof knobsOf> = {}
    try {
      const family = familyOf(e.subagentType)
      if (family !== undefined) {
        knobs = knobsOf(await configText($), family)
        // A model the caller named is the caller's choice, and stands.
        const model = e.model ?? knobs.model
        routed = { ...e, subagentType: modeTypeOf(family, e.prompt), ...(model === undefined ? {} : { model }) }
      }
    } catch {
      routed = undefined
    }
    if (routed === undefined) return next(e)
    const result = await next(routed)
    if (result.agentId !== undefined && knobs.effort !== undefined) {
      await $.state.set({ plugin: 'workbench-dev-team', key: 'effort', id: result.agentId }, knobs.effort)
    }
    return result
  }).catch(($, e, next) => (next.called ? next(e) : { deny: uncheckedDeny() }))

  on('turn.step', async function* ($, e, next) {
    if (e.agentId === undefined) return yield* next(e)
    const { value: effort } = await $.state.get({ plugin: 'workbench-dev-team', key: 'effort', id: e.agentId })
    return yield* next(effort === undefined ? e : { ...e, effort })
  })

  // One tool.call hook, since a plugin registers each event once. It runs the
  // two guards on Bash and the editing tools before the call, and adds the
  // dispatch gate's hint after an Agent call. A guard that throws refuses the
  // call (fail closed), and the hint's failure leaves the call as it ran.
  on('tool.call', async ($, e, next) => {
    if (e.tool === 'Bash' || e.tool === 'Edit' || e.tool === 'Write' || e.tool === 'NotebookEdit') {
      const deny = await guard($, e)
      return deny === undefined ? next(e) : { deny }
    }
    if (e.tool !== 'Agent') return next(e)
    const result = await next(e)
    if (result.deny !== undefined || result.isError || next.origin.plugin !== 'engine') return result
    if (typeof e.prompt !== 'string' || !(await gated($, e.agentId))) return result
    const check = await $.workbench.briefCheck(e.prompt).catch(() => undefined)
    const hint = check === undefined ? undefined : hintOf(check, e.prompt)
    return hint === undefined ? result : { ...result, context: [...(result.context ?? []), hint] }
  }).catch(($, e, next) => (next.called || !GUARDED.has(e.tool) ? next(e) : { deny: GUARD_FAILED }))
}
