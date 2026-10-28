import { activeSession, emit, hookInput } from './gate.ts'

const input = await hookInput()
if (activeSession(process.env.HOME, input) !== undefined) {
  const { RULES, isRulesLane } = await import('../mods/session-rules.ts')
  if (isRulesLane(process.env.WORKBENCH_SKIP_WARMUP)) emit('SessionStart', RULES)
}
