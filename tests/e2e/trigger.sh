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
#   PAR=4 TURNS=6 bash tests/e2e/trigger.sh
#   REPEAT=3 bash tests/e2e/trigger.sh opus   # same case N times: triggering is stochastic, so a
#                                             # single green run is not evidence that it is stable
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Resolve the real CLI now: the stub dir goes on PATH later, and a stubbed `claude` would otherwise
# hijack this script's own session launch (it did, once).
CLAUDE_BIN="$(command -v claude)"
REPO="$(cd "$HERE/../.." && pwd)"
FILTER="${1:-}"; PAR="${PAR:-4}"; MODEL="${MODEL:-}"; TURNS="${TURNS:-6}"; REPEAT="${REPEAT:-1}"
ART="${ART:-$HERE/artifacts/trigger-$(date +%H%M%S)}"; mkdir -p "$ART"
ART="$(cd "$ART" && pwd)"   # absolute: each case runs from its own cwd

# --- session-only plugin holding just the candidate skill
PLUG="$ART/plug"; mkdir -p "$PLUG/.claude-plugin" "$PLUG/skills"
rm -rf "$PLUG/skills/spec-debate"; cp -R "$REPO" "$PLUG/skills/spec-debate"
rm -rf "$PLUG/skills/spec-debate/.git" "$PLUG/skills/spec-debate/tests"
printf '{ "name": "spec-debate-candidate", "version": "1.1.0", "description": "spec-debate under test" }\n' \
  >"$PLUG/.claude-plugin/plugin.json"

# --- stub reviewer CLIs (shared with the hermetic suite) + a canned critique they return
BIN="$ART/bin"; mkdir -p "$BIN"
for n in codex opencode claude; do cp "$REPO/tests/hermetic/stub.sh" "$BIN/$n"; chmod +x "$BIN/$n"; done
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
"FIRE|fire-ru-codex-harness|codex|посоветуйся с кодексом по плану в plan.md"
"FIRE|fire-en-noname|codex|get a second opinion on plan.md from someone"
"FIRE|fire-ru-kimi-model|opencode:kimi-k3|спроси кими, держится ли план в plan.md"
"FIRE|fire-ru-glm-critique|opencode:glm-5.2|пусть glm раскритикует plan.md"
"FIRE|fire-ru-opus-review|claude:opus|пусть опус оценит plan.md"
"FIRE|fire-en-claim-stress|codex|stress-test this claim with codex: for internal tools we should default to a modular monolith until we pass ~4 teams"
"FIRE|fire-en-code-effort|codex+xhigh|think it through with codex at maximum reasoning depth before I refactor ratelimit.py — don't touch the code yet"
"FIRE|fire-ru-anyone-secondop|codex|дай кому-нибудь на второе мнение plan.md"
"FIRE|fire-en-privacy|codex|debate the redesign of billing.py with codex, but privacy mode — don't send the code, just an abstracted summary"
"FIRE|fire-ru-debate-word|codex|прогони plan.md через дебат"
"FIRE|fire-en-second-model|codex|let a second model critique plan.md"
"FIRE|fire-ru-gpt-name|codex|спроси у gpt, что не так с plan.md"
"NOFIRE|nofire-ru-worker-kimi|none|перепиши эту функцию на kimi: def median(nums): nums.sort(); return nums[len(nums)//2]"
"NOFIRE|nofire-ru-bare-assess|none|оцени plan.md"
"NOFIRE|nofire-ru-bare-holes|none|найди дыры в plan.md"
"NOFIRE|nofire-en-bare-review|none|review plan.md"
"NOFIRE|nofire-en-worker-opus|none|use opus to refactor ratelimit.py into two files"
"NOFIRE|nofire-ru-write-spec|none|напиши спеку для внутреннего сервиса сокращения ссылок"
"NOFIRE|nofire-ru-make-plan|none|составь план миграции на новую схему БД и покажи мне"
"NOFIRE|nofire-en-tool-question|none|which model is better for reviewing code — kimi or codex?"
"SOFT-NOFIRE|soft-ru-model-opinion|none|что кими думает про рынок LLM в 2026?"
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
