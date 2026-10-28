import { activeSession, emit, hookInput } from './gate.ts'

const input = await hookInput()
if (activeSession(process.env.HOME, input) !== undefined && typeof input.agent_type === 'string') {
  const { RULES, isRulesLane, isRulesSubagent } = await import('../mods/session-rules.ts')
  if (isRulesSubagent(input.agent_type) && isRulesLane(process.env.WORKBENCH_SKIP_WARMUP)) emit('SubagentStart', RULES)
}
