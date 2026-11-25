import type { ShellParse } from './review-guard'
import { ghFault } from './review-guard'
import { PLUGIN } from './spawn'

const EXTERNAL_TYPE = /(^|[:/])(watson|holmes|lestrade)-external$/iu
const POSTER = /(^|\/)external-gh\.sh$/u
const LOCAL_GH: readonly (readonly [string, string])[] = [
  ['repo', 'clone'],
  ['pr', 'checkout'],
]

export const isExternalType = (type: string | undefined): boolean => type !== undefined && EXTERNAL_TYPE.test(type.trim())

export type ExternalCaller = { isReviewer: boolean; isExternal: boolean }

export function externalFault(parse: ShellParse, caller: ExternalCaller): string | undefined {
  for (const s of parse.statements) {
    if (caller.isReviewer && s.words.some(word => POSTER.test(word))) {
      return deny(
        'a Holmes reviewer ran external-gh.sh.',
        'A reviewer posts nothing to GitHub, in any mode and under any parent run. The verdict goes to the session that dispatched you, or to the result file in external mode.',
      )
    }
    if (!caller.isExternal || s.name !== 'gh') continue
    const [group = '', verb = ''] = s.args
    if (LOCAL_GH.some(([g, v]) => g === group && v === verb)) continue
    const fault = ghFault(s.args)
    if (fault !== undefined) {
      return deny(
        `${fault.action} in an external run.`,
        `${fault.action} can write to GitHub as Mike, with no agent marker, no footer, and no draft. In an external run every GitHub write goes through \`\${CLAUDE_PLUGIN_ROOT}/bin/external-gh.sh\`, and every other gh call reads.`,
      )
    }
  }
  return undefined
}

function deny(action: string, reason: string): string {
  return `🛑 Blocked: ${action}\n\nExternal write rule (${PLUGIN}). ${reason} Do not try another spelling.`
}
