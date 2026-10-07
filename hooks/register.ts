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
//   tool.call    the gate's advisory hint on a complete brief that dictates
//                method, after the Agent call ran
//
// The logic is pure and lives in mods/spawn.ts. Every hook that touches `$`
// lives in this file, because the engine follows `$` into no imported function,
// and a plugin registers each event once.
//
// The scheduled path never reaches this module's routing or knobs: it starts
// the mode type directly (`claude -p --agent workbench-dev-team:watson-index`),
// and bin/dispatch-agent.sh passes the config's model and effort as flags.

import type { EngineInterface, Register } from 'claude-code'

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

  on('tool.call', { tool: 'Agent' }, async ($, e, next) => {
    const result = await next(e)
    if (result.deny !== undefined || result.isError || next.origin.plugin !== 'engine') return result
    if (typeof e.prompt !== 'string' || !(await gated($, e.agentId))) return result
    const check = await $.workbench.briefCheck(e.prompt).catch(() => undefined)
    const hint = check === undefined ? undefined : hintOf(check, e.prompt)
    return hint === undefined ? result : { ...result, context: [...(result.context ?? []), hint] }
  }).catch(($, e, next) => next(e))
}
