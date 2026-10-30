#!/usr/bin/env python3
import json
import os
import subprocess
import sys

WRITES = {
    "issue": {"create", "edit", "comment", "close", "reopen", "delete", "lock", "unlock", "pin", "unpin", "transfer", "develop"},
    "pr": {"create", "edit", "comment", "close", "reopen", "merge", "review", "ready", "lock", "unlock", "update-branch", "checkout"},
    "repo": {"create", "edit", "delete", "fork", "sync", "rename", "archive", "unarchive", "set-default", "deploy-key"},
    "label": {"create", "edit", "delete", "clone"},
    "release": {"create", "edit", "delete", "upload", "delete-asset"},
    "project": {"create", "edit", "delete", "close", "copy", "field-create", "field-delete", "item-add", "item-archive", "item-create", "item-delete", "item-edit", "link", "unlink", "mark-template"},
}
WRITE_GROUPS = {"gist", "secret", "variable", "workflow", "run", "cache", "ruleset", "auth", "config", "alias", "extension", "codespace", "ssh-key", "gpg-key"}
VALUE_FLAGS = {"-R", "--repo", "--json", "--jq", "-q", "--limit", "-L", "--state", "-s", "--label", "-l", "-X", "--method", "-H", "--header"}
FIELD_FLAGS = {"-f", "-F", "--field", "--raw-field", "--input"}


class Refused(Exception):
    pass


def log(entry):
    with open(os.environ["EVAL_GH_LOG"], "a") as f:
        f.write(json.dumps(entry) + "\n")


def parse(argv):
    positional, flags = [], {}
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--":
            flags["--"] = argv[i + 1:]
            break
        if arg in FIELD_FLAGS:
            flags.setdefault("fields", []).append(argv[i + 1] if i + 1 < len(argv) else "")
            i += 2
            continue
        if "=" in arg and arg.split("=", 1)[0] in VALUE_FLAGS | FIELD_FLAGS:
            name, value = arg.split("=", 1)
            if name in FIELD_FLAGS:
                flags.setdefault("fields", []).append(value)
            else:
                flags[name] = value
        elif arg in VALUE_FLAGS:
            flags[arg] = argv[i + 1] if i + 1 < len(argv) else ""
            i += 1
        elif arg.startswith("-"):
            flags[arg] = True
        else:
            positional.append(arg)
        i += 1
    return positional, flags


def flag(flags, *names, default=None):
    return next((flags[n] for n in names if n in flags), default)


def project(record, fields):
    if not fields:
        return record
    return {name: record.get(name) for name in fields.split(",")}


def emit(value, flags):
    fields = flag(flags, "--json")
    if isinstance(value, list):
        value = [project(v, fields) for v in value]
    elif isinstance(value, dict):
        value = project(value, fields)
    text = json.dumps(value)
    jq = flag(flags, "--jq", "-q")
    if jq:
        done = subprocess.run(["jq", "-r", jq], input=text, capture_output=True, text=True)
        sys.stdout.write(done.stdout)
        sys.stderr.write(done.stderr)
        return done.returncode
    print(text)
    return 0


def by_state(records, state):
    state = (state or "open").lower()
    return records if state == "all" else [r for r in records if r.get("state", "OPEN").lower() == state]


def find(records, number, kind):
    for record in records:
        if str(record["number"]) == str(number).lstrip("#"):
            return record
    raise LookupError(f"no {kind} #{number} in this replay")


def issue_text(issue, with_comments):
    lines = [f"title:\t{issue['title']}", f"state:\t{issue.get('state', 'OPEN')}", f"number:\t{issue['number']}", "--", issue.get("body") or ""]
    if with_comments:
        for c in issue.get("comments", []):
            lines += ["--", f"author:\t{c['author']['login']}", c["body"]]
    return "\n".join(lines) + "\n"


def api(path, flags, repo, data):
    method = str(flag(flags, "-X", "--method", default="GET")).upper()
    if method != "GET" or flags.get("fields"):
        raise Refused(f"gh api {method} with fields")
    parts = path.strip("/").split("?")[0].split("/")
    if parts[:3] != ["repos", *repo.split("/")] or len(parts) < 5 or parts[3] != "issues":
        raise LookupError(f"gh api {path} is not served in this replay")
    issue = find(data.get("github", {}).get("issues", []), parts[4], "issue")
    if len(parts) == 5:
        return emit({"number": issue["number"], "title": issue["title"], "body": issue.get("body"), "state": issue.get("state", "OPEN").lower(), "labels": issue.get("labels", [])}, flags)
    if parts[5:] == ["comments"]:
        return emit([{"body": c["body"], "user": {"login": c["author"]["login"]}, "created_at": c["createdAt"]} for c in issue.get("comments", [])], flags)
    raise LookupError(f"gh api {path} is not served in this replay")


def serve(argv, data):
    positional, flags = parse(argv)
    group, verb = (positional + ["", ""])[:2]
    repo = data["repo"]
    if group in WRITE_GROUPS or verb in WRITES.get(group, set()):
        raise Refused(f"gh {group} {verb}")
    asked = flag(flags, "-R", "--repo")
    if asked and asked.lower() != repo.lower():
        raise LookupError(f"this replay serves {repo} only, not {asked}")
    github = data.get("github", {})
    if (group, verb) == ("issue", "list"):
        issues = by_state(github.get("issues", []), flag(flags, "--state", "-s"))
        return emit(issues[: int(flag(flags, "--limit", "-L", default=30))], flags)
    if (group, verb) == ("issue", "view"):
        issue = find(github.get("issues", []), positional[2], "issue")
        if "--json" in flags:
            return emit(issue, flags)
        sys.stdout.write(issue_text(issue, "--comments" in flags or "-c" in flags))
        return 0
    if (group, verb) == ("pr", "list"):
        pulls = by_state(github.get("pulls", []), flag(flags, "--state", "-s"))
        return emit(pulls[: int(flag(flags, "--limit", "-L", default=30))], flags)
    if (group, verb) == ("pr", "view"):
        return emit(find(github.get("pulls", []), positional[2] if len(positional) > 2 else data.get("pr", ""), "pull request"), flags)
    if (group, verb) == ("pr", "diff"):
        diff = ["git", "-C", os.environ["EVAL_CHECKOUT"], "diff", f"{os.environ['EVAL_DIFF_BASE']}...{os.environ['EVAL_DIFF_HEAD']}"]
        return subprocess.run(diff + (["--name-only"] if "--name-only" in flags else [])).returncode
    if (group, verb) == ("repo", "clone"):
        if positional[2].lower() != repo.lower():
            raise LookupError(f"this replay serves {repo} only")
        target = positional[3] if len(positional) > 3 else repo.split("/")[1]
        clone = ["git", "clone", "--quiet", *flags.get("--", []), "file://" + os.environ["EVAL_CLONE_FROM"], target]
        return subprocess.run(clone).returncode
    if group == "api" and verb:
        return api(verb, flags, repo, data)
    raise LookupError(f"gh {group} {verb} is not served in this replay")


def main(argv):
    with open(os.environ["EVAL_GH_DATA"]) as f:
        data = json.load(f)
    try:
        code = serve(argv, data)
    except Refused as refused:
        log({"argv": argv, "outcome": "refused"})
        sys.stderr.write(f"{refused} is refused: this is a read-only replay, and no GitHub write is possible here.\n")
        return 1
    except (LookupError, IndexError, ValueError) as missing:
        log({"argv": argv, "outcome": "unsupported"})
        sys.stderr.write(f"{missing}\n")
        return 1
    log({"argv": argv, "outcome": "served", "exit": code})
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
