#!/usr/bin/env bash
# Recording proxy for a real reviewer CLI: captures the exact argv and the exact prompt bytes, then
# runs the real binary unchanged. Used by the quality suite, where the critique must be real but we
# still need to assert WHAT was sent (e.g. privacy mode must not leak source code or secrets).
#
#   PROXY_LOG    dir for <name>-<n>.{argv,stdin,stdout}
#   REAL_<name>  absolute path to the real binary (e.g. REAL_codex=/opt/homebrew/bin/codex)
set -uo pipefail
name="$(basename "$0")"
log="${PROXY_LOG:?proxy needs PROXY_LOG}"; mkdir -p "$log"
i=1; while [ -e "$log/$name-$i.argv" ]; do i=$((i + 1)); done
printf '%s\n' "$@" >"$log/$name-$i.argv"
var="REAL_$name"; real="${!var:?proxy needs $var}"

# Only a critique invocation is a "run". An auth/catalog probe (`codex login status`, `opencode models`)
# gets no stdin, so tee-ing it would block on an inherited descriptor — and the empty .stdin it left
# behind used to satisfy checks meant to prove the reviewer actually ran.
is_run=0
for a in "$@"; do
  case "$name:$a" in codex:exec|opencode:run|claude:-p) is_run=1 ;; esac
done
[ "$is_run" = 0 ] && exec "$real" "$@"

# Record the reply too, not just the prompt: a provider that refuses (out of balance, rate-limited)
# still receives a prompt, and "the reviewer was called" would otherwise read as "the reviewer answered".
tee "$log/$name-$i.stdin" | "$real" "$@" | tee "$log/$name-$i.stdout"
exit "${PIPESTATUS[1]}"
