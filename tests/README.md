# Tests

Four suites, in the order you should run them: cheapest and most deterministic first.

| Suite | What it proves | Cost | Needs |
|---|---|---|---|
| `hermetic/run.sh` | the dispatcher's contract: routing, resolution, isolation, failure modes, shipped-file consistency | free, ~15s | `bash`, `python3`, `pgrep` |
| `e2e/trigger.sh` | the skill fires on the right phrasings (and stays quiet on the wrong ones), and Step 0 routes to the harness the user named | Claude turns only | `claude` |
| `e2e/fallback.sh` | it works on machines with a different set of reviewer CLIs, and never silently swaps a harness you named | Claude turns only | `claude` |
| `e2e/quality.sh` | a real debate finds planted defects, leaves code alone in CODE mode, and never leaks source or secrets in privacy mode | real reviewer calls | `claude` + `codex` + `opencode` |

```bash
bash tests/hermetic/run.sh              # all 73 cases (one is skipped when run as root)
bash tests/hermetic/run.sh opencode     # filter by case-name substring

bash tests/e2e/trigger.sh               # 28 phrasings, 4 at a time
TURNS=24 bash tests/e2e/trigger.sh privacy   # privacy mode drafts an abstract first: it needs more
MODEL=sonnet PAR=6 bash tests/e2e/trigger.sh
bash tests/e2e/fallback.sh
bash tests/e2e/quality.sh q3            # one scenario
```

Only the hermetic suite runs in CI (it needs no accounts): automatically on GitHub, as a manual job in
the plugin marketplace repo. The e2e suites cost provider calls, so they are a pre-release gate you run.

## Adding a quality scenario

Scenarios are data. Create a directory and an answer key — no script changes:

```
fixtures/scenarios/<name>/prompt.txt     # the request, exactly as a user would phrase it
fixtures/scenarios/<name>/seed/…         # files copied into the sandbox (subdirectories are fine)
fixtures/answers.json  → "<name>": { defects, expect_reviewer, … }
```

Plant each defect **without the vocabulary of its fix**, and list that vocabulary as the defect's
`any` keywords — that is what makes a hit mean "the debate found it". `expect_reviewer` names the
harness the prompt asks for and the minimum number of critique calls. Optional per-scenario keys:
`want_state_rounds`, `code_must_be_unchanged`, `changespec_required`, `must_not_appear_in_prompts`.
Scored paths (`artifact`, `code_must_be_unchanged`) are resolved relative to the sandbox and may be
nested; a required change-spec is looked for at the top level.

The hermetic suite fails if the scenario directories and the answer keys are not the same set, so a
half-added scenario costs 15 free seconds rather than a paid run.

## How the runtime suites stay honest

**Isolation is asserted, not assumed.** Every case runs `claude -p` with `--plugin-dir` (the candidate
skill, loaded for that session only) plus `--setting-sources project` from a throwaway cwd — no user
skills, no other plugins, no MCP servers, no project memory. The scorer reads the session's own `init`
event and fails the run if anything else was loaded, so what decides triggering is the description
alone, exactly as a stranger who installed the skill would experience it.

**Stubbed where the answer is a routing decision** (`hermetic/stub.sh`, also used by `trigger.sh`): the
stub records every call's argv, stdin and cwd, then replays a canned critique. "It said codex" and "it
ran codex at effort xhigh" therefore cannot be confused, and a fired debate costs no provider tokens.

**Proxied where the answer needs a real model** (`e2e/proxy.sh`): the real binary runs, but the exact
prompt bytes are captured first. That is what turns privacy mode from a claim into a check —
`quality.sh` plants a marked credential in the source and fails if it appears in anything that was sent.

**Scored against a hidden answer key** (`e2e/fixtures/answers.json`): each artifact is seeded with known
defects, planted without the vocabulary of their fixes, so a keyword hit means the debate surfaced the
defect rather than echoing the input. Coverage counts the debate's prose, its applied edits and the
saved state — never a re-read of the seeded artifact. And because Claude contributes findings of its
own, each scenario also declares which harness must actually run, and how often: full marks with the
reviewer never called is a failure, not a pass.

**One thing genuinely leaks in from the machine**: the Codex path enforces one `codex exec` at a time by
scanning the real process list, so a Codex run started anywhere else would fail every codex case. Those
cases get a `pgrep` that reports an empty list; the guard case swaps the real one back in and starts its
own process to be found.

Run output goes to a temp dir printed on the run's first line (`ART=<path>` to choose one). Outside the
repo by default: the candidate plugin is built by copying the shipped files, and an artifacts dir inside
the tree used to end up copied into it.
