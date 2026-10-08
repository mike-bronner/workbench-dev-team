#!/usr/bin/env python3
"""comms-check: hold one piece of outward prose to the mechanical part of the
comms-style skill (skills/comms-style). Reads markdown on stdin, prints one
finding per line, and exits 1 when there is any.

bin/test-dispatch-tick.sh runs it on every escalation comment the tick posts.
That comment goes to The Index over curl, so the Claude-side outbound prose
guard never sees it, and this check stands in for it.

What it checks, in prose only (fenced code, inline code and HTML comments are
quoted or hidden text, and are left out first):
  em-dash       no em dash (the Clear standard's rule 8)
  semicolon     no semicolon: two sentences instead (comms-style, Sentences)
  pointer       no file path, the Self-contained rule: the reader cannot open
                a file on the machine that wrote the comment
  contraction   no contraction: full sentences, nothing omitted
  long          no sentence over 25 words (comms-style's narrative limit)
  paragraph     no paragraph over six sentences
  wording       none of the hedges and marketing words comms-style names
"""

import re
import sys

FENCED = re.compile(r"^[ \t]*(```|~~~).*?^[ \t]*\1[ \t]*$", re.S | re.M)
HTML_COMMENT = re.compile(r"<!--.*?-->", re.S)
INLINE_CODE = re.compile(r"`[^`\n]*`")
URL = re.compile(r"\bhttps?://\S+", re.I)
POINTER = re.compile(r"(?:~/|\.{1,2}/)\S+|(?<![\w])[\w.-]+/[\w.-]+/?[\w.-]*|\b[\w-]+\.(?:md|sh|json|py|ts|log)\b")
CONTRACTION = re.compile(r"\b\w+n't\b|\b\w+'(?:re|ve|ll|m|d)\b|\b(?:it|that|there|here|what|who|let)'s\b", re.I)
WORDING = re.compile(
    r"\b(?:it is important to note|please note|potentially|seamless(?:ly)?|robust|cutting-edge|"
    r"leverage|reach out|circle back|spin up|e\.g\.|i\.e\.|etc\.)",
    re.I,
)
SENTENCE_END = re.compile(r"(?<=[.!?])\s+(?=[A-Z0-9`\"'(])")


def prose(text):
    text = FENCED.sub("", text)
    text = HTML_COMMENT.sub("", text)
    text = INLINE_CODE.sub("code", text)
    return URL.sub("link", text)


def findings(text):
    out = []
    body = prose(text)
    if "—" in body:
        out.append("em-dash: an em dash in prose")
    if ";" in body:
        out.append("semicolon: a semicolon in prose")
    for match in POINTER.finditer(body):
        out.append(f"pointer: a file path in prose: {match.group(0)}")
    for match in CONTRACTION.finditer(body):
        out.append(f"contraction: {match.group(0)}")
    for match in WORDING.finditer(body):
        out.append(f"wording: {match.group(0)}")
    for paragraph in re.split(r"\n\s*\n", body):
        flat = " ".join(paragraph.split())
        if not flat:
            continue
        sentences = [s for s in SENTENCE_END.split(flat) if s.strip()]
        if len(sentences) > 6:
            out.append(f"paragraph: {len(sentences)} sentences: {flat[:60]}")
        for sentence in sentences:
            words = len(sentence.split())
            if words > 25:
                out.append(f"long: {words} words: {sentence[:60]}")
    return out


if __name__ == "__main__":
    found = findings(sys.stdin.read())
    for line in found:
        print(line)
    sys.exit(1 if found else 0)
