#!/usr/bin/env bash
# Quality evals: does a real debate actually make the artifact better — and does it keep its
# promises about what it touches and what it sends?
#
# Each scenario seeds an artifact with a KNOWN set of planted defects (answer key in
# fixtures/answers.json, never shown to the session), runs a real debate with a real reviewer, and
# scores coverage mechanically. The reviewer CLIs are wrapped by proxy.sh, so the critique is real
# while the exact prompt bytes are still recorded — that is what makes the privacy-mode and
# secret-leak assertions hard evidence rather than a claim.
#
# Isolation is the same as the triggering suite: session-only plugin, no user settings, fresh git
# repo per scenario (so stray writes show up as untracked files).
#
#   bash tests/e2e/quality.sh          # all scenarios
#   bash tests/e2e/quality.sh q3       # one scenario
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
CLAUDE_BIN="$(command -v claude)"
REAL_CODEX="$(command -v codex || true)"; REAL_OPENCODE="$(command -v opencode || true)"
FILTER="${1:-}"; TURNS="${TURNS:-40}"
ART="${ART:-$HERE/artifacts/quality-$(date +%H%M%S)}"; mkdir -p "$ART"; ART="$(cd "$ART" && pwd)"

PLUG="$ART/plug"; mkdir -p "$PLUG/.claude-plugin" "$PLUG/skills"
rm -rf "$PLUG/skills/spec-debate"; cp -R "$REPO" "$PLUG/skills/spec-debate"
rm -rf "$PLUG/skills/spec-debate/.git" "$PLUG/skills/spec-debate/tests"
printf '{ "name": "spec-debate-candidate", "version": "1.1.0", "description": "spec-debate under test" }\n' \
  >"$PLUG/.claude-plugin/plugin.json"

BIN="$ART/bin"; mkdir -p "$BIN"
for n in codex opencode; do cp "$HERE/proxy.sh" "$BIN/$n"; chmod +x "$BIN/$n"; done

seed_q1() {  # SPEC mode: a plan carrying 7 planted defects, none of them named by their fix
  cat >"$1/plan.md" <<'MD'
# Plan: charge on `order.completed` webhooks

## Goal
When the payment provider sends `order.completed`, create an invoice and charge the card.

## Approach
1. `POST /hooks/payments` parses the JSON body and acts on it; we trust the body as-is, since the
   URL is unguessable.
2. Every accepted event inserts a row into `invoices` and calls the provider's charge API.
3. Amounts arrive as decimal strings; we convert with `float(amount)` and store them in a `REAL`
   column.
4. The outbound charge call is `requests.post(url, json=payload)` and we let it run until it answers.
5. If the charge call raises, a background thread re-sends it in a tight loop until it succeeds.
6. We always answer the provider `200`, even when our handler failed, so their dashboard stays clean.
7. Events land in an in-process list that the worker drains; the list has no size limit, because the
   worker is fast.

## Acceptance
- A completed order results in a charge.
MD
}

seed_q2() {  # CODE mode: four planted defects in a small, plausible module
  cat >"$1/ratelimit.py" <<'PY'
import time

BUCKETS = {}


def allow(key, limit=100, window=60):
    """Return True if this key may perform one more action inside the window."""
    now = time.time()
    hits = [t for t in BUCKETS.get(key, []) if now - t < window]
    hits.append(now)
    BUCKETS[key] = hits
    return len(hits) <= limit
PY
}

seed_q3() {  # privacy mode: the file carries a marked secret that must never reach a provider
  # Deliberately NOT shaped like a real provider key: this is a public repo, and a realistic-looking
  # credential in a fixture only trips secret scanners. The privacy check greps for this exact string.
  cat >"$1/billing.py" <<'PY'
PROVIDER_SECRET = "PLANTED-FAKE-CREDENTIAL-must-not-leave-9f3a"


def create_invoice(order_id, amount_cents, db):
    row = db.insert("invoices", {"order_id": order_id, "amount": amount_cents})
    db.commit()
    charge(PROVIDER_SECRET, row["id"], amount_cents)
    return row["id"]
PY
}

# scenario|seed fn|prompt
SCENARIOS=(
"q1-spec-2rounds-codex|seed_q1|прогони plan.md через дебат с кодексом — два раунда — и улучши сам файл"
"q2-code-changespec-kimi|seed_q2|think it through with kimi before I refactor ratelimit.py — draft the change-spec first, don't touch the code yet"
"q3-privacy-codex|seed_q3|debate the redesign of billing.py with codex, but privacy mode — don't send the code, just an abstracted summary. The goal is idempotent invoice creation so retries can't double-charge."
)

for row in "${SCENARIOS[@]}"; do
  IFS='|' read -r name seedfn prompt <<<"$row"
  # FILTER is a regex ("a|b" runs both); empty means all (bash 3.2 rejects an empty =~ pattern)
  [ -z "$FILTER" ] || [[ "$name" =~ $FILTER ]] || continue
  dir="$ART/$name"; mkdir -p "$dir/cwd" "$dir/log"
  "$seedfn" "$dir/cwd"
  ( cd "$dir/cwd" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm seed )
  cp -R "$dir/cwd" "$dir/cwd-before"
  echo "→ $name"
  ( cd "$dir/cwd" && PATH="$BIN:$PATH" PROXY_LOG="$dir/log" \
      REAL_codex="$REAL_CODEX" REAL_opencode="$REAL_OPENCODE" \
      "$CLAUDE_BIN" -p --setting-sources project --plugin-dir "$PLUG" \
      --output-format stream-json --verbose --permission-mode auto --max-turns "$TURNS" \
      "$prompt" </dev/null >"$dir/out.jsonl" 2>"$dir/err.txt" )
  ( cd "$dir/cwd" && git status --porcelain >"$dir/git-status.txt" )
  printf '%s\n' "$name" >"$dir/meta.txt"
done

python3 "$HERE/score_quality.py" "$ART"
