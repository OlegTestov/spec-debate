#!/usr/bin/env bash
# run_codex_critique.sh — run a single OpenAI Codex critique pass, robustly.
#
# Usage: run_codex_critique.sh <prompt_file> [effort] [workdir] [model]
#   prompt_file : path to a file containing the full prompt (spec embedded inside,
#                 or referenced by exact in-workdir path with a read-in-full instruction)
#   effort      : model_reasoning_effort — high | medium | low | xhigh. EMPTY (the default) passes
#                 nothing, so codex resolves it from its own configuration: overriding an effort the
#                 caller never asked about would silently downgrade a user who configured a higher one.
#   model       : passed as -m. Empty (the default) leaves codex's configured model alone. Not
#                 validated here — an unknown model must fail loudly in codex, never fall back
#   workdir     : sandbox root for codex (-C). Defaults to the prompt file's dir.
#   env CODEX_MAX_WAIT_SECS : seconds to wait for a running codex to clear before refusing
#                 (default 5 — covers teardown overlap; 0 disables the wait). Raise it (e.g. 900)
#                 to WAIT for a concurrent run from another session/agent instead of exiting 3.
#
# Why this script exists:
#   - One `codex exec` at a time. The original deadlock came from passing the doc on
#     argv with an open, idle stdin (see the invocation note below); that is fixed by
#     feeding the prompt via stdin with EOF. The guard is kept as cheap defense-in-depth,
#     and it tolerates a just-finished codex still tearing down by polling briefly before
#     refusing. A genuinely concurrent run blocks by default; set CODEX_MAX_WAIT_SECS=<n>
#     to WAIT that many seconds for the slot to free (e.g. a run owned by another session)
#     instead of failing.
#   - codex is sandboxed to -C and CANNOT read files outside it, so the caller
#     must embed the full spec text in the prompt file — or, when the spec file
#     itself lives inside -C, reference it by exact path with a read-in-full
#     instruction. workdir matters when codex must read the spec or other
#     referenced files (read-only).
#
# Output: on a normal run, codex's stdout (the critique) then a final line "CODEX_EXIT:<n>";
#         codex's stderr goes to a private mktemp file, is printed inline (to this script's
#         stderr) on non-zero exit, and the temp file is always removed via a trap. Preflight
#         failures (bad args, codex/pgrep missing, etc.) exit early with an "ERROR:" line and a
#         non-zero status, without a CODEX_EXIT marker.

set -uo pipefail

PROMPT_FILE="${1:?usage: run_codex_critique.sh <prompt_file> [effort] [workdir] [model]}"
EFFORT="${2:-}"
WORKDIR="${3:-$(dirname "$PROMPT_FILE")}"
MODEL="${4:-}"

case "$EFFORT" in
  ""|high|medium|low|xhigh) ;;
  *) echo "ERROR: invalid effort '$EFFORT' (use: high|medium|low|xhigh, or empty to inherit)." >&2; exit 5 ;;
esac

if ! command -v codex >/dev/null 2>&1; then
  echo "ERROR: codex CLI not found. Install: npm install -g @openai/codex" >&2
  exit 2
fi

if ! command -v pgrep >/dev/null 2>&1; then
  echo "ERROR: pgrep not found; cannot enforce one-codex-at-a-time (fail-closed)." >&2
  echo "       macOS has it; on Linux install procps. On Windows use WSL2 — Git Bash ships no pgrep." >&2
  exit 7
fi

# Match a real Codex invocation: "codex" at the start of the command line or right after a path slash,
# with "exec" as the following token — so `codex exec`, `/…/codex exec`, and versioned/wrapper binaries
# (`/…/codex-<triple> exec`, `…/codex.js exec`) all count. This REDUCES, but cannot fully eliminate,
# false positives: a bare substring match (-f "codex exec") trips on ANY process whose argv merely
# mentions the string (an editor, a `ps|grep`, a `claude -p …` agent carrying a summary about this very
# skill); the bounded form excludes those — though a prose mention containing a real `/path/codex exec`
# can still match. pgrep -f matches the raw argv, so the boundaries work there.
# Distinguish pgrep's exit codes: 0 = a match (a codex exec is running), 1 = no match,
# anything else = pgrep itself failed (e.g. cannot read the process list) → fail closed.
codex_exec_running() {  # 0 = one is running, 1 = none, 2 = pgrep failed
  local s=0
  pgrep -u "$(id -u)" -f '(^|/)codex([^/[:space:]]*)? exec([[:space:]]|$)' >/dev/null 2>&1 || s=$?
  case "$s" in 0) return 0 ;; 1) return 1 ;; *) return 2 ;; esac
}

# A match may be the PRIOR step's codex still tearing down rather than a genuine concurrent
# run (e.g. critique → cross-critique back-to-back), OR a run owned by another session/agent.
# Poll for the slot to clear before refusing. CODEX_MAX_WAIT_SECS caps the wait (default 5s —
# covers a teardown overlap); raise it (e.g. 900) to WAIT for a concurrent run to finish so the
# debate self-recovers instead of erroring. Poll interval is 0.5s.
MAX_WAIT_SECS="${CODEX_MAX_WAIT_SECS:-5}"
case "$MAX_WAIT_SECS" in
  ''|*[!0-9]*) echo "ERROR: CODEX_MAX_WAIT_SECS must be a non-negative integer (seconds); got '$MAX_WAIT_SECS'." >&2; exit 5 ;;
esac
max_polls=$((10#$MAX_WAIT_SECS * 2))  # 0.5s per poll; 10# forces base-10 (a leading-zero value like 08/010 must not be read as octal)

codex_exec_running; guard_rc=$?
guard_polls=0
while [ "$guard_rc" -eq 0 ] && [ "$guard_polls" -lt "$max_polls" ]; do
  sleep 0.5
  guard_polls=$((guard_polls + 1))
  codex_exec_running; guard_rc=$?
done
case "$guard_rc" in
  0)
    echo "ERROR: another 'codex exec' is still running for this user after ${MAX_WAIT_SECS}s. Concurrent codex runs can hang." >&2
    echo "       To WAIT for it (e.g. a run owned by another session) instead of failing, re-run with CODEX_MAX_WAIT_SECS=<seconds> (e.g. 900), and raise the caller's timeout to match." >&2
    # The inspection hint is a LOOSE substring on purpose: `ps` prefixes each line with the PID, so the
    # bounded guard pattern misses the bare `<pid> codex exec` form in ps output. A human reading the
    # result can tell a real codex from a process that merely mentions the string, so loose is right here.
    echo "       Inspect it with: ps -ax -o pid=,command= | grep '[c]odex exec'  (kill it only if it's your own stray run)." >&2
    exit 3 ;;
  1) ;;  # clear (or cleared during the poll) — proceed
  *)
    echo "ERROR: pgrep failed; cannot enforce one-codex-at-a-time (fail-closed)." >&2
    exit 7 ;;
esac

if [ ! -r "$PROMPT_FILE" ]; then
  echo "ERROR: prompt file not found or not readable: $PROMPT_FILE" >&2
  exit 4
fi

if [ ! -d "$WORKDIR" ]; then
  echo "ERROR: workdir not found: $WORKDIR" >&2
  exit 6
fi

ERR_FILE="$(mktemp "${TMPDIR:-/tmp}/spec-debate-codex.XXXXXX")"  # trailing X's: portable BSD+GNU
OUT_FILE="$(mktemp "${TMPDIR:-/tmp}/spec-debate-codex.XXXXXX")"
trap 'rm -f "$ERR_FILE" "$OUT_FILE"' EXIT  # never leave the temp files behind

# Feed the prompt to codex via STDIN, not as an argv arg. `codex exec` reads instructions from
# stdin when the prompt argument is `-` (see `codex exec --help`). This keeps the full document
# OFF the command line: no OS arg-length (ARG_MAX) limit on large specs, and the document is not
# exposed in the process list (ps / /proc) to other local users. The file provides EOF, so the
# run terminates cleanly — the old hang ("Reading additional input from stdin...") came from
# passing the doc on argv while an *open, idle* stdin was attached, which is a different case.
# Only what was asked for. -c and -m override the user's own codex configuration, so they go in
# solely on request; the sandbox, the workdir and the stdin sentinel are ours by design and always set.
# (`${arr[@]+"${arr[@]}"}` is the bash 3.2-safe way to expand a possibly-empty array under `set -u`.)
opts=()
[ -n "$EFFORT" ] && opts+=(-c "model_reasoning_effort=\"$EFFORT\"")
[ -n "$MODEL" ]  && opts+=(-m "$MODEL")
codex exec \
  --skip-git-repo-check \
  -C "$WORKDIR" \
  -s read-only \
  ${opts[@]+"${opts[@]}"} \
  - \
  <"$PROMPT_FILE" \
  >"$OUT_FILE" \
  2>"$ERR_FILE"
status=$?

cat "$OUT_FILE"
# The marker must be its OWN line. codex's stdout is buffered to a file (instead of streamed) purely
# so this is checkable: without the guard, output ending mid-line glues the marker onto it
# ("...no TTL.CODEX_EXIT:0"), and the caller's anchored match then finds no marker at all.
[ -n "$(tail -c1 "$OUT_FILE")" ] && echo

# Keep stdout (the critique) clean; surface stderr only when the run actually failed.
if [ "$status" -ne 0 ]; then
  echo "----- codex stderr (exit $status) -----" >&2
  cat "$ERR_FILE" >&2
fi
echo "CODEX_EXIT:$status"
