// workbench-dev-team's hooks module, beside the command hooks in hooks.json.
// It builds on workbench-core's $.workbench noun (dependencies in plugin.json).
//
//   agent.spawn    one dispatch of an agent, in order:
//                  1. the dispatch gate: a main-session dispatch whose brief
//                     lacks a slot is refused, as hooks/agent-dispatch-gate.sh
//                     in workbench-core refuses it, and so is one whose brief
//                     cannot be checked
//                  2. the helper rule: a spawn Holmes makes, in any mode, runs
//                     on holmes-lens whatever type it named, and a fork or a
//                     teammate of his is refused
//                  3. the workspace check: a gated Watson Direct-mode brief
//                     whose Workdir: is a bare path, on a repo on main, master
//                     or trunk, is refused with an ask-for-a-branch reason
//                  4. routing: a dispatch of watson, holmes or lestrade runs the
//                     mode agent its token picks (bin/compose-agents.sh builds
//                     them), so the public names keep working
//                  5. model and effort from ~/.claude-workbench/dev-team-config.json,
//                     and for holmes-local, holmes-index and lestrade-item the
//                     config line (fanout, lensModel) added to the prompt
//                  Each dev-team agent's type is kept by its agentId.
//   prompt.submit  the config line, as context, for the top-level loop of a
//                  `claude -p --agent` run of those three modes: the run
//                  bin/dispatch-agent.sh starts raises no agent.spawn
//   turn.step      applies the effort step 5 recorded, to that sub-agent's
//                  loop, and measures each dev-team request's working context
//                  against the budget, notifying the human once per run
//   turn.complete  deletes the run's scratch folder unless a child it spawned is
//                  still live, and resets its budget notice
//   tool.call      on Bash, Edit, Write and NotebookEdit, before the call:
//                  1. scratch: a dev-team agent's bare mktemp is pointed at a
//                     folder of its own under a scratch root (mods/scratch.ts)
//                  2. the commit guard (mods/commit-guard.ts), on every Bash
//                     line in every lane: a forced or deleting push, a merge by
//                     an agent or the pipeline, a sub-agent's commit or push,
//                     and a commit, push or merge the ask rules cannot see
//                  3. the commit subject check (mods/commit-subject.ts) on
//                     every commit the guard lets through
//                  4. the review guard (mods/review-guard.ts): a Holmes
//                     reviewer, or anything he spawned, writes only in scratch
//                  The guards read the line through $.workbench.parseShell,
//                  take the lane from $.workbench.callerLane and isUnattended,
//                  and refuse the call when they throw.
//                  On Agent, from the main session (mods/dispatch.ts): a Watson
//                  `Item ID: <n>` call runs bin/dispatch-agent.sh in its place
//                  and answers with the dispatcher's first line, and a dev-team
//                  call that did not ask for the foreground runs in the
//                  background. After the call ran: the gate's advisory hint on
//                  a complete brief that dictates method.
//
// The logic is pure and lives in mods/. Every hook that touches `$` lives in
// this file, because the engine follows `$` into no imported function, and a
// plugin registers each event once.
//
// The scheduled path never reaches agent.spawn: it starts the mode type
// directly (`claude -p --agent workbench-dev-team:watson-index`), and
// bin/dispatch-agent.sh passes the config's model and effort as flags. The
// other hooks run in that process too.

import type { EngineInterface, Register, TurnUsage } from 'claude-code'

import { budgetNotice, contextOf, isOverBudget } from './mods/budget'
import { commitVerdict } from './mods/commit-guard'
import type { ShellParse } from './mods/commit-guard'
import { subjectVerdict } from './mods/commit-subject'
import { DISPATCH_CONTEXT, dispatchDeny, dispatcherArgv, dispatchOutcome, dispatchResult, indexDispatchOf, isForcedBackground } from './mods/dispatch'
import type { Disk } from './mods/review-guard'
import { isReviewerType, judgeWrites, refusalOf, reviewBash, reviewEdit } from './mods/review-guard'
import { hasBareMktemp, hasLiveChild, isDeletable, pointMktemp, prefixOf, readsAsPointed, rootOf } from './mods/scratch'
import type { CallerLane } from './mods/spawn'
import {
  CONFIG_MODES,
  DEFAULT_BRANCHES,
  branchDeny,
  branchUnreadDeny,
  configLineOf,
  denyOf,
  familyOf,
  hintOf,
  isDevTeamType,
  isGated,
  isHolmesMode,
  knobsOf,
  lensSpawnOf,
  modeTypeOf,
  uncheckedDeny,
  withConfigLine,
  workdirOf,
} from './mods/spawn'

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

// ── Whose run a loop is ──────────────────────────────────────────────────────

// A dev-team run, as the per-run state keys it: its agent type, and its agentId,
// or `run` for the top-level loop of a `claude -p --agent` run. Undefined for
// the main session and for every agent outside the dev-team.
type Run = { type: string; key: string }

async function runOf($: EngineInterface, agentId: string | undefined): Promise<Run | undefined> {
  if (agentId !== undefined) {
    const { value: type } = await $.state.get({ plugin: 'workbench-dev-team', key: 'agentType', id: agentId })
    return isDevTeamType(type) && type !== undefined ? { type, key: agentId } : undefined
  }
  if ((await $.workbench.callerLane({})) !== 'top-level-agent') return undefined
  const type = await $.env.get('CLAUDE_CODE_AGENT')
  return isDevTeamType(type) && type !== undefined ? { type, key: 'run' } : undefined
}

// The type of the loop a spawn happens in: the top-level `--agent` type, or
// none, for a main-loop spawn; the type the mod kept, or the one
// $.agent.list() gives, for a sub-agent's. Undefined when it cannot be told.
async function spawnerTypeOf($: EngineInterface, parentAgentId: string | undefined): Promise<string | undefined> {
  if (parentAgentId === undefined) return $.env.get('CLAUDE_CODE_AGENT').catch(() => undefined)
  const { value: kept } = await $.state.get({ plugin: 'workbench-dev-team', key: 'agentType', id: parentAgentId })
  if (kept !== undefined) return kept
  const agents = await $.agent.list().catch(() => undefined)
  return agents?.find(agent => agent.id === parentAgentId)?.type
}

// ── Scratch folders ──────────────────────────────────────────────────────────

// The run's scratch folder: the one it has, or a new one under the first
// scratch root, made with mktemp. Undefined when none can be made.
async function scratchFolderOf($: EngineInterface, run: Run): Promise<string | undefined> {
  const { value: kept } = await $.state.get({ plugin: 'workbench-dev-team', key: 'scratch', id: run.key })
  if (kept && (await $.fs.exists(kept).catch(() => false))) return kept
  const roots = await $.workbench.scratchRoots()
  const root = rootOf(roots)
  if (root === undefined) return undefined
  const made = await $.process.run(['mktemp', '-d', `${root}/${prefixOf(run.type)}.XXXXXX`])
  const folder = made.stdout.trim()
  if (made.exitCode !== 0 || !isDeletable(folder, roots)) return undefined
  await $.state.set({ plugin: 'workbench-dev-team', key: 'scratch', id: run.key }, folder)
  return folder
}

// The Bash line with a dev-team agent's bare mktemp pointed at its folder, or
// the line as written when it has none, or when anything here fails: a mktemp
// left in $TMPDIR is how the line ran before the mod.
async function withScratch($: EngineInterface, agentId: string | undefined, line: string): Promise<string> {
  if (!line.includes('mktemp')) return line
  try {
    const before = await $.workbench.parseShell(line)
    if (!hasBareMktemp(before)) return line
    const run = await runOf($, agentId)
    if (run === undefined) return line
    const folder = await scratchFolderOf($, run)
    if (folder === undefined) return line
    const pointed = pointMktemp(line, folder)
    if (pointed === undefined) return line
    return readsAsPointed(before, await $.workbench.parseShell(pointed), folder) ? pointed : line
  } catch {
    return line
  }
}

// The end of a turn: the run's scratch folder deleted, unless a child the run
// spawned is still live, and its budget notice reset. A child's end never
// deletes its parent's folder: an ended agent may resume, as Holmes does when
// his background helpers report, and read it again. A folder kept for a live
// child goes at the end of the next turn that finds none. When the agent list
// cannot be read, the folder stays.
async function endRun($: EngineInterface, agentId: string | undefined): Promise<void> {
  const key = agentId ?? ((await $.workbench.callerLane({})) === 'top-level-agent' ? 'run' : undefined)
  if (key === undefined) return
  const { value: folder } = await $.state.get({ plugin: 'workbench-dev-team', key: 'scratch', id: key })
  const agents = folder ? await $.agent.list().catch(() => undefined) : undefined
  if (folder && agents !== undefined && !hasLiveChild(agents, agentId)) {
    if (isDeletable(folder, await $.workbench.scratchRoots())) await $.process.run(['rm', '-rf', '--', folder])
    await $.state.set({ plugin: 'workbench-dev-team', key: 'scratch', id: key }, '')
  }
  const { value: told } = await $.state.get({ plugin: 'workbench-dev-team', key: 'overBudget', id: key })
  if (told) await $.state.set({ plugin: 'workbench-dev-team', key: 'overBudget', id: key }, false)
}

// ── The context budget ───────────────────────────────────────────────────────

async function measure($: EngineInterface, agentId: string | undefined, usage: TurnUsage | null): Promise<void> {
  const tokens = contextOf(usage)
  if (!isOverBudget(tokens) || tokens === undefined) return
  const run = await runOf($, agentId)
  if (run === undefined) return
  const { value: told } = await $.state.get({ plugin: 'workbench-dev-team', key: 'overBudget', id: run.key })
  if (told) return
  await $.state.set({ plugin: 'workbench-dev-team', key: 'overBudget', id: run.key }, true)
  const notice = budgetNotice(run.type, run.key, tokens)
  $.ui.toast(notice, { timeoutMs: 15000 })
  $.ui.log(notice, { to: 'transcript' })
}

// ── The Index dispatcher ─────────────────────────────────────────────────────

// The Agent call's answer for a Watson Index-mode dispatch: the dispatcher's
// first line, or a refusal. It never falls through to a spawn, which would
// start a run without its pipeline flag.
async function runDispatcher($: EngineInterface, itemId: string, prompt: string) {
  const home = await $.env.get('HOME').catch(() => undefined)
  if (!home) return { deny: dispatchDeny('HOME is not set, so the dispatcher cannot be found') }
  const run = await $.process.run(dispatcherArgv(home, itemId), { timeoutMs: 120_000 }).catch(() => undefined)
  if (run === undefined) return { deny: dispatchDeny('the dispatcher could not run') }
  const outcome = dispatchOutcome(run)
  if ('deny' in outcome) return outcome
  return { result: dispatchResult(outcome.line, prompt), context: [DISPATCH_CONTEXT] }
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

// The guards on one call: the commit guard and the subject check on a Bash line
// in every lane, then the review guard when a reviewer makes the call, or when
// who makes it cannot be told and the call writes outside scratch.
async function guard($: EngineInterface, e: GuardInput): Promise<string | undefined> {
  const lane = await $.workbench.callerLane(e.agentId === undefined ? {} : { agentId: e.agentId }).catch(() => undefined)
  let parse: ShellParse | undefined
  if (e.tool === 'Bash') {
    const line = typeof e.command === 'string' ? e.command : ''
    parse = await $.workbench.parseShell(line)
    const isUnattended = await $.workbench.isUnattended().catch(() => true)
    const refused = commitVerdict(parse, line, { lane, isUnattended }) ?? subjectVerdict(parse)
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
  // fault, and /orchestrator off is the way past it. The helper rule and the
  // workspace check are refusals too, and each says how it fails below. What
  // follows them (the config, the routing) is not a guard: when it fails, the
  // dispatch goes on unchanged, unrouted and on the agent file's own model,
  // which is how the public type runs without this module.
  on('agent.spawn', async ($, e, next) => {
    // Only the model's own Agent calls are judged, the ones the bash gate sees.
    // A plugin's $.agent.spawn is the plugin's implementation, not a handoff.
    const isModel = next.origin.plugin === 'engine'
    const isGatedCall = isModel && (await gated($, e.parentAgentId))
    if (isGatedCall) {
      const check = await $.workbench.briefCheck(e.prompt).catch(() => undefined)
      if (check === undefined) return { deny: uncheckedDeny() }
      if (!check.isComplete) {
        const slots = await $.workbench.briefSlots().catch(() => [])
        return { deny: denyOf(check.missing, slots) }
      }
    }

    // The helper rule. A spawner the mod cannot name is let through: the
    // review guard still holds every write by anything Holmes spawned.
    let input = e
    if (isModel && isHolmesMode(await spawnerTypeOf($, e.parentAgentId))) {
      const lens = lensSpawnOf(e)
      if ('deny' in lens) return lens
      input = { ...e, subagentType: lens.subagentType }
    }

    // The workspace check. git answering with no branch (not a repository, or
    // a detached HEAD) passes; git that cannot run at all refuses, since the
    // answer is then unknown, and recording a branch in Workdir: passes.
    if (isGatedCall && familyOf(input.subagentType) === 'watson' && modeTypeOf('watson', input.prompt).endsWith(':watson-direct')) {
      const workdir = workdirOf(input.prompt)
      if (workdir !== undefined && !workdir.isRecorded && workdir.path.startsWith('/')) {
        const head = await $.process
          .run(['git', '-C', workdir.path, 'symbolic-ref', '--quiet', '--short', 'HEAD'], { timeoutMs: 10_000 })
          .catch(() => undefined)
        if (head === undefined) return { deny: branchUnreadDeny(workdir.path) }
        const branch = head.stdout.trim()
        if (head.exitCode === 0 && DEFAULT_BRANCHES.includes(branch)) return { deny: branchDeny(workdir.path, branch) }
      }
    }

    // Nothing in this block calls next, so a failure here passes the dispatch
    // on unchanged, and next is called once either way.
    let routed: typeof e | undefined
    let knobs: ReturnType<typeof knobsOf> = {}
    try {
      const family = familyOf(input.subagentType)
      if (family !== undefined) {
        const text = await configText($)
        knobs = knobsOf(text, family)
        const subagentType = modeTypeOf(family, input.prompt)
        const configFamily = CONFIG_MODES[subagentType]
        const prompt = configFamily === undefined ? input.prompt : withConfigLine(input.prompt, configLineOf(text, configFamily))
        // A model the caller named is the caller's choice, and stands.
        const model = input.model ?? knobs.model
        routed = { ...input, subagentType, prompt, ...(model === undefined ? {} : { model }) }
      }
    } catch {
      routed = undefined
    }
    const spawned = routed ?? input
    const result = await next(spawned)
    if (result.agentId !== undefined) {
      if (routed !== undefined && knobs.effort !== undefined) {
        await $.state.set({ plugin: 'workbench-dev-team', key: 'effort', id: result.agentId }, knobs.effort)
      }
      if (isDevTeamType(spawned.subagentType)) {
        await $.state.set({ plugin: 'workbench-dev-team', key: 'agentType', id: result.agentId }, spawned.subagentType)
      }
    }
    return result
  }).catch(($, e, next) => (next.called ? next(e) : { deny: uncheckedDeny() }))

  // The config line for a top-level run of a mode that reads it. Nothing here
  // calls next, so a failure leaves the prompt as it came.
  on('prompt.submit', async ($, e, next) => {
    let line: string | undefined
    try {
      if ((await $.workbench.callerLane({})) === 'top-level-agent') {
        const family = CONFIG_MODES[(await $.env.get('CLAUDE_CODE_AGENT')) ?? '']
        if (family !== undefined) line = configLineOf(await configText($), family)
      }
    } catch {
      line = undefined
    }
    return next(line === undefined ? e : { ...e, context: [...(e.context ?? []), line] })
  })

  on('turn.step', async function* ($, e, next) {
    let input = e
    if (e.agentId !== undefined) {
      const { value: effort } = await $.state.get({ plugin: 'workbench-dev-team', key: 'effort', id: e.agentId })
      if (effort !== undefined) input = { ...e, effort }
    }
    const result = yield* next(input)
    await measure($, e.agentId, result.usage).catch(() => undefined)
    return result
  })

  on('turn.complete', async ($, e, next) => {
    const result = await next(e)
    await endRun($, e.agentId).catch(() => undefined)
    return result
  })

  // One tool.call hook, since a plugin registers each event once. A guard that
  // throws refuses the call (fail closed), a scratch rewrite that fails leaves
  // the line as written, and the hint's failure leaves the call as it ran.
  on('tool.call', async ($, e, next) => {
    if (e.tool === 'Bash' || e.tool === 'Edit' || e.tool === 'Write' || e.tool === 'NotebookEdit') {
      const call = e.tool === 'Bash' && typeof e.command === 'string' ? { ...e, command: await withScratch($, e.agentId, e.command) } : e
      const deny = await guard($, call)
      return deny === undefined ? next(call) : { deny }
    }
    if (e.tool !== 'Agent') return next(e)
    const isModel = next.origin.plugin === 'engine'
    let call = e
    if (isModel) {
      // A set agentId is a sub-agent's call, whatever callerLane says, so a
      // sub-agent never reaches the dispatcher. Only a call with no agentId
      // asks the lane, and a lookup that fails there reads as the main session.
      const isMain = e.agentId === undefined && (await $.workbench.callerLane({}).catch(() => 'main' as const)) === 'main'
      if (isMain) {
        const itemId = indexDispatchOf(e.subagent_type, e.prompt)
        if (itemId !== undefined) return runDispatcher($, itemId, e.prompt)
        if (isForcedBackground(e.subagent_type, e.run_in_background)) call = { ...e, run_in_background: true }
      }
    }
    const result = await next(call)
    if (result.deny !== undefined || result.isError || !isModel) return result
    if (typeof e.prompt !== 'string' || !(await gated($, e.agentId))) return result
    const check = await $.workbench.briefCheck(e.prompt).catch(() => undefined)
    const hint = check === undefined ? undefined : hintOf(check, e.prompt)
    return hint === undefined ? result : { ...result, context: [...(result.context ?? []), hint] }
  }).catch(($, e, next) => (next.called || !GUARDED.has(e.tool) ? next(e) : { deny: GUARD_FAILED }))
}
