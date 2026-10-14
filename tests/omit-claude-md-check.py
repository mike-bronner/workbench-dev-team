#!/usr/bin/env python3
import bisect
import importlib.util
import re
import sys
from pathlib import Path

USAGE = 'Usage: omit-claude-md-check.py <claude binary> <workbench-core root> [session-rules.ts]'
HERE = Path(__file__).resolve().parent
ROOT = HERE.parent

spec = importlib.util.spec_from_file_location('core_check', HERE / 'core' / 'scripts' / 'omit-claude-md-check.py')
core = importlib.util.module_from_spec(spec)
spec.loader.exec_module(core)
CHUNK = b'// @bun'


def built_in_omitters(binary: bytes) -> set[str]:
    starts = [0] + [m.start() for m in re.finditer(re.escape(CHUNK), binary)] + [len(binary)]
    found: set[str] = set()
    seen_anchor = False
    for m in core.DEFINITION.finditer(binary):
        end = core.END.search(binary, m.end())
        body = binary[m.end():end.start() if end else len(binary)]
        if core.BUILT_IN not in body:
            continue
        seen_anchor = seen_anchor or m.group(1) == f'"{core.ANCHOR}"'.encode()
        if core.OMITS.search(body):
            i = bisect.bisect_right(starts, m.start())
            found.add(core.resolve(binary[starts[i - 1]:starts[i]], m.group(1)))
    if not seen_anchor:
        raise core.Unreadable(f'no {core.ANCHOR!r} built-in agent found: the CLI binary layout is not one this check can read')
    return found


def listed(rules: Path) -> set[str]:
    block = re.search(r'export const OMITS_CLAUDE_MD\b[^=]*=\s*new Set\(\[(.*?)\]\)', rules.read_text(), re.S)
    if block is None:
        raise core.Unreadable(f'OMITS_CLAUDE_MD not found in {rules}')
    return set(re.findall(r"'([^']*)'", block.group(1)))


def main(argv: list[str]) -> int:
    if len(argv) not in (3, 4):
        print(USAGE, file=sys.stderr)
        return 2
    rules = Path(argv[3]) if len(argv) == 4 else ROOT / 'hooks' / 'mods' / 'session-rules.ts'
    try:
        actual = listed(rules)
        expected = built_in_omitters(Path(argv[1]).read_bytes()) | core.plugin_omitters(Path(argv[2])) | core.plugin_omitters(ROOT)
    except (OSError, ValueError, KeyError, core.Unreadable) as err:
        print(f'omit-claude-md-check: cannot read a source: {err}', file=sys.stderr)
        return 2
    missing, extra = sorted(expected - actual), sorted(actual - expected)
    if not missing and not extra:
        print(f'OMITS_CLAUDE_MD matches the agents that omit CLAUDE.md: {", ".join(sorted(actual))}')
        return 0
    if missing:
        print(f'OMITS_CLAUDE_MD is missing agents defined with omitClaudeMd: {", ".join(missing)}', file=sys.stderr)
    if extra:
        print(f'OMITS_CLAUDE_MD names agents not defined with omitClaudeMd: {", ".join(extra)}', file=sys.stderr)
    print('Update OMITS_CLAUDE_MD in hooks/mods/session-rules.ts.', file=sys.stderr)
    return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
