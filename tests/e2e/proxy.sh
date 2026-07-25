#!/usr/bin/env bash
# Recording proxy for a real reviewer CLI: captures the exact argv and the exact prompt bytes, then
# runs the real binary unchanged. Used by the quality suite, where the critique must be real but we
# still need to assert WHAT was sent (e.g. privacy mode must not leak source code or secrets).
#
#   PROXY_LOG    dir for <name>-<n>.{argv,stdin}
#   REAL_<name>  absolute path to the real binary (e.g. REAL_codex=/opt/homebrew/bin/codex)
set -uo pipefail
name="$(basename "$0")"
log="${PROXY_LOG:?proxy needs PROXY_LOG}"; mkdir -p "$log"
i=1; while [ -e "$log/$name-$i.argv" ]; do i=$((i + 1)); done
printf '%s\n' "$@" >"$log/$name-$i.argv"
var="REAL_$name"; real="${!var:?proxy needs $var}"
tee "$log/$name-$i.stdin" | "$real" "$@"
exit "${PIPESTATUS[1]}"
