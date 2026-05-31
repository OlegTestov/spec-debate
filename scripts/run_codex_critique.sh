#!/usr/bin/env bash
# run_codex_critique.sh — run a single OpenAI Codex critique pass, robustly.
#
# Usage: run_codex_critique.sh <prompt_file> [effort] [workdir]
#   prompt_file : path to a file containing the full prompt (ТЗ embedded inside)
#   effort      : model_reasoning_effort — high (default) | medium | low | xhigh
#   workdir     : sandbox root for codex (-C). Defaults to the prompt file's dir.
#
# Why this script exists:
#   - Concurrent `codex exec` processes HANG (observed empirically). We refuse to
#     start a second one rather than deadlock. One debate = one codex at a time.
#   - codex is sandboxed to -C and CANNOT read files outside it, so the caller
#     must embed the full ТЗ text in the prompt file. workdir only matters if the
#     ТЗ references in-repo source files codex may want to read (read-only).
#
# Output: on a normal run, codex's stdout (the critique) then a final line "CODEX_EXIT:<n>";
#         codex's stderr goes to a private mktemp file, is printed inline (to this script's
#         stderr) on non-zero exit, and the temp file is always removed via a trap. Preflight
#         failures (bad args, codex/pgrep missing, etc.) exit early with an "ERROR:" line and a
#         non-zero status, without a CODEX_EXIT marker.

set -uo pipefail

PROMPT_FILE="${1:?usage: run_codex_critique.sh <prompt_file> [effort] [workdir]}"
EFFORT="${2:-high}"
WORKDIR="${3:-$(dirname "$PROMPT_FILE")}"

case "$EFFORT" in
  high|medium|low|xhigh) ;;
  *) echo "ERROR: invalid effort '$EFFORT' (use: high|medium|low|xhigh)." >&2; exit 5 ;;
esac

if ! command -v codex >/dev/null 2>&1; then
  echo "ERROR: codex CLI not found. Install: npm install -g @openai/codex" >&2
  exit 2
fi

if ! command -v pgrep >/dev/null 2>&1; then
  echo "ERROR: pgrep not found; cannot enforce one-codex-at-a-time (fail-closed)." >&2
  echo "       Install procps (Linux) or use a shell that provides pgrep (macOS has it)." >&2
  exit 7
fi

# Anchor the pattern to a real invocation: "codex exec" at the start of the command line or right
# after a path slash (`/…/codex exec`). A bare substring match (-f "codex exec") false-positives on
# ANY process whose argv merely mentions the string — e.g. an editor, a `ps|grep "codex exec"`, or a
# `claude -p …` agent carrying a summary about this very skill — and would wrongly block the run.
if pgrep -u "$(id -u)" -f '(^|/)codex exec' >/dev/null 2>&1; then
  echo "ERROR: another 'codex exec' is already running for this user. Concurrent codex runs hang." >&2
  echo "       Inspect it with: ps -ax -o pid=,command= | grep -E '(^|/)[c]odex exec'  (kill it only if it's your own stray run)." >&2
  exit 3
fi

if [ ! -r "$PROMPT_FILE" ]; then
  echo "ERROR: prompt file not found or not readable: $PROMPT_FILE" >&2
  exit 4
fi

if [ ! -d "$WORKDIR" ]; then
  echo "ERROR: workdir not found: $WORKDIR" >&2
  exit 6
fi

ERR_FILE="$(mktemp "${TMPDIR:-/tmp}/spec-debate-codex.XXXXXX")"  # trailing X's: portable BSD+GNU
trap 'rm -f "$ERR_FILE"' EXIT  # never leave the temp stderr file behind

# Feed the prompt to codex via STDIN, not as an argv arg. `codex exec` reads instructions from
# stdin when the prompt argument is `-` (see `codex exec --help`). This keeps the full document
# OFF the command line: no OS arg-length (ARG_MAX) limit on large specs, and the document is not
# exposed in the process list (ps / /proc) to other local users. The file provides EOF, so the
# run terminates cleanly — the old hang ("Reading additional input from stdin...") came from
# passing the doc on argv while an *open, idle* stdin was attached, which is a different case.
codex exec \
  --skip-git-repo-check \
  -C "$WORKDIR" \
  -s read-only \
  -c "model_reasoning_effort=\"$EFFORT\"" \
  - \
  <"$PROMPT_FILE" \
  2>"$ERR_FILE"
status=$?

# Keep stdout (the critique) clean; surface stderr only when the run actually failed.
if [ "$status" -ne 0 ]; then
  echo "----- codex stderr (exit $status) -----" >&2
  cat "$ERR_FILE" >&2
fi
echo "CODEX_EXIT:$status"
