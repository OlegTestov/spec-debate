#!/usr/bin/env bash
# run_critique.sh <harness> <prompt_file> [effort] [workdir] [model]
#
# Unified reviewer-critique runner for spec-debate. One entry point for all harnesses so SKILL.md
# stays harness-agnostic. stdout = the critique, then a final line `CRITIQUE_EXIT:<n>`.
#
#   harness : codex | opencode | claude
#   effort  : low | medium | high | max   (default high; "xhigh" accepted as an alias for max)
#   workdir : dir the reviewer may read (read-only). codex = sandbox root; claude = cwd; opencode
#             ignores it (runs in a throwaway temp dir). Default = the prompt file's dir.
#   model   : optional. For opencode: a full `provider/model` id, or a family name (kimi/glm/…)
#             resolved to the newest version in the catalog. For claude: a --model value. Ignored
#             for codex (it trusts its own default).
#
# The prompt is ALWAYS fed via STDIN (never argv): keeps the spec text off the process list and
# avoids ARG_MAX on large embeds. Preflight failures print an `ERROR:` line (no CRITIQUE_EXIT marker)
# and exit non-zero. A printed `CRITIQUE_EXIT:<n>` line ALWAYS means the dispatcher process exits 0.
# The codex path delegates to the hardened `run_codex_critique.sh` UNCHANGED and normalizes its
# `CODEX_EXIT` marker to a single `CRITIQUE_EXIT`.
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

# Newest version of an opencode model FAMILY (e.g. kimi -> opencode-go/kimi-k3). Matched by basename
# with a shell GLOB, not a regex — so a stray "." in the family can't match everything — and no tier
# is preferred: "latest" = highest version by basename, provider is only a deterministic tie-break.
resolve_opencode_model() {
  local family="$1" models="$2" id base
  printf '%s\n' "$models" | while IFS= read -r id; do
    base="${id##*/}"
    case "$base" in "$family"|"$family"[-.0-9]*) printf '%s\t%s\n' "$base" "$id" ;; esac
  done | sort -V -k1,1 | tail -1 | cut -f2-
}

# Emit a harness result: replay stdout verbatim, then exactly one CRITIQUE_EXIT marker (the process
# stays exit 0). A ZERO exit with empty/whitespace-only output is a SILENT failure (a provider error,
# a rejected permission) masquerading as "no findings" — surface it as CRITIQUE_EXIT:1, never consensus.
emit_result() {  # <exit_code> <stdout_file> <stderr_file> <label>
  local code="$1" out="$2" err="$3" label="$4"
  if [ "$code" -eq 0 ] && ! grep -q '[^[:space:]]' "$out"; then
    echo "ERROR-EMPTY: $label exited 0 with no output — treating as a failure, not consensus." >&2
    [ -s "$err" ] && { echo "----- $label stderr -----" >&2; cat "$err" >&2; }
    echo "CRITIQUE_EXIT:1"; return
  fi
  cat "$out"
  [ "$code" -ne 0 ] && { echo "----- $label stderr (exit $code) -----" >&2; cat "$err" >&2; }
  echo "CRITIQUE_EXIT:$code"
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
      model="$(resolve_opencode_model kimi "$models")"                       # default: latest kimi
      [ -n "$model" ] || { echo "ERROR: no kimi model in the opencode catalog." >&2; exit 2; }
    elif [ "${model#*/}" != "$model" ]; then                                 # explicit provider/model
      printf '%s\n' "$models" | grep -qxF "$model" || { echo "ERROR: opencode model '$model' not in catalog." >&2; exit 2; }
    else                                                                     # a family name
      model="$(resolve_opencode_model "$model" "$models")"
      [ -n "$model" ] || { echo "ERROR: opencode family '$MODEL' has no models in the catalog." >&2; exit 2; }
    fi
    # opencode's default agent is NOT sandboxed read-only. Run it in a THROWAWAY temp dir (never the
    # repo): context is embedded and the critique never asks for edits, so <workdir> is unused here.
    # opencode effort is coarse — minimal|high|max only (medium maps to high; an invalid variant is
    # silently ignored by opencode).
    case "$EFFORT" in low) variant=minimal ;; medium|high) variant=high ;; max|xhigh) variant=max ;; esac
    oc_dir="$(mktemp -d "${TMPDIR:-/tmp}/spec-debate-ocdir.XXXXXX")"
    out="$(mktemp "${TMPDIR:-/tmp}/spec-debate-oc.XXXXXX")"; err="$(mktemp "${TMPDIR:-/tmp}/spec-debate-oc.XXXXXX")"
    trap 'rm -rf "$oc_dir"; rm -f "$out" "$err"' EXIT
    opencode run -m "$model" --variant "$variant" --dir "$oc_dir" < "$PROMPT_FILE" >"$out" 2>"$err"; code=$?
    emit_result "$code" "$out" "$err" "opencode ($model)"
    ;;

  claude)
    command -v claude >/dev/null 2>&1 || { echo "ERROR: claude CLI not found." >&2; exit 2; }
    out="$(mktemp "${TMPDIR:-/tmp}/spec-debate-cl.XXXXXX")"; err="$(mktemp "${TMPDIR:-/tmp}/spec-debate-cl.XXXXXX")"
    trap 'rm -f "$out" "$err"' EXIT
    # Fresh instance, non-editing (plan) mode, and NO project/user MCP servers (a reviewer only needs
    # the embedded prompt — this keeps it off Jira/GitLab/etc.). Prompt via stdin; omit --model to
    # inherit the orchestrator's default.
    ( cd "$WORKDIR" && claude -p --permission-mode plan --strict-mcp-config --mcp-config '{"mcpServers":{}}' ${MODEL:+--model "$MODEL"} < "$PROMPT_FILE" ) >"$out" 2>"$err"; code=$?
    emit_result "$code" "$out" "$err" "claude reviewer"
    ;;

  *)
    echo "ERROR: unknown harness '$HARNESS' (use codex|opencode|claude)." >&2; exit 5 ;;
esac
