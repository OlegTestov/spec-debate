#!/usr/bin/env bash
# Universality evals: the skill must work for someone whose machine has a DIFFERENT set of reviewer
# CLIs installed — and must never quietly swap a reviewer the user named by name.
#
# Each case gives the session a restricted PATH containing only the stubs we chose, so "codex is not
# installed" is true for that session (the real /opt/homebrew/bin is not reachable). claude itself is
# launched by absolute path, so the session still runs while `claude` as a REVIEWER is a stub.
#
#   bash tests/e2e/fallback.sh [name-filter]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
CLAUDE_BIN="$(command -v claude)"
# A capped run counts as a FAILURE here (the route IS the assertion), so the cap must be generous.
FILTER="${1:-}"; TURNS="${TURNS:-12}"
# shellcheck source=tests/e2e/lib.sh
. "$HERE/lib.sh"
ART="${ART:-$(default_art fallback)}"; mkdir -p "$ART"; ART="$(cd "$ART" && pwd)"

PLUG="$ART/plug"; build_candidate_plugin "$REPO" "$PLUG"

export STUB_OUT='1. MAJOR — dropping the old columns in the same release leaves no way back.
2. MAJOR — a 40M-row backfill in one pass will hold locks long enough to stall writes.'
export STUB_CATALOG='opencode-go/kimi-k2
opencode-go/kimi-k3
opencode-go/glm-5.2'

# name|stubs to install|expected route|prompt
CASES=(
"fb-noname-no-codex|opencode claude|opencode:kimi-k3|get a second opinion on plan.md from someone"
"fb-noname-only-claude|claude|claude:default|get a second opinion on plan.md from someone"
"fb-named-codex-missing|opencode claude|none|consult codex about the plan in plan.md"
)
# Text the run MUST contain, by case name (kept out of CASES because a regex needs "|";
# a case statement rather than an associative array, so this still runs on bash 3.2 / macOS).
must_for() {
  case "$1" in
    fb-named-codex-missing)
      printf '%s' '(?i)codex[^.]{0,80}(is not installed|not found|install|не установлен|отсутствует)' ;;
  esac
}

for row in "${CASES[@]}"; do
  IFS='|' read -r name stubs route prompt <<<"$row"
  # FILTER is a regex ("a|b" runs both); empty means all (bash 3.2 rejects an empty =~ pattern)
  [ -z "$FILTER" ] || [[ "$name" =~ $FILTER ]] || continue
  dir="$ART/$name"; mkdir -p "$dir/cwd" "$dir/log" "$dir/bin"
  # shellcheck disable=SC2086   # $stubs is a deliberate word-split list
  install_stub_clis "$REPO" "$dir/bin" $stubs
  cat >"$dir/cwd/plan.md" <<'MD'
# Plan: migrate orders to the new schema

- Add `orders_v2`, backfill all 40M rows in one pass, then drop the old columns in the same release.
- Roll out to every tenant at once; a canary is not worth the extra week.
- Done when the migration completes without errors.
MD
  echo "→ $name (stubs: $stubs)"
  ( cd "$dir/cwd" && PATH="$dir/bin:/usr/bin:/bin:/usr/sbin:/sbin" STUB_LOG="$dir/log" \
      "$CLAUDE_BIN" -p --setting-sources project --plugin-dir "$PLUG" \
      --output-format stream-json --verbose --permission-mode auto --max-turns "$TURNS" \
      "$prompt" </dev/null >"$dir/out.jsonl" 2>"$dir/err.txt" )
  printf '%s\t%s\t%s\n' "FIRE" "$name" "$route" >"$dir/meta.tsv"
  must_for "$name" >"$dir/must_text.txt"
done

python3 "$HERE/score_fallback.py" "$ART"
