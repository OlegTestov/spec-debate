# Tests

Three suites, in the order you should run them: cheapest and most deterministic first.

| Suite | What it proves | Cost | Needs |
|---|---|---|---|
| `hermetic/run.sh` | the dispatcher's contract: routing, resolution, isolation, failure modes, shipped-file consistency | free, ~15s | `bash` only |
| `e2e/trigger.sh` | the skill fires on the right phrasings (and stays quiet on the wrong ones), and Step 0 routes to the harness the user named | Claude turns only | `claude` |
| `e2e/fallback.sh` | it works on machines with a different set of reviewer CLIs, and never silently swaps a harness you named | Claude turns only | `claude` |
| `e2e/quality.sh` | a real debate finds planted defects, leaves code alone in CODE mode, and never leaks source or secrets in privacy mode | real reviewer calls | `claude` + `codex` + `opencode` |

```bash
bash tests/hermetic/run.sh              # all 63 cases
bash tests/hermetic/run.sh opencode     # filter by case-name substring

bash tests/e2e/trigger.sh               # 22 phrasings, 4 at a time
MODEL=sonnet PAR=6 bash tests/e2e/trigger.sh
bash tests/e2e/fallback.sh
bash tests/e2e/quality.sh q3            # one scenario
```

## How the runtime suites stay honest

**Isolation is asserted, not assumed.** Every case runs `claude -p` with `--plugin-dir` (the
candidate skill, loaded for that session only) plus `--setting-sources project` from a throwaway
cwd — so no user skills, no other plugins, no MCP servers, no project memory. The scorer reads the
session's own `init` event and fails the run if anything else was loaded. What decides triggering is
therefore the skill's description alone, exactly as a stranger who installed it would experience it.

**The reviewer CLIs are stubbed where the answer is a routing decision** (`hermetic/stub.sh`, also
used by `trigger.sh`): it records the argv, stdin and cwd it was called with, then replays a canned
critique. So "it said codex" and "it actually ran codex with effort xhigh" cannot be confused, and a
fired debate costs no provider tokens.

**The reviewer CLIs are proxied where the answer needs a real model** (`e2e/proxy.sh`): the real
binary runs, but the exact prompt bytes are captured first. That is what turns privacy mode from a
claim into a check — `quality.sh` plants a marked secret in the source and fails if it appears in
anything that was sent.

**One thing genuinely leaks in from the machine**: the Codex path enforces one `codex exec` at a time
by scanning the real process list, so a Codex run started anywhere else would fail every codex case.
The suite therefore gives those cases a `pgrep` that reports an empty list, and the guard case swaps
the real one back in and starts its own process to be found — deterministic either way.

**Quality is scored against a hidden answer key** (`e2e/fixtures/answers.json`): each seeded artifact
carries known defects, planted without using the vocabulary of their fix, so a keyword hit in the
debate's report means the debate surfaced the defect rather than echoing the input. Coverage is read
from the report and the saved state, never from the edited artifact.

Artifacts (transcripts, recorded prompts, before/after trees) land in `tests/e2e/artifacts/` and are
gitignored — keep them when a case fails; they are the evidence.
