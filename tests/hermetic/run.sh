#!/usr/bin/env bash
# Hermetic test suite for scripts/run_critique.sh — no network, no provider account, no model call.
# The reviewer CLIs (codex/opencode/claude) are replaced by stub.sh on PATH; run_codex_critique.sh
# is exercised for real (only the `codex` binary under it is stubbed).
#
#   bash tests/hermetic/run.sh            # run all
#   bash tests/hermetic/run.sh opencode   # only cases whose name contains "opencode"
#
# Exit 0 = all pass. Every failure prints the case, the expectation, and what actually happened.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/../.." && pwd)"
DISPATCH="$SKILL_DIR/scripts/run_critique.sh"
FILTER="${1:-}"
[ -r "$DISPATCH" ] || { echo "FATAL: dispatcher not found at $DISPATCH" >&2; exit 2; }

SBX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/spec-debate-hermetic.XXXXXX")" && pwd)"   # normalized: a TMPDIR with a trailing slash would break path asserts
BIN="$SBX/bin"; mkdir -p "$BIN"
export TMPDIR="$SBX/tmp"; mkdir -p "$TMPDIR"      # keeps the dispatcher's temp files inside the sandbox
# Only the system utility dirs: package managers install the real codex/opencode/claude elsewhere
# (Homebrew, ~/.local/bin, npm prefixes), so leaving those out means only our stubs are reachable and
# a "CLI missing" case is a genuinely missing CLI.
BASE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
PASS=0; FAIL=0; SKIP=0; FAILED_NAMES=()

install_stub() { for n in "$@"; do cp "$HERE/stub.sh" "$BIN/$n"; chmod +x "$BIN/$n"; done; }
# The codex helper enforces one-at-a-time by scanning the real process list, so a `codex exec` running
# anywhere else on the machine would make every codex case here fail. Default to a pgrep that reports
# an empty list; the guard case swaps the real one back in and starts its own process to be found.
stub_pgrep_none() { printf '#!/bin/sh\nexit 1\n' >"$BIN/pgrep"; chmod +x "$BIN/pgrep"; }
use_real_pgrep()  { rm -f "$BIN/pgrep"; }   # also used to make pgrep genuinely absent
clear_stubs()  { rm -f "$BIN"/*; }
# A PATH with the usual utilities but one deliberately missing — for fail-closed guards.
make_minbin_without() {
  local drop="$1" t; rm -rf "$SBX/minbin"; mkdir -p "$SBX/minbin"
  for t in bash sh cat grep sed sort cut tail head find mktemp rm id sleep dirname basename awk chmod cp ls printf pgrep; do
    [ "$t" = "$drop" ] && continue
    [ -x "/usr/bin/$t" ] && ln -sf "/usr/bin/$t" "$SBX/minbin/$t"
    [ -x "/bin/$t" ]     && ln -sf "/bin/$t"     "$SBX/minbin/$t"
  done
}

# ---------------------------------------------------------------- case scaffolding
# c <name> honours the name filter and opens the case; sets CASEDIR (workdir), LOG, PROMPT.
# Configure a case by setting STUB_* / PROMPT_TEXT / CASE_ENV before calling `dispatch`,
# which then sets RC, OUT, ERR.
CASE=""; PROMPT_TEXT=""; CASE_ENV=""; N=0
c() { case "$1" in *"$FILTER"*) new_case "$1"; return 0 ;; esac; return 1; }
new_case() {
  CASE="$1"; N=$((N + 1))
  CASEDIR="$SBX/case-$(printf '%03d' "$N")"
  LOG="$CASEDIR/log"; mkdir -p "$LOG" "$CASEDIR/cwd" "$CASEDIR/work"
  PROMPT="$CASEDIR/prompt.txt"
  printf '%s\n' "${PROMPT_TEXT:-CRITIQUE THIS SPEC: the widget cache has no TTL.}" >"$PROMPT"
  CASE_ENV=""
  unset STUB_OUT STUB_OUT_FILE STUB_RC STUB_CATALOG STUB_MODELS_RC STUB_TOUCH STUB_SLEEP
  stub_pgrep_none
}
dispatch() {  # dispatch <args...> — runs the dispatcher from a neutral cwd with the sandboxed PATH
  OUT="$CASEDIR/stdout"; ERR="$CASEDIR/stderr"
  ( cd "$CASEDIR/cwd" || exit 99
    export PATH="$BIN:$BASE_PATH" STUB_LOG="$LOG"
    [ -n "$CASE_ENV" ] && eval "export $CASE_ENV"
    exec bash "$DISPATCH" "$@" >"$OUT" 2>"$ERR" </dev/null )
  RC=$?
  # Global invariant: a printed CRITIQUE_EXIT marker ALWAYS means the process exited 0.
  if grep -q '^CRITIQUE_EXIT:' "$OUT" && [ "$RC" -ne 0 ]; then
    CASE_ERR="${CASE_ERR:+$CASE_ERR; }INVARIANT: printed CRITIQUE_EXIT but exited $RC"
  fi
}

_fail() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$CASE"); printf '  \033[31mFAIL\033[0m %s\n        %s\n' "$CASE" "$1"; }
_pass() { PASS=$((PASS + 1)); printf '  \033[32mok\033[0m   %s\n' "$CASE"; }
# check <desc> <predicate...> — accumulates; verdict() closes the case
CASE_ERR=""
check() { local desc="$1"; shift; if "$@"; then :; else CASE_ERR="${CASE_ERR:+$CASE_ERR; }$desc"; fi; }
not()   { ! "$@"; }   # for `check "..." not <predicate> …`
verdict() { if [ -n "$CASE_ERR" ]; then _fail "$CASE_ERR (rc=$RC, stdout=$(head -c 200 "$OUT" | tr '\n' '|'), stderr=$(head -c 200 "$ERR" | tr '\n' '|'))"; else _pass; fi; CASE_ERR=""; }

rc_is()        { [ "$RC" = "$1" ]; }
rc_nonzero()   { [ "$RC" -ne 0 ]; }
out_has()      { grep -qF -- "$1" "$OUT"; }
out_lacks()    { ! grep -qF -- "$1" "$OUT"; }
out_last_is()  { [ "$(tail -1 "$OUT")" = "$1" ]; }
out_bigger_than() { [ "$(wc -c <"$OUT")" -ge "$1" ]; }
err_has()      { grep -qF -- "$1" "$ERR"; }
argv_has()     { grep -qxF -- "$2" "$LOG/$1.argv" 2>/dev/null; }
argv_lacks()   { ! grep -qF -- "$2" "$LOG/$1.argv" 2>/dev/null; }
# whole-argument absence: "-c" is a substring of "--skip-git-repo-check", so flags need exact matching
argv_lacks_flag() { ! grep -qxF -- "$2" "$LOG/$1.argv" 2>/dev/null; }
argv_after()   { # argv_after <cli> <flag> <expected-next-value>
  # p==2 means a value was actually examined; a flag that is the LAST argument leaves p==1 and must
  # fail, or an assertion would pass on a flag with no value after it.
  awk -v f="$2" -v v="$3" 'p==1{p=2; exit ($0==v)?0:1} $0==f{p=1} END{if(p!=2) exit 1}' "$LOG/$1.argv" 2>/dev/null; }
argv_after_glob() {  # argv_after_glob <cli> <flag> <glob for the next value>
  local v; v="$(awk -v f="$2" 'p==1{print; exit} $0==f{p=1}' "$LOG/$1.argv" 2>/dev/null)"
  [ -n "$v" ] || return 1
  # shellcheck disable=SC2254   # $3 is a glob on purpose
  case "$v" in $3) return 0 ;; esac; return 1; }
stdin_has()    { grep -qF -- "$2" "$LOG/$1.stdin" 2>/dev/null; }
pwd_is()       { [ "$(cat "$LOG/$1.pwd" 2>/dev/null)" = "$2" ]; }
no_file()      { [ ! -e "$1" ]; }
# shellcheck disable=SC2206   # unquoted on purpose: expands the glob
no_glob()      { local m; m=( $1 ); [ ! -e "${m[0]}" ]; }
no_new_files() { [ -z "$(find "$1" -mindepth 1 2>/dev/null)" ]; }

skip() { SKIP=$((SKIP + 1)); printf '  \033[33mskip\033[0m %s (%s)\n' "$CASE" "$1"; }
group() { printf '\n\033[1m%s\033[0m\n' "$1"; }
want()  { case "$CASE" in *"$FILTER"*) return 0 ;; esac; return 1; }   # honours the name filter

# shellcheck disable=SC2034   # consumed by cases.sh (sourced below)
CATALOG='opencode-go/kimi-k2
opencode-go/kimi-k3
opencode-go/glm-4.6
opencode-go/glm-5.2
opencode-go/glm-10.1
opencode-go/deepseek-v3.2
opencode-go/qwen3-max
opencode-go/minimax-m2
anthropic/claude-sonnet-4-5
zhipu/glm-5.2'

source "$HERE/cases.sh"

printf '\n\033[1mhermetic: %d passed, %d failed, %d skipped\033[0m\n' "$PASS" "$FAIL" "$SKIP"
if [ "$FAIL" -gt 0 ]; then printf 'failed: %s\n' "${FAILED_NAMES[*]}"; echo "sandbox kept: $SBX"; exit 1; fi
rm -rf "$SBX"
exit 0
