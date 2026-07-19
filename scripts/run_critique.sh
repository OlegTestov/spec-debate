#!/usr/bin/env bash
# run_critique.sh <harness> <prompt_file> [effort] [workdir] [model]
#
# Unified reviewer-critique runner for spec-debate. One entry point for all harnesses so SKILL.md
# stays harness-agnostic. stdout = the critique, then a final line `CRITIQUE_EXIT:<n>`.
#
#   harness : codex | opencode | claude
#   effort  : low | medium | high | max   (default high; "xhigh" accepted as an alias for max)
#   workdir : dir the reviewer may read (read-only); default = the prompt file's dir
#   model   : optional. For opencode: a full `provider/model` id, or a family name (kimi/glm/…) that
#             is resolved to the newest available BASE version. For claude: a --model value. Ignored
#             for codex (it trusts its own default).
#
# The prompt is ALWAYS fed via STDIN (never argv): keeps the spec text off the process list and
# avoids ARG_MAX on large embeds. Preflight failures print an `ERROR:` line (no CRITIQUE_EXIT marker)
# and exit non-zero. The codex path delegates to the hardened `run_codex_critique.sh` UNCHANGED and
# normalizes its `CODEX_EXIT` marker to a single `CRITIQUE_EXIT`.
set -uo pipefail

HARNESS="${1:?usage: run_critique.sh <codex|opencode|claude> <prompt_file> [effort] [workdir] [model]}"
PROMPT_FILE="${2:?prompt_file required}"
EFFORT="${3:-high}"
WORKDIR="${4:-$(cd "$(dirname "$PROMPT_FILE")" 2>/dev/null && pwd)}"
MODEL="${5:-}"
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$EFFORT" in low|medium|high|max|xhigh) ;; *) echo "ERROR: invalid effort '$EFFORT' (low|medium|high|max)." >&2; exit 5 ;; esac
[ -r "$PROMPT_FILE" ] || { echo "ERROR: prompt file not readable: $PROMPT_FILE" >&2; exit 4; }
[ -d "$WORKDIR" ]     || { echo "ERROR: workdir not found: $WORKDIR" >&2; exit 6; }

# Newest BASE model of a family from `opencode models` output (drop -code/-flash/-pro/-max/-plus/-free
# variants, which are tiers not versions; version-sort the rest, take the top).
resolve_opencode_model() {
  local family="$1" models="$2"
  printf '%s\n' "$models" \
    | grep -iE "/${family}[-0-9k.]*$" \
    | grep -vE -- '-(code|flash|pro|max|plus|free)$' \
    | sort -V | tail -1
}

case "$HARNESS" in
  codex)
    command -v codex >/dev/null 2>&1 || { echo "ERROR: codex CLI not found. Install: npm i -g @openai/codex" >&2; exit 2; }
    [ "$EFFORT" = max ] && EFFORT=xhigh   # codex reasoning-effort vocab
    bash "$SKILL_DIR/run_codex_critique.sh" "$PROMPT_FILE" "$EFFORT" "$WORKDIR" \
      | sed 's/^CODEX_EXIT:\([0-9][0-9]*\)$/CRITIQUE_EXIT:\1/'
    exit "${PIPESTATUS[0]}"
    ;;

  opencode)
    command -v opencode >/dev/null 2>&1 || { echo "ERROR: opencode CLI not found." >&2; exit 2; }
    models="$(opencode models 2>/dev/null)"
    [ -n "$models" ] || { echo "ERROR: opencode has no configured models (run: opencode auth)." >&2; exit 2; }
    model="$MODEL"
    if [ -z "$model" ]; then
      model="$(resolve_opencode_model kimi "$models")"          # default: latest kimi
    elif [ "${model#*/}" = "$model" ]; then                     # a family name, not provider/model
      model="$(resolve_opencode_model "$model" "$models")"
    fi
    [ -n "$model" ] || { echo "ERROR: could not resolve an opencode model (family not in catalog)." >&2; exit 2; }
    case "$EFFORT" in low) variant=minimal ;; medium|high) variant=high ;; max|xhigh) variant=max ;; esac
    # opencode's default agent is NOT sandboxed read-only (it can edit). The critique prompt never asks
    # for edits and the context is embedded, so isolate it to the prompt file's dir — never the user's
    # repo — as defense-in-depth.
    oc_dir="$(cd "$(dirname "$PROMPT_FILE")" && pwd)"
    err="$(mktemp "${TMPDIR:-/tmp}/spec-debate-oc.XXXXXX")"; trap 'rm -f "$err"' EXIT
    opencode run -m "$model" --variant "$variant" --dir "$oc_dir" < "$PROMPT_FILE" 2>"$err"; code=$?
    [ "$code" -ne 0 ] && { echo "----- opencode stderr (exit $code, model $model) -----" >&2; cat "$err" >&2; }
    echo "CRITIQUE_EXIT:$code"
    ;;

  claude)
    command -v claude >/dev/null 2>&1 || { echo "ERROR: claude CLI not found." >&2; exit 2; }
    err="$(mktemp "${TMPDIR:-/tmp}/spec-debate-cl.XXXXXX")"; trap 'rm -f "$err"' EXIT
    # Fresh instance, non-editing (plan) mode, prompt via stdin. Omit --model to inherit the
    # orchestrator's default; pass one only if a specific claude model was named.
    ( cd "$WORKDIR" && claude -p --permission-mode plan ${MODEL:+--model "$MODEL"} < "$PROMPT_FILE" ) 2>"$err"; code=$?
    [ "$code" -ne 0 ] && { echo "----- claude stderr (exit $code) -----" >&2; cat "$err" >&2; }
    echo "CRITIQUE_EXIT:$code"
    ;;

  *)
    echo "ERROR: unknown harness '$HARNESS' (use codex|opencode|claude)." >&2; exit 5 ;;
esac
