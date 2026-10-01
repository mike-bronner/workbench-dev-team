#!/usr/bin/env python3
"""The read allowlist that commit-guard.sh and local-review-guard.sh share.

A command line is an allowlisted read when every segment is a reader listed in
READERS, using only the options listed for it, and nothing else. Only then may a
guard judge the line differently from main (621f3fb): the commit guard lets a
read that names a guarded word pass, and the local-review guard reads quoted
text as data. Every other line gets main's verdict.

This is an allowlist on purpose. Three rounds of a denylist (runners, flags that
run a program) each regressed, because every unlisted spelling passed. Here an
unlisted reader, option, abbreviation, short-option letter, quoted option word,
file redirect, or unquoted wildcard before a literal `--` makes the line fall
back to main. A wildcard is any character bash or zsh can glob on: `*`, `?`,
`[`, and under zsh's extendedglob `^`, `#`, and a `~` that does not lead the
word. The shell expands one after this check, so a file named like an option
would become one the parser never saw. So `git log ^main` falls back too. A read that is
refused costs a minor defect. A command that runs silently is the failure that
matters.

Options that run a program, write a file, or read config that names a program
are left off the lists: git -c, rg --pre and -z, git grep -O and
--open-files-in-pager, --ext-diff, --output, --textconv, gh --web, tail -f, and
pagers. One listed option can still run one, so its value is checked: a
--format or --pretty value with a %G placeholder makes git verify a signature
with gpg (or gpg.program, gpg.ssh.program, gpgsm), and falls back to main.

Recorded limits, which main shares, so they are not regressions. Config, files,
and environment already in place can make a listed reader run a program. These
are examples, not a complete list: diff.external on a plain `git diff`;
core.fsmonitor on `git status` or `git diff`; a textconv driver (.gitattributes
plus diff.<driver>.textconv) on `git log -p`, `git show`, or `git diff`; the
post-index-change hook that an index refresh in `git status` can run;
log.showSignature=true, which makes a plain `git log` or `git show` run gpg;
format.pretty, or a pretty.<name> alias holding %G, which `--format=<name>`
reaches past the value check; and RIPGREP_CONFIG_PATH, whose file can add
`--pre` to a listed rg. Main allowed every one of those lines.

Run as a script, it reads one command line on stdin and exits 0 when it is an
allowlisted read, 1 otherwise.
"""
import re
import sys


def spec(flags="", values="", long="", long_values="", digits=False):
    """One reader's options: boolean short letters, short letters that take a
    value, boolean long options, long options that take a value, and whether a
    bare count such as -5 is allowed."""
    return (set(flags), set(values), set(long.split()), set(long_values.split()), digits)


GREP_LONG = ("--recursive --line-number --ignore-case --files-with-matches --files-without-match "
             "--count --word-regexp --invert-match --extended-regexp --fixed-strings "
             "--only-matching --no-filename --with-filename --quiet --silent --line-regexp "
             "--no-messages")
GH_VALUES = "--repo --limit --json --jq --state --author --label --owner --sort --order --base --head --search"

READERS = {
    "grep": spec("rRniIlLcwvEFoshHqxz", "eABCm", GREP_LONG,
                 "--include --exclude --exclude-dir --regexp --max-count --after-context "
                 "--before-context --context --color --colour"),
    "rg": spec("niIlcwvFoHNSsuULPx", "egtTABCmM",
               "--hidden --no-ignore --files --files-with-matches --count --fixed-strings "
               "--line-number --ignore-case --word-regexp --invert-match --no-heading --heading "
               "--with-filename --no-filename --no-line-number --smart-case --case-sensitive "
               "--multiline --json --only-matching --follow --vimgrep --stats --trim",
               "--glob --iglob --type --type-not --regexp --max-count --after-context "
               "--before-context --context --max-depth --color --sort"),
    "cat": spec("nb"),
    "head": spec("", "nc", digits=True),
    "tail": spec("", "nc", digits=True),
    "wc": spec("lwcm"),
    "ls": spec("laA1RhtrdFSG"),
    "echo": spec("neE"),
    "printf": spec(),
    "jq": spec("rcesnMSj", "", "--raw-output --compact-output --exit-status --slurp "
               "--null-input --monochrome-output --sort-keys --join-output"),
    "cd": spec(),
    "git log": spec("piEF", "nSG",
                    "--oneline --all --stat --name-only --name-status --patch --follow --reverse "
                    "--no-merges --merges --first-parent --graph --regexp-ignore-case "
                    "--fixed-strings --extended-regexp --all-match --invert-grep --abbrev-commit "
                    "--shortstat --numstat --no-patch --branches --tags --remotes --summary "
                    "--no-color --no-decorate --decorate --topo-order --date-order",
                    "--format --pretty --grep --author --committer --since --until --after "
                    "--before --date --max-count --skip --diff-filter", digits=True),
    "git show": spec("ps", "",
                     "--stat --name-only --name-status --oneline --no-patch --patch "
                     "--abbrev-commit --numstat --shortstat --summary --no-color",
                     "--format --pretty --date --diff-filter"),
    "git diff": spec("wbRM", "U",
                     "--stat --name-only --name-status --cached --staged --numstat --shortstat "
                     "--check --no-color --ignore-all-space --ignore-space-change --find-renames "
                     "--summary --exit-code --quiet --no-renames --no-ext-diff",
                     "--unified --diff-filter"),
    "git status": spec("sb", "", "--short --porcelain --branch --long --ignored"),
    "git grep": spec("nilcwvEFhHI", "eABCm",
                     "--count --name-only --files-with-matches --untracked --cached "
                     "--ignore-case --line-number --word-regexp --invert-match "
                     "--extended-regexp --fixed-strings --full-name",
                     "--max-depth --max-count --after-context --before-context --context"),
    "git ls-files": spec("comd", "", "--others --exclude-standard --cached --modified --deleted "
                         "--full-name"),
    "git rev-parse": spec("q", "", "--show-toplevel --abbrev-ref --verify --git-dir "
                          "--is-inside-work-tree --show-prefix --symbolic-full-name", "--short"),
    "gh search prs": spec("", "RL", "", GH_VALUES),
    "gh search issues": spec("", "RL", "", GH_VALUES),
    "gh search code": spec("", "RL", "", GH_VALUES),
    "gh pr view": spec("", "Rq", "--comments", GH_VALUES),
    "gh pr list": spec("", "RLq", "", GH_VALUES),
    "gh pr diff": spec("", "R", "--name-only", GH_VALUES),
    "gh pr checks": spec("", "R", "", GH_VALUES),
    "gh issue view": spec("", "Rq", "--comments", GH_VALUES),
    "gh issue list": spec("", "RLq", "", GH_VALUES),
}

# The only redirects allowed: to /dev/null, or duplicating a descriptor.
REDIRECT_WORD = re.compile(r"(?:[0-9]?>&[0-9]|[0-9]?>/dev/null|&>/dev/null)")
REDIRECT_ALONE = re.compile(r"(?:[0-9]?>|&>)")


def words_of(command: str):
    """The line as segments of words, each word `(text, raw, quoted)`, and its
    masked copy, or None for anything this tokenizer does not model."""
    segments, words, text, raw = [], [], [], []
    masked, quoted, globbed, quote, i = [], False, False, "", 0

    def end_word():
        nonlocal quoted
        nonlocal globbed
        if raw:
            words.append(("".join(text), "".join(raw), quoted, globbed))
        text.clear()
        raw.clear()
        quoted = globbed = False

    while i < len(command):
        ch = command[i]
        if quote == "'":
            if ch == "'":
                quote = ""
                raw.append(ch)
                masked.append(ch)
            else:
                text.append(ch)
                raw.append(ch)
                masked.append("_")
        elif quote == '"':
            if ch == '"':
                quote = ""
                raw.append(ch)
                masked.append(ch)
            elif ch in "$`":
                return None
            elif ch == "\\" and command[i + 1:i + 2] in ("$", "`", '"', "\\"):
                text.append(command[i + 1])
                raw.append(command[i:i + 2])
                masked.append("__")
                i += 1
            elif ch == "\\" and command[i + 1:i + 2] == "\n":
                return None
            else:
                text.append(ch)
                raw.append(ch)
                masked.append("_")
        elif ch in "'\"":
            quote, quoted = ch, True
            raw.append(ch)
            masked.append(ch)
        elif ch in " \t":  # the shell splits words on space and tab only
            end_word()
            masked.append(ch)
        elif ch in ";\n" or (ch == "|" and command[i + 1:i + 2] != "&") or (
                ch == "&" and command[i + 1:i + 2] == "&"):
            end_word()
            segments.append(words)
            words = []
            double = command[i + 1:i + 2] == ch and ch in "|&"
            masked.append(command[i:i + 2] if double else ch)
            i += 1 if double else 0
        elif ch == "&" and (raw[-1:] == [">"] or command[i + 1:i + 2] == ">"):
            text.append(ch)
            raw.append(ch)
            masked.append(ch)
        elif ch in "$`\\{}()&|":
            return None
        elif ch in "#=" and not raw:
            return None
        elif ch == "[" and raw[-1:] == ["~"]:
            return None  # zsh ~[...] runs a named-directory function
        else:
            # An unquoted * ? or [ is a wildcard the shell expands after this
            # check, so a file named like an option could become one. Under
            # zsh's extendedglob so are ^ (every file but), # (repeat), and a ~
            # that does not lead the word (exclude). A leading ~ is the home
            # directory, and a word-initial # is refused above.
            globbed = globbed or ch in "*?[^" or (ch in "#~" and bool(raw))
            text.append(ch)
            raw.append(ch)
            masked.append(ch)
        i += 1
    if quote:
        return None
    end_word()
    segments.append(words)
    return segments, "".join(masked)


def options_allowed(reader, words) -> bool:
    """True when every option word is listed for `reader`."""
    flags, values, long, long_values, digits = READERS[reader]
    i, operands_only = 0, False
    while i < len(words):
        text, raw, quoted, globbed = words[i]
        i += 1
        if operands_only:
            continue  # a wildcard after a literal -- expands to operands only
        if globbed:
            return False  # a wildcard could expand to an option word
        if not text.startswith("-") or text == "-":
            continue
        if not raw.startswith("-"):
            return False  # a quoted option word
        if text == "--":
            operands_only = True
        elif text.startswith("--"):
            name, eq, value = text.partition("=")
            if quoted and "=" not in raw.split("'")[0].split('"')[0]:
                return False  # a quote inside the option's name
            if name in long_values:
                if not eq:
                    if i >= len(words) or words[i][0].startswith("-") or words[i][3]:
                        return False
                    value = words[i][0]
                    i += 1
                # A %G placeholder makes git verify a signature with gpg.
                if name in ("--format", "--pretty") and "%G" in value:
                    return False
            elif not (name in long and not eq):
                return False
        elif digits and re.fullmatch(r"-[0-9]+", text):
            continue
        else:
            if quoted:
                return False
            for j, letter in enumerate(text[1:], 1):
                if letter in values:
                    if j == len(text) - 1:
                        if i >= len(words) or words[i][0].startswith("-") or words[i][3]:
                            return False
                        i += 1
                    break
                if letter not in flags:
                    return False
    return True


def masked_read(command: str):
    """The masked copy of an allowlisted read line, or None."""
    parsed = words_of(command)
    if parsed is None:
        return None
    segments, masked = parsed
    for words in segments:
        kept, skip = [], False
        for text, raw, quoted, globbed in words:
            if skip:
                skip = False
                if text != "/dev/null" or quoted:
                    return None
                continue
            if not quoted and REDIRECT_WORD.fullmatch(raw):
                continue
            if not quoted and REDIRECT_ALONE.fullmatch(raw):
                skip = True
                continue
            if not quoted and ("<" in raw or ">" in raw):
                return None
            kept.append((text, raw, quoted, globbed))
        if skip:
            return None
        if not kept:
            continue
        # The program name, git's -C value, and the subcommand words must be
        # plain words: no quote, and no wildcard.
        plain = lambda word: not word[2] and not word[3]  # noqa: E731
        if not plain(kept[0]):
            return None
        name, rest = kept[0][0], kept[1:]
        if name == "git":
            if rest[:1] and rest[0][0] == "-C" and len(rest) > 1 and not rest[1][0].startswith("-") \
                    and not rest[1][3]:
                rest = rest[2:]
            elif rest[:1] and rest[0][0] == "--no-pager":
                rest = rest[1:]
            name, rest = (f"git {rest[0][0]}", rest[1:]) if rest and plain(rest[0]) else ("", rest)
        elif name == "gh":
            if not all(plain(w) for w in rest[:2]):
                return None
            name, rest = " ".join(["gh"] + [w[0] for w in rest[:2]]), rest[2:]
        if name not in READERS or not options_allowed(name, rest):
            return None
    return masked


if __name__ == "__main__":
    sys.exit(0 if masked_read(sys.stdin.read().rstrip("\n")) is not None else 1)
