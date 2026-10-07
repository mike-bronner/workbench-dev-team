// GENERATED from workbench-core 6131575: every prompt case of
// hooks/test-agent-dispatch-gate.sh, with the verdict the bash gate gave it on a
// main-session dispatch (deny, hint, or silent) and the answer core's
// $.workbench.briefCheck gives the same prompt. Core retires the bash gate once
// this module reaches parity, so this file is the record of what it decided.
// tests/gate-parity.test.ts holds the module to it. Do not edit by hand.

export type GateCase = {
  name: string
  prompt: string
  verdict: 'deny' | 'hint' | 'silent'
  check: { isComplete: boolean; missing: string[]; shape: 'brief' | 'item-id' | 'repo-sweep' | 'blank' }
}

export const GATE_CASES: GateCase[] = [
  {
    "name": "a free-form paragraph",
    "prompt": "Go read the config parser and fix whatever looks wrong in it.",
    "verdict": "deny",
    "check": {
      "isComplete": false,
      "missing": [
        "Workdir:",
        "Goal:",
        "Context:",
        "Constraints:",
        "Acceptance:",
        "Done when:"
      ],
      "shape": "brief"
    }
  },
  {
    "name": "an empty-ish prompt of dots",
    "prompt": "...",
    "verdict": "deny",
    "check": {
      "isComplete": false,
      "missing": [
        "Workdir:",
        "Goal:",
        "Context:",
        "Constraints:",
        "Acceptance:",
        "Done when:"
      ],
      "shape": "brief"
    }
  },
  {
    "name": "slot headers only in prose",
    "prompt": "Mention the repo and the goal.",
    "verdict": "deny",
    "check": {
      "isComplete": false,
      "missing": [
        "Workdir:",
        "Goal:",
        "Context:",
        "Constraints:",
        "Acceptance:",
        "Done when:"
      ],
      "shape": "brief"
    }
  },
  {
    "name": "missing 'Workdir:' is denied",
    "prompt": "Goal: Make the credential guard stop matching .env by substring.\nContext: The guard matches .env anywhere in the raw command text, so any command\nmentioning a path containing .envrc trips it. Three false positives in one day.\nConstraints: none\nAcceptance:\n- AC1: A path containing .envrc passes the guard.\n- AC2: A read of .env is still refused.\nDone when: The guard rejects .envrc and still catches .env, with a test per case.",
    "verdict": "deny",
    "check": {
      "isComplete": false,
      "missing": [
        "Workdir:"
      ],
      "shape": "brief"
    }
  },
  {
    "name": "missing 'Goal:' is denied",
    "prompt": "Workdir: /Users/mike/Developer/workbench-core\nContext: The guard matches .env anywhere in the raw command text, so any command\nmentioning a path containing .envrc trips it. Three false positives in one day.\nConstraints: none\nAcceptance:\n- AC1: A path containing .envrc passes the guard.\n- AC2: A read of .env is still refused.\nDone when: The guard rejects .envrc and still catches .env, with a test per case.",
    "verdict": "deny",
    "check": {
      "isComplete": false,
      "missing": [
        "Goal:"
      ],
      "shape": "brief"
    }
  },
  {
    "name": "missing 'Context:' is denied",
    "prompt": "Workdir: /Users/mike/Developer/workbench-core\nGoal: Make the credential guard stop matching .env by substring.\nmentioning a path containing .envrc trips it. Three false positives in one day.\nConstraints: none\nAcceptance:\n- AC1: A path containing .envrc passes the guard.\n- AC2: A read of .env is still refused.\nDone when: The guard rejects .envrc and still catches .env, with a test per case.",
    "verdict": "deny",
    "check": {
      "isComplete": false,
      "missing": [
        "Context:"
      ],
      "shape": "brief"
    }
  },
  {
    "name": "missing 'Constraints:' is denied",
    "prompt": "Workdir: /Users/mike/Developer/workbench-core\nGoal: Make the credential guard stop matching .env by substring.\nContext: The guard matches .env anywhere in the raw command text, so any command\nmentioning a path containing .envrc trips it. Three false positives in one day.\nAcceptance:\n- AC1: A path containing .envrc passes the guard.\n- AC2: A read of .env is still refused.\nDone when: The guard rejects .envrc and still catches .env, with a test per case.",
    "verdict": "deny",
    "check": {
      "isComplete": false,
      "missing": [
        "Constraints:"
      ],
      "shape": "brief"
    }
  },
  {
    "name": "missing 'Acceptance:' is denied",
    "prompt": "Workdir: /Users/mike/Developer/workbench-core\nGoal: Make the credential guard stop matching .env by substring.\nContext: The guard matches .env anywhere in the raw command text, so any command\nmentioning a path containing .envrc trips it. Three false positives in one day.\nConstraints: none\n- AC1: A path containing .envrc passes the guard.\n- AC2: A read of .env is still refused.\nDone when: The guard rejects .envrc and still catches .env, with a test per case.",
    "verdict": "deny",
    "check": {
      "isComplete": false,
      "missing": [
        "Acceptance:"
      ],
      "shape": "brief"
    }
  },
  {
    "name": "missing 'Done when:' is denied",
    "prompt": "Workdir: /Users/mike/Developer/workbench-core\nGoal: Make the credential guard stop matching .env by substring.\nContext: The guard matches .env anywhere in the raw command text, so any command\nmentioning a path containing .envrc trips it. Three false positives in one day.\nConstraints: none\nAcceptance:\n- AC1: A path containing .envrc passes the guard.\n- AC2: A read of .env is still refused.",
    "verdict": "deny",
    "check": {
      "isComplete": false,
      "missing": [
        "Done when:"
      ],
      "shape": "brief"
    }
  },
  {
    "name": "a brief using the old Repo: name is refused",
    "prompt": "Repo: /Users/mike/Developer/workbench-core\nGoal: Make the credential guard stop matching .env by substring.\nContext: The guard matches .env anywhere in the raw command text, so any command\nmentioning a path containing .envrc trips it. Three false positives in one day.\nConstraints: none\nAcceptance:\n- AC1: A path containing .envrc passes the guard.\n- AC2: A read of .env is still refused.\nDone when: The guard rejects .envrc and still catches .env, with a test per case.",
    "verdict": "deny",
    "check": {
      "isComplete": false,
      "missing": [
        "Workdir:"
      ],
      "shape": "brief"
    }
  },
  {
    "name": "all six slots, no prescriptive markers",
    "prompt": "Workdir: /Users/mike/Developer/workbench-core\nGoal: Make the credential guard stop matching .env by substring.\nContext: The guard matches .env anywhere in the raw command text, so any command\nmentioning a path containing .envrc trips it. Three false positives in one day.\nConstraints: none\nAcceptance:\n- AC1: A path containing .envrc passes the guard.\n- AC2: A read of .env is still refused.\nDone when: The guard rejects .envrc and still catches .env, with a test per case.",
    "verdict": "silent",
    "check": {
      "isComplete": true,
      "missing": [],
      "shape": "brief"
    }
  },
  {
    "name": "slots in a different order still pass",
    "prompt": "Done when: The guard rejects .envrc and still catches .env, with a test per case.\n- AC2: A read of .env is still refused.\n- AC1: A path containing .envrc passes the guard.\nAcceptance:\nConstraints: none\nmentioning a path containing .envrc trips it. Three false positives in one day.\nContext: The guard matches .env anywhere in the raw command text, so any command\nGoal: Make the credential guard stop matching .env by substring.\nWorkdir: /Users/mike/Developer/workbench-core",
    "verdict": "silent",
    "check": {
      "isComplete": true,
      "missing": [],
      "shape": "brief"
    }
  },
  {
    "name": "lower-case headers still pass",
    "prompt": "workdir: /users/mike/developer/workbench-core\ngoal: make the credential guard stop matching .env by substring.\ncontext: the guard matches .env anywhere in the raw command text, so any command\nmentioning a path containing .envrc trips it. three false positives in one day.\nconstraints: none\nacceptance:\n- ac1: a path containing .envrc passes the guard.\n- ac2: a read of .env is still refused.\ndone when: the guard rejects .envrc and still catches .env, with a test per case.",
    "verdict": "silent",
    "check": {
      "isComplete": true,
      "missing": [],
      "shape": "brief"
    }
  },
  {
    "name": "'Done  when:' with extra spacing passes",
    "prompt": "Workdir: /Users/mike/Developer/workbench-core\nGoal: Make the credential guard stop matching .env by substring.\nContext: The guard matches .env anywhere in the raw command text, so any command\nmentioning a path containing .envrc trips it. Three false positives in one day.\nConstraints: none\nAcceptance:\n- AC1: A path containing .envrc passes the guard.\n- AC2: A read of .env is still refused.\nDone   when: The guard rejects .envrc and still catches .env, with a test per case.",
    "verdict": "silent",
    "check": {
      "isComplete": true,
      "missing": [],
      "shape": "brief"
    }
  },
  {
    "name": "indented headers pass",
    "prompt": "   Workdir: /Users/mike/Developer/workbench-core\n   Goal: Make the credential guard stop matching .env by substring.\n   Context: The guard matches .env anywhere in the raw command text, so any command\n   mentioning a path containing .envrc trips it. Three false positives in one day.\n   Constraints: none\n   Acceptance:\n   - AC1: A path containing .envrc passes the guard.\n   - AC2: A read of .env is still refused.\n   Done when: The guard rejects .envrc and still catches .env, with a test per case.",
    "verdict": "silent",
    "check": {
      "isComplete": true,
      "missing": [],
      "shape": "brief"
    }
  },
  {
    "name": "tab-separated 'Done<TAB>when:' passes",
    "prompt": "Workdir: /Users/mike/Developer/workbench-core\nGoal: Make the credential guard stop matching .env by substring.\nContext: The guard matches .env anywhere in the raw command text, so any command\nmentioning a path containing .envrc trips it. Three false positives in one day.\nConstraints: none\nAcceptance:\n- AC1: A path containing .envrc passes the guard.\n- AC2: A read of .env is still refused.\nDone\twhen: The guard rejects .envrc and still catches .env, with a test per case.",
    "verdict": "silent",
    "check": {
      "isComplete": true,
      "missing": [],
      "shape": "brief"
    }
  },
  {
    "name": "'Done<NBSP>when:' does not satisfy the slot",
    "prompt": "Workdir: /Users/mike/Developer/workbench-core\nGoal: Make the credential guard stop matching .env by substring.\nContext: The guard matches .env anywhere in the raw command text, so any command\nmentioning a path containing .envrc trips it. Three false positives in one day.\nConstraints: none\nAcceptance:\n- AC1: A path containing .envrc passes the guard.\n- AC2: A read of .env is still refused.\nDone when: The guard rejects .envrc and still catches .env, with a test per case.",
    "verdict": "deny",
    "check": {
      "isComplete": false,
      "missing": [
        "Done when:"
      ],
      "shape": "brief"
    }
  },
  {
    "name": "'Done<IDSP>when:' does not satisfy the slot",
    "prompt": "Workdir: /Users/mike/Developer/workbench-core\nGoal: Make the credential guard stop matching .env by substring.\nContext: The guard matches .env anywhere in the raw command text, so any command\nmentioning a path containing .envrc trips it. Three false positives in one day.\nConstraints: none\nAcceptance:\n- AC1: A path containing .envrc passes the guard.\n- AC2: A read of .env is still refused.\nDone　when: The guard rejects .envrc and still catches .env, with a test per case.",
    "verdict": "deny",
    "check": {
      "isComplete": false,
      "missing": [
        "Done when:"
      ],
      "shape": "brief"
    }
  },
  {
    "name": "a slot header indented with NBSP is still a slot",
    "prompt": " Workdir: /Users/mike/Developer/workbench-core\n Goal: Make the credential guard stop matching .env by substring.\n Context: The guard matches .env anywhere in the raw command text, so any command\n mentioning a path containing .envrc trips it. Three false positives in one day.\n Constraints: none\n Acceptance:\n - AC1: A path containing .envrc passes the guard.\n - AC2: A read of .env is still refused.\n Done when: The guard rejects .envrc and still catches .env, with a test per case.",
    "verdict": "deny",
    "check": {
      "isComplete": false,
      "missing": [
        "Workdir:",
        "Goal:",
        "Context:",
        "Constraints:",
        "Acceptance:",
        "Done when:"
      ],
      "shape": "brief"
    }
  },
  {
    "name": "a prompt of nothing but NBSPs is judged, not skipped",
    "prompt": "   ",
    "verdict": "deny",
    "check": {
      "isComplete": false,
      "missing": [
        "Workdir:",
        "Goal:",
        "Context:",
        "Constraints:",
        "Acceptance:",
        "Done when:"
      ],
      "shape": "brief"
    }
  },
  {
    "name": "a prompt of nothing but ideographic spaces is judged",
    "prompt": "　　",
    "verdict": "deny",
    "check": {
      "isComplete": false,
      "missing": [
        "Workdir:",
        "Goal:",
        "Context:",
        "Constraints:",
        "Acceptance:",
        "Done when:"
      ],
      "shape": "brief"
    }
  },
  {
    "name": "an all-ASCII-whitespace prompt is still skipped",
    "prompt": "  \t\n  ",
    "verdict": "silent",
    "check": {
      "isComplete": true,
      "missing": [],
      "shape": "blank"
    }
  },
  {
    "name": "'Item ID:<NBSP>12' is not the exempt shape",
    "prompt": "Item ID: 12",
    "verdict": "deny",
    "check": {
      "isComplete": false,
      "missing": [
        "Workdir:",
        "Goal:",
        "Context:",
        "Constraints:",
        "Acceptance:",
        "Done when:"
      ],
      "shape": "brief"
    }
  },
  {
    "name": "'Item ID:<IDSP>12' is not the exempt shape",
    "prompt": "Item ID:　12",
    "verdict": "deny",
    "check": {
      "isComplete": false,
      "missing": [
        "Workdir:",
        "Goal:",
        "Context:",
        "Constraints:",
        "Acceptance:",
        "Done when:"
      ],
      "shape": "brief"
    }
  },
  {
    "name": "trailing NBSP breaks the exempt shape",
    "prompt": "Repo sweep: owner/repo  ",
    "verdict": "deny",
    "check": {
      "isComplete": false,
      "missing": [
        "Workdir:",
        "Goal:",
        "Context:",
        "Constraints:",
        "Acceptance:",
        "Done when:"
      ],
      "shape": "brief"
    }
  },
  {
    "name": "trailing IDSP breaks the exempt shape",
    "prompt": "Repo sweep: owner/repo 　",
    "verdict": "deny",
    "check": {
      "isComplete": false,
      "missing": [
        "Workdir:",
        "Goal:",
        "Context:",
        "Constraints:",
        "Acceptance:",
        "Done when:"
      ],
      "shape": "brief"
    }
  },
  {
    "name": "a Workdir: naming a branch passes",
    "prompt": "Workdir: /Users/mike/Developer/workbench-core (branch: fix/env-prefix, to be created off main)\nGoal: Make the credential guard stop matching .env by substring.\nContext: The guard matches .env anywhere in the raw command text, so any command\nmentioning a path containing .envrc trips it. Three false positives in one day.\nConstraints: none\nAcceptance:\n- AC1: A path containing .envrc passes the guard.\n- AC2: A read of .env is still refused.\nDone when: The guard rejects .envrc and still catches .env, with a test per case.",
    "verdict": "silent",
    "check": {
      "isComplete": true,
      "missing": [],
      "shape": "brief"
    }
  },
  {
    "name": "a Workdir: naming a worktree passes",
    "prompt": "Workdir: /Users/mike/Developer/workbench-core-wt/env-prefix (worktree off main)\nGoal: Make the credential guard stop matching .env by substring.\nContext: The guard matches .env anywhere in the raw command text, so any command\nmentioning a path containing .envrc trips it. Three false positives in one day.\nConstraints: none\nAcceptance:\n- AC1: A path containing .envrc passes the guard.\n- AC2: A read of .env is still refused.\nDone when: The guard rejects .envrc and still catches .env, with a test per case.",
    "verdict": "silent",
    "check": {
      "isComplete": true,
      "missing": [],
      "shape": "brief"
    }
  },
  {
    "name": "read-only investigation brief",
    "prompt": "Workdir: /Users/mike/Developer/zed-laravel\nGoal: Report correctness defects in the PHP translation-catalogue AST walker.\nContext: The branch replaced a regex parser with a tree-sitter walk. Read-only,\nno write tools, no patching. Do not edit any file. Report findings only.\nConstraints:\n- Read-only. Do not modify anything.\nAcceptance:\n- AC1: Each finding names a file, a line, and a failing input.\nDone when: Every finding is reported with a file, a line, and a failing input.",
    "verdict": "silent",
    "check": {
      "isComplete": true,
      "missing": [],
      "shape": "brief"
    }
  },
  {
    "name": "Context: none",
    "prompt": "Workdir: /Users/mike/Developer/workbench-core\nGoal: Make the credential guard stop matching .env by substring.\nContext: none\nOldContext: The guard matches .env anywhere in the raw command text, so any command\nmentioning a path containing .envrc trips it. Three false positives in one day.\nConstraints: none\nAcceptance:\n- AC1: A path containing .envrc passes the guard.\n- AC2: A read of .env is still refused.\nDone when: The guard rejects .envrc and still catches .env, with a test per case.",
    "verdict": "silent",
    "check": {
      "isComplete": true,
      "missing": [],
      "shape": "brief"
    }
  },
  {
    "name": "Context: prose",
    "prompt": "Workdir: /Users/mike/Developer/workbench-core\nGoal: Make the credential guard stop matching .env by substring.\nContext: The guard matches .env anywhere in the raw command text, so any command\nmentioning a path containing .envrc trips it. Three false positives in one day.\nConstraints: none\nAcceptance:\n- AC1: A path containing .envrc passes the guard.\n- AC2: A read of .env is still refused.\nDone when: The guard rejects .envrc and still catches .env, with a test per case.",
    "verdict": "silent",
    "check": {
      "isComplete": true,
      "missing": [],
      "shape": "brief"
    }
  },
  {
    "name": "Acceptance: none passes",
    "prompt": "Workdir: /Users/mike/Developer/workbench-core\nGoal: Make the credential guard stop matching .env by substring.\nContext: The guard matches .env anywhere in the raw command text, so any command\nmentioning a path containing .envrc trips it. Three false positives in one day.\nConstraints: none\nAcceptance: none\nDone when: The guard rejects .envrc and still catches .env, with a test per case.",
    "verdict": "silent",
    "check": {
      "isComplete": true,
      "missing": [],
      "shape": "brief"
    }
  },
  {
    "name": "a bare Acceptance: header with no criteria passes",
    "prompt": "Workdir: /Users/mike/Developer/workbench-core\nGoal: Make the credential guard stop matching .env by substring.\nContext: The guard matches .env anywhere in the raw command text, so any command\nmentioning a path containing .envrc trips it. Three false positives in one day.\nConstraints: none\nAcceptance:\nDone when: The guard rejects .envrc and still catches .env, with a test per case.",
    "verdict": "silent",
    "check": {
      "isComplete": true,
      "missing": [],
      "shape": "brief"
    }
  },
  {
    "name": "the old five-slot brief is refused",
    "prompt": "Workdir: /Users/mike/Developer/workbench-core\nGoal: Make the credential guard stop matching .env by substring.\nContext: The guard matches .env anywhere in the raw command text, so any command\nmentioning a path containing .envrc trips it. Three false positives in one day.\nConstraints: none\nDone when: The guard rejects .envrc and still catches .env, with a test per case.",
    "verdict": "deny",
    "check": {
      "isComplete": false,
      "missing": [
        "Acceptance:"
      ],
      "shape": "brief"
    }
  },
  {
    "name": "Acceptance: only mid-line in prose is refused",
    "prompt": "Workdir: /Users/mike/Developer/workbench-core\nGoal: Make the credential guard stop matching .env by substring.\nContext: The guard matches .env anywhere in the raw command text, so any command\nmentioning a path containing .envrc trips it. Three false positives in one day.\nConstraints: none, see the Acceptance: list later\nDone when: The guard rejects .envrc and still catches .env, with a test per case.",
    "verdict": "deny",
    "check": {
      "isComplete": false,
      "missing": [
        "Acceptance:"
      ],
      "shape": "brief"
    }
  },
  {
    "name": "a very long complete brief still passes",
    "prompt": "Workdir: /Users/mike/Developer/workbench-core\nGoal: Make the credential guard stop matching .env by substring.\nContext: The guard matches .env anywhere in the raw command text, so any command\nmentioning a path containing .envrc trips it. Three false positives in one day.\nConstraints: none\nAcceptance:\n- AC1: A path containing .envrc passes the guard.\n- AC2: A read of .env is still refused.\nDone when: The guard rejects .envrc and still catches .env, with a test per case.\nContext continues with more prose that a real brief would carry, at length.\nContext continues with more prose that a real brief would carry, at length.\nContext continues with more prose that a real brief would carry, at length.\nContext continues with more prose that a real brief would carry, at length.\nContext continues with more prose that a real brief would carry, at length.\nContext continues with more prose that a real brief would carry, at length.\nContext continues with more prose that a real brief would carry, at length.\nContext continues with more prose that a real brief would carry, at length.",
    "verdict": "silent",
    "check": {
      "isComplete": true,
      "missing": [],
      "shape": "brief"
    }
  },
  {
    "name": "a very short complete brief still passes",
    "prompt": "Workdir: /x\nGoal: g\nContext: none\nConstraints: none\nAcceptance: none\nDone when: d",
    "verdict": "silent",
    "check": {
      "isComplete": true,
      "missing": [],
      "shape": "brief"
    }
  },
  {
    "name": "no state file -> gate is ON by default",
    "prompt": "Go read the config parser and fix whatever looks wrong in it.",
    "verdict": "deny",
    "check": {
      "isComplete": false,
      "missing": [
        "Workdir:",
        "Goal:",
        "Context:",
        "Constraints:",
        "Acceptance:",
        "Done when:"
      ],
      "shape": "brief"
    }
  },
  {
    "name": "removing the state file re-enables the gate",
    "prompt": "Go read the config parser and fix whatever looks wrong in it.",
    "verdict": "deny",
    "check": {
      "isComplete": false,
      "missing": [
        "Workdir:",
        "Goal:",
        "Context:",
        "Constraints:",
        "Acceptance:",
        "Done when:"
      ],
      "shape": "brief"
    }
  },
  {
    "name": "Item ID: 369",
    "prompt": "Item ID: 369",
    "verdict": "silent",
    "check": {
      "isComplete": true,
      "missing": [],
      "shape": "item-id"
    }
  },
  {
    "name": "Item ID with surrounding whitespace",
    "prompt": "  Item ID: 369\n",
    "verdict": "silent",
    "check": {
      "isComplete": true,
      "missing": [],
      "shape": "item-id"
    }
  },
  {
    "name": "Repo sweep: owner/repo",
    "prompt": "Repo sweep: mike-bronner/phpcs-rules",
    "verdict": "silent",
    "check": {
      "isComplete": true,
      "missing": [],
      "shape": "repo-sweep"
    }
  },
  {
    "name": "the retired summary-writer sentinel is NOT exempt",
    "prompt": "Process pending session summary.\nsession_id: d640e864-4bed-4e3c-8b35-85d9e4c79588\nmarker_path: /Users/mike/.claude-memory-cache/pending-summaries/d640e864.json",
    "verdict": "deny",
    "check": {
      "isComplete": false,
      "missing": [
        "Workdir:",
        "Goal:",
        "Context:",
        "Constraints:",
        "Acceptance:",
        "Done when:"
      ],
      "shape": "brief"
    }
  },
  {
    "name": "Item ID prefix + free prose is NOT exempt",
    "prompt": "Item ID: 369\nNow go and refactor the whole parser however you see fit.",
    "verdict": "deny",
    "check": {
      "isComplete": false,
      "missing": [
        "Workdir:",
        "Goal:",
        "Context:",
        "Constraints:",
        "Acceptance:",
        "Done when:"
      ],
      "shape": "brief"
    }
  },
  {
    "name": "Repo sweep prefix + free prose is NOT exempt",
    "prompt": "Repo sweep: a/b\nAlso rewrite the test suite.",
    "verdict": "deny",
    "check": {
      "isComplete": false,
      "missing": [
        "Workdir:",
        "Goal:",
        "Context:",
        "Constraints:",
        "Acceptance:",
        "Done when:"
      ],
      "shape": "brief"
    }
  },
  {
    "name": "Item ID + trailing prose on ONE line is NOT exempt",
    "prompt": "Item ID: 369 and refactor the whole parser however you see fit",
    "verdict": "deny",
    "check": {
      "isComplete": false,
      "missing": [
        "Workdir:",
        "Goal:",
        "Context:",
        "Constraints:",
        "Acceptance:",
        "Done when:"
      ],
      "shape": "brief"
    }
  },
  {
    "name": "Repo sweep + trailing prose on ONE line is NOT exempt",
    "prompt": "Repo sweep: a/b and also rewrite the test suite",
    "verdict": "deny",
    "check": {
      "isComplete": false,
      "missing": [
        "Workdir:",
        "Goal:",
        "Context:",
        "Constraints:",
        "Acceptance:",
        "Done when:"
      ],
      "shape": "brief"
    }
  },
  {
    "name": "Item ID with a non-numeric target is NOT exempt",
    "prompt": "Item ID: whatever",
    "verdict": "deny",
    "check": {
      "isComplete": false,
      "missing": [
        "Workdir:",
        "Goal:",
        "Context:",
        "Constraints:",
        "Acceptance:",
        "Done when:"
      ],
      "shape": "brief"
    }
  },
  {
    "name": "Repo sweep with no slug is NOT exempt",
    "prompt": "Repo sweep: notaslug",
    "verdict": "deny",
    "check": {
      "isComplete": false,
      "missing": [
        "Workdir:",
        "Goal:",
        "Context:",
        "Constraints:",
        "Acceptance:",
        "Done when:"
      ],
      "shape": "brief"
    }
  },
  {
    "name": "a bare Item ID is still exempt",
    "prompt": "Item ID: 369",
    "verdict": "silent",
    "check": {
      "isComplete": true,
      "missing": [],
      "shape": "item-id"
    }
  },
  {
    "name": "a bare Repo sweep is still exempt",
    "prompt": "Repo sweep: mike-bronner/phpcs-rules",
    "verdict": "silent",
    "check": {
      "isComplete": true,
      "missing": [],
      "shape": "repo-sweep"
    }
  },
  {
    "name": "fenced code block flags",
    "prompt": "Workdir: /Users/mike/Developer/workbench-core\nGoal: Make the credential guard stop matching .env by substring.\nContext: The guard matches .env anywhere in the raw command text, so any command\nmentioning a path containing .envrc trips it. Three false positives in one day.\nConstraints: none\nAcceptance:\n- AC1: A path containing .envrc passes the guard.\n- AC2: A read of .env is still refused.\nDone when: The guard rejects .envrc and still catches .env, with a test per case.\n```bash\nsed -i '' 's/a/b/' file.sh\n```",
    "verdict": "hint",
    "check": {
      "isComplete": true,
      "missing": [],
      "shape": "brief"
    }
  },
  {
    "name": "shell command on its own line flags",
    "prompt": "Workdir: /Users/mike/Developer/workbench-core\nGoal: Make the credential guard stop matching .env by substring.\nContext: The guard matches .env anywhere in the raw command text, so any command\nmentioning a path containing .envrc trips it. Three false positives in one day.\nConstraints: none\nAcceptance:\n- AC1: A path containing .envrc passes the guard.\n- AC2: A read of .env is still refused.\nDone when: The guard rejects .envrc and still catches .env, with a test per case.\ngit rebase -i origin/main",
    "verdict": "hint",
    "check": {
      "isComplete": true,
      "missing": [],
      "shape": "brief"
    }
  },
  {
    "name": "three numbered steps flag",
    "prompt": "Workdir: /Users/mike/Developer/workbench-core\nGoal: Make the credential guard stop matching .env by substring.\nContext: The guard matches .env anywhere in the raw command text, so any command\nmentioning a path containing .envrc trips it. Three false positives in one day.\nConstraints: none\nAcceptance:\n- AC1: A path containing .envrc passes the guard.\n- AC2: A read of .env is still refused.\nDone when: The guard rejects .envrc and still catches .env, with a test per case.\n1. Open the file.\n2. Change the regex.\n3. Run the suite.",
    "verdict": "hint",
    "check": {
      "isComplete": true,
      "missing": [],
      "shape": "brief"
    }
  },
  {
    "name": "two numbered steps do NOT flag",
    "prompt": "Workdir: /Users/mike/Developer/workbench-core\nGoal: Make the credential guard stop matching .env by substring.\nContext: The guard matches .env anywhere in the raw command text, so any command\nmentioning a path containing .envrc trips it. Three false positives in one day.\nConstraints: none\nAcceptance:\n- AC1: A path containing .envrc passes the guard.\n- AC2: A read of .env is still refused.\nDone when: The guard rejects .envrc and still catches .env, with a test per case.\n1. Open the file.\n2. Change the regex.",
    "verdict": "silent",
    "check": {
      "isComplete": true,
      "missing": [],
      "shape": "brief"
    }
  },
  {
    "name": "an inline mention of git does NOT flag",
    "prompt": "Workdir: /Users/mike/Developer/workbench-core\nGoal: Make the credential guard stop matching .env by substring.\nContext: The guard matches .env anywhere in the raw command text, so any command\nmentioning a path containing .envrc trips it. Three false positives in one day.\nConstraints: none\nAcceptance:\n- AC1: A path containing .envrc passes the guard.\n- AC2: A read of .env is still refused.\nDone when: The guard rejects .envrc and still catches .env, with a test per case.\nThe reason is that git history shows the guard was added later.",
    "verdict": "silent",
    "check": {
      "isComplete": true,
      "missing": [],
      "shape": "brief"
    }
  },
  {
    "name": "'make sure ...' does NOT flag",
    "prompt": "Workdir: /Users/mike/Developer/workbench-core\nGoal: Make the credential guard stop matching .env by substring.\nContext: The guard matches .env anywhere in the raw command text, so any command\nmentioning a path containing .envrc trips it. Three false positives in one day.\nConstraints: none\nAcceptance:\n- AC1: A path containing .envrc passes the guard.\n- AC2: A read of .env is still refused.\nDone when: The guard rejects .envrc and still catches .env, with a test per case.\nmake sure the suite is green before reporting.",
    "verdict": "silent",
    "check": {
      "isComplete": true,
      "missing": [],
      "shape": "brief"
    }
  },
  {
    "name": "'touch only ...' does NOT flag",
    "prompt": "Workdir: /Users/mike/Developer/workbench-core\nGoal: Make the credential guard stop matching .env by substring.\nContext: The guard matches .env anywhere in the raw command text, so any command\nmentioning a path containing .envrc trips it. Three false positives in one day.\nConstraints: none\nAcceptance:\n- AC1: A path containing .envrc passes the guard.\n- AC2: A read of .env is still refused.\nDone when: The guard rejects .envrc and still catches .env, with a test per case.\ntouch only the files listed above.",
    "verdict": "silent",
    "check": {
      "isComplete": true,
      "missing": [],
      "shape": "brief"
    }
  },
  {
    "name": "'go through ...' does NOT flag",
    "prompt": "Workdir: /Users/mike/Developer/workbench-core\nGoal: Make the credential guard stop matching .env by substring.\nContext: The guard matches .env anywhere in the raw command text, so any command\nmentioning a path containing .envrc trips it. Three false positives in one day.\nConstraints: none\nAcceptance:\n- AC1: A path containing .envrc passes the guard.\n- AC2: A read of .env is still refused.\nDone when: The guard rejects .envrc and still catches .env, with a test per case.\ngo through the parser and note what it misses.",
    "verdict": "silent",
    "check": {
      "isComplete": true,
      "missing": [],
      "shape": "brief"
    }
  },
  {
    "name": "'sh' as a sentence opener does NOT flag",
    "prompt": "Workdir: /Users/mike/Developer/workbench-core\nGoal: Make the credential guard stop matching .env by substring.\nContext: The guard matches .env anywhere in the raw command text, so any command\nmentioning a path containing .envrc trips it. Three false positives in one day.\nConstraints: none\nAcceptance:\n- AC1: A path containing .envrc passes the guard.\n- AC2: A read of .env is still refused.\nDone when: The guard rejects .envrc and still catches .env, with a test per case.\nsh scripts in this repo follow the same helper layout.",
    "verdict": "silent",
    "check": {
      "isComplete": true,
      "missing": [],
      "shape": "brief"
    }
  },
  {
    "name": "a real command still flags after the exclusions",
    "prompt": "Workdir: /Users/mike/Developer/workbench-core\nGoal: Make the credential guard stop matching .env by substring.\nContext: The guard matches .env anywhere in the raw command text, so any command\nmentioning a path containing .envrc trips it. Three false positives in one day.\nConstraints: none\nAcceptance:\n- AC1: A path containing .envrc passes the guard.\n- AC2: A read of .env is still refused.\nDone when: The guard rejects .envrc and still catches .env, with a test per case.\ncomposer update crossbibleinc/bible-models",
    "verdict": "hint",
    "check": {
      "isComplete": true,
      "missing": [],
      "shape": "brief"
    }
  },
  {
    "name": "the skill's brief passes the gate unaided",
    "prompt": "Workdir: /Users/mike/Documents/Claude/Memory\nGoal: Write the narrative summary for session d640e864-4bed-4e3c-8b35-85d9e4c79588 into the memory vault, promote any decisions it earns, and clear its pending marker.\nContext: A Claude Code session ended and its raw log was dumped to disk, but no summary exists yet. You cannot derive these values, so they are given:\nsession_id: d640e864-4bed-4e3c-8b35-85d9e4c79588\nmarker_path: /Users/mike/.claude-memory-cache/pending-summaries/d640e864.json\nlog_path: /Users/mike/Documents/Claude/Memory/sessions/2026-08-19/d640e864.log.md\ntranscript_path: /Users/mike/.claude/projects/x/d640e864.jsonl\nThe log is a 7-day cache inside the vault. The transcript is the original Claude Code JSONL and lives about 30 days. A missing log therefore means the cache expired, never that the session is lost.\nConstraints:\n- Summarize from transcript_path whenever log_path no longer exists. Never report a pruned log as an unrecoverable session.\n- Follow your agent definition for the summary format and for the bar a decision must clear before promotion.\n- You receive no follow-up messages. Work from this brief alone and stop when the marker is gone.\nAcceptance:\n- AC1: The summary is written from the log, or from the transcript when the log is gone.\n- AC2: A decision is promoted only when it clears the bar in your agent definition.\n- AC3: The marker is removed only after the summary is written.\nDone when: The summary note exists in the vault, any promoted decisions are written, and /Users/mike/.claude-memory-cache/pending-summaries/d640e864.json no longer exists.",
    "verdict": "silent",
    "check": {
      "isComplete": true,
      "missing": [],
      "shape": "brief"
    }
  },
  {
    "name": "the skill's brief minus a slot is refused",
    "prompt": "Workdir: /Users/mike/Documents/Claude/Memory\nContext: A Claude Code session ended and its raw log was dumped to disk, but no summary exists yet. You cannot derive these values, so they are given:\nsession_id: d640e864-4bed-4e3c-8b35-85d9e4c79588\nmarker_path: /Users/mike/.claude-memory-cache/pending-summaries/d640e864.json\nlog_path: /Users/mike/Documents/Claude/Memory/sessions/2026-08-19/d640e864.log.md\ntranscript_path: /Users/mike/.claude/projects/x/d640e864.jsonl\nThe log is a 7-day cache inside the vault. The transcript is the original Claude Code JSONL and lives about 30 days. A missing log therefore means the cache expired, never that the session is lost.\nConstraints:\n- Summarize from transcript_path whenever log_path no longer exists. Never report a pruned log as an unrecoverable session.\n- Follow your agent definition for the summary format and for the bar a decision must clear before promotion.\n- You receive no follow-up messages. Work from this brief alone and stop when the marker is gone.\nAcceptance:\n- AC1: The summary is written from the log, or from the transcript when the log is gone.\n- AC2: A decision is promoted only when it clears the bar in your agent definition.\n- AC3: The marker is removed only after the summary is written.\nDone when: The summary note exists in the vault, any promoted decisions are written, and /Users/mike/.claude-memory-cache/pending-summaries/d640e864.json no longer exists.",
    "verdict": "deny",
    "check": {
      "isComplete": false,
      "missing": [
        "Goal:"
      ],
      "shape": "brief"
    }
  }
]
