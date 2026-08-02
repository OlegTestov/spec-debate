#!/usr/bin/env bash
# Triggering + routing evals against a real Claude session, with the reviewer CLIs stubbed.
#
# What is real: the session, the skill's description (what decides triggering), and Step 0's
# reviewer resolution. What is stubbed: codex / opencode / claude-as-reviewer, so a fired debate
# costs no provider tokens and the resolved harness+model+effort are recorded as argv we can assert.
#
# Isolation (proven per case from the session's own init event): --plugin-dir loads only the
# candidate skill, --setting-sources project drops all user settings (no user skills, no other
# plugins, no MCP), and each case runs in its own throwaway cwd (no project memory). Every case sees
# the SAME seeded files, so the only variable is how the request is phrased.
#
#   bash tests/e2e/trigger.sh                 # all cases
#   bash tests/e2e/trigger.sh kimi            # only cases whose name matches
#   MODEL=sonnet bash tests/e2e/trigger.sh    # pin a model (default: the CLI's own default)
#   PAR=4 TURNS=24 bash tests/e2e/trigger.sh   # the cap is a ceiling, not a budget: too low ends a
#                                             # case before it reaches the CLI and the route goes unproven
#   REPEAT=3 bash tests/e2e/trigger.sh opus   # same case N times: triggering is stochastic, so a
#                                             # single green run is not evidence that it is stable
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Resolve the real CLI now: the stub dir goes on PATH later, and a stubbed `claude` would otherwise
# hijack this script's own session launch (it did, once).
CLAUDE_BIN="$(command -v claude)"
REPO="$(cd "$HERE/../.." && pwd)"
FILTER="${1:-}"; PAR="${PAR:-4}"; MODEL="${MODEL:-}"; TURNS="${TURNS:-16}"; REPEAT="${REPEAT:-1}"
# shellcheck source=tests/e2e/lib.sh
. "$HERE/lib.sh"
ART="${ART:-$(default_art trigger)}"; mkdir -p "$ART"; ART="$(cd "$ART" && pwd)"

PLUG="$ART/plug"; build_candidate_plugin "$REPO" "$PLUG"
BIN="$ART/bin"; install_stub_clis "$REPO" "$BIN" codex opencode claude
CANNED='1. MAJOR — no rollback path: the plan drops the old columns in the same release, so a bad
   deploy cannot be reverted without data loss. Add an expand/contract split across two releases.
2. MAJOR — the backfill is unbounded: 40M rows in one transaction will hold locks long enough to
   stall writes. Batch it with a bounded key range and a resumable cursor.
3. MINOR — no acceptance criteria: "migration completes" is not measurable. State max lock time,
   max replica lag, and a row-count parity check.'
export STUB_OUT="$CANNED"
export STUB_CATALOG='opencode-go/kimi-k2
opencode-go/kimi-k3
opencode-go/glm-4.6
opencode-go/glm-5.2
opencode-go/deepseek-v3.2
anthropic/claude-sonnet-4-5'

seed() {  # every case gets the same artifacts, so only the phrasing varies
  local d="$1"
  cat >"$d/plan.md" <<'MD'
# Plan: migrate orders to the new schema

- Add the new `orders_v2` table, backfill all 40M rows in one pass, then drop the old columns in
  the same release.
- Roll the migration out to every tenant at once; a canary is not worth the extra week.
- Reads switch to `orders_v2` behind a feature flag; the flag defaults to on.
- Done when the migration completes without errors.
MD
  cat >"$d/ratelimit.py" <<'PY'
import time

BUCKETS = {}

def allow(key, limit=100, window=60):
    now = time.time()
    hits = [t for t in BUCKETS.get(key, []) if now - t < window]
    hits.append(now)
    BUCKETS[key] = hits
    return len(hits) <= limit
PY
  cat >"$d/billing.py" <<'PY'
def create_invoice(order_id, amount_cents, db):
    row = db.insert("invoices", {"order_id": order_id, "amount": amount_cents})
    db.commit()
    return row["id"]
PY
}

# --- cases: EXPECT|name|expected-route|prompt   (SOFT-* = ambiguous phrasing: reported, not counted)
# route: "codex" | "codex+xhigh" | "opencode:<model>" | "claude:<model>" | "none"
CASES=(
"FIRE|fire-en-codex-harness|codex|consult codex about the migration plan in plan.md"
"FIRE|fire-en-noname|codex|get a second opinion on plan.md from someone"
"FIRE|fire-en-kimi-model|opencode:kimi-k3|ask kimi whether the plan in plan.md holds up"
"FIRE|fire-en-glm-critique|opencode:glm-5.2|let glm tear plan.md apart"
"FIRE|fire-en-opus-review|claude:opus|have opus assess plan.md"
"FIRE|fire-en-claim-stress|codex|stress-test this claim with codex: for internal tools we should default to a modular monolith until we pass ~4 teams"
"FIRE|fire-en-code-effort|codex+xhigh|think it through with codex at maximum reasoning depth before I refactor ratelimit.py — don't touch the code yet"
"FIRE|fire-en-anyone-secondop|codex|give plan.md to someone for a second opinion"
"FIRE|fire-en-privacy|codex|debate the redesign of billing.py with codex, but privacy mode — don't send the code, just an abstracted summary"
"FIRE|fire-en-debate-word|codex|run plan.md through a debate"
"FIRE|fire-en-second-model|codex|let a second model critique plan.md"
"FIRE|fire-en-gpt-name|codex|ask gpt what is wrong with plan.md"
"FIRE|fire-ru-codex-harness|codex|посоветуйся с кодексом по плану в plan.md"
"FIRE|fire-ru-kimi-model|opencode:kimi-k3|спроси кими, держится ли план в plan.md"
"FIRE|fire-ru-opus-review|claude:opus|пусть опус оценит plan.md"
"FIRE|fire-ru-anyone-secondop|codex|дай кому-нибудь на второе мнение plan.md"
"NOFIRE|nofire-en-worker-kimi|none|rewrite this function with kimi: def median(nums): nums.sort(); return nums[len(nums)//2]"
"NOFIRE|nofire-en-bare-review|none|review plan.md"
"NOFIRE|nofire-en-bare-holes|none|find the holes in plan.md"
"NOFIRE|nofire-en-bare-assess|none|assess plan.md for me"
"NOFIRE|nofire-en-worker-opus|none|use opus to refactor ratelimit.py into two files"
"NOFIRE|nofire-en-write-spec|none|write a spec for an internal link-shortener service"
"NOFIRE|nofire-en-make-plan|none|draft a migration plan for the new DB schema and show it to me"
"NOFIRE|nofire-en-tool-question|none|which model is better for reviewing code — kimi or codex?"
"NOFIRE|nofire-ru-worker-kimi|none|перепиши эту функцию на kimi: def median(nums): nums.sort(); return nums[len(nums)//2]"
"NOFIRE|nofire-ru-bare-assess|none|оцени plan.md"
"SOFT-NOFIRE|soft-en-model-opinion|none|what does kimi think about the LLM market in 2026?"
"SOFT-NOFIRE|soft-en-raw-cli|none|run codex exec and show me the raw output"
)

run_case() {  # run_case <expect> <name> <expected-route> <prompt>
  local expect="$1" name="$2" route="$3" prompt="$4"
  local dir="$ART/$name"
  mkdir -p "$dir/cwd" "$dir/log"; seed "$dir/cwd"
  ( cd "$dir/cwd" && PATH="$BIN:$PATH" STUB_LOG="$dir/log" "$CLAUDE_BIN" -p \
      --setting-sources project --plugin-dir "$PLUG" \
      --output-format stream-json --verbose --permission-mode auto --max-turns "$TURNS" \
      ${MODEL:+--model "$MODEL"} "$prompt" </dev/null >"$dir/out.jsonl" 2>"$dir/err.txt" )
  printf '%s\t%s\t%s\n' "$expect" "$name" "$route" >"$dir/meta.tsv"
}

echo "artifacts: $ART"
i=0
for row in "${CASES[@]}"; do
  IFS='|' read -r expect name route prompt <<<"$row"
  # FILTER is a regex ("a|b" runs both); empty means all (bash 3.2 rejects an empty =~ pattern)
  [ -z "$FILTER" ] || [[ "$name" =~ $FILTER ]] || continue
  r=1
  while [ "$r" -le "$REPEAT" ]; do
    [ "$REPEAT" -gt 1 ] && rname="$name-r$r" || rname="$name"
    run_case "$expect" "$rname" "$route" "$prompt" &
    i=$((i + 1)); [ $((i % PAR)) -eq 0 ] && wait
    r=$((r + 1))
  done
done
wait

python3 "$HERE/score_trigger.py" "$ART"
