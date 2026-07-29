#!/usr/bin/env bash
# Quality evals: does a real debate actually make the artifact better — and does it keep its promises
# about what it touches and what it sends?
#
# Scenarios are DATA, not code: each one is a directory under fixtures/scenarios/ holding the request
# (`prompt.txt`) and the files to seed the sandbox with (`seed/`), plus an entry in fixtures/answers.json
# listing the defects planted in them. Adding a scenario means adding files — no edit to this script.
#
# Each run seeds a sandbox, launches a real session with only the candidate skill loaded, and scores the
# result against the answer key, which the session never sees. The reviewer CLIs are wrapped by proxy.sh,
# so the critique is real while the exact prompt bytes are still recorded — that is what makes the
# privacy-mode and secret-leak assertions evidence rather than a claim. Isolation is the same as the
# triggering suite: session-only plugin, no user settings, a fresh git repo per scenario (so stray writes
# show up as untracked files).
#
#   bash tests/e2e/quality.sh          # all scenarios
#   bash tests/e2e/quality.sh q3       # name filter (regex)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
CLAUDE_BIN="$(command -v claude)"
REAL_CODEX="$(command -v codex || true)"; REAL_OPENCODE="$(command -v opencode || true)"
FILTER="${1:-}"; TURNS="${TURNS:-45}"
SCEN_DIR="$HERE/fixtures/scenarios"
die() { echo "FATAL: $*" >&2; exit 2; }

# shellcheck source=tests/e2e/lib.sh
. "$HERE/lib.sh"
ART="${ART:-$(default_art quality)}"; mkdir -p "$ART"; ART="$(cd "$ART" && pwd)"

PLUG="$ART/plug"; build_candidate_plugin "$REPO" "$PLUG"

BIN="$ART/bin"; mkdir -p "$BIN"
for n in codex opencode; do cp "$HERE/proxy.sh" "$BIN/$n"; chmod +x "$BIN/$n"; done

# --- discover. An empty dir would expand to the literal glob, hence the -d guard; scenario names are
# --- ASCII, so glob order is stable across locales.
selected=()
for dir in "$SCEN_DIR"/*/; do
  [ -d "$dir" ] || continue
  name="$(basename "$dir")"
  [ -z "$FILTER" ] || [[ "$name" =~ $FILTER ]] || continue
  selected+=("$name")
done
[ "${#selected[@]}" -gt 0 ] || die "no scenario under fixtures/scenarios/ matched '${FILTER:-(all)}'"

# --- preflight EVERY selected scenario before spending a single paid session: a malformed one found
# --- halfway through would already have cost the sessions before it.
for name in "${selected[@]}"; do
  [ -r "$SCEN_DIR/$name/prompt.txt" ]      || die "$name: fixtures/scenarios/$name/prompt.txt is missing"
  [ -d "$SCEN_DIR/$name/seed" ]            || die "$name: fixtures/scenarios/$name/seed/ is missing"
  [ -n "$(ls -A "$SCEN_DIR/$name/seed")" ] || die "$name: fixtures/scenarios/$name/seed/ is empty"
done

for name in "${selected[@]}"; do
  dir="$ART/$name"; mkdir -p "$dir/cwd" "$dir/log"
  # `seed/.` copies the whole tree including dotfiles; unchecked, an incomplete sandbox would be debated
  cp -R "$SCEN_DIR/$name/seed/." "$dir/cwd/" || die "$name: could not copy seed/ into the sandbox"
  prompt="$(cat "$SCEN_DIR/$name/prompt.txt")"   # file contents, trailing newline dropped
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
