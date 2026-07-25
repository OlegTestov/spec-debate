#!/usr/bin/env bash
# Generic stub for codex / opencode / claude, dispatched on its own basename. Records what the
# dispatcher passed it (argv, stdin, cwd) and replays a scripted result, so run_critique.sh can be
# tested without a network, a provider account, or a model call.
#
#   STUB_LOG        dir for the recordings: <name>.{argv,stdin,pwd}
#   STUB_OUT        stdout to print (or STUB_OUT_FILE to print a file's contents)
#   STUB_RC         exit code (default 0)
#   STUB_CATALOG    `opencode models` output
#   STUB_MODELS_RC  exit code for `opencode models` (default 0)
#   STUB_TOUCH      relative filename to create in the CWD — probes where the reviewer may write
#   STUB_SLEEP      sleep this long before exiting (for the one-at-a-time guard case)
set -u
name="$(basename "$0")"
log="${STUB_LOG:?stub needs STUB_LOG}"
mkdir -p "$log"
printf '%s\n' "$@" >"$log/$name.argv"
pwd >"$log/$name.pwd"

# `opencode models` is a catalog query: no stdin is attached, so never read it here.
if [ "$name" = opencode ] && [ "${1:-}" = models ]; then
  [ -n "${STUB_CATALOG:-}" ] && printf '%s\n' "$STUB_CATALOG"
  exit "${STUB_MODELS_RC:-0}"
fi

# Anything that is not a critique invocation is an auth/status probe (`codex login status`,
# `claude --version`, …). Answer plausibly and record nothing: replying with a canned critique both
# derails the caller and makes "the reviewer ran" indistinguishable from "the CLI was inspected".
is_run=0
for a in "$@"; do
  case "$name:$a" in codex:exec|opencode:run|claude:-p) is_run=1 ;; esac
done
if [ "$is_run" = 0 ]; then
  printf '%s\n' "${STUB_STATUS:-stub $name: logged in}"
  exit "${STUB_STATUS_RC:-0}"
fi

cat >"$log/$name.stdin"                       # the dispatcher always redirects a file: EOF is safe
[ -n "${STUB_SLEEP:-}" ] && sleep "$STUB_SLEEP"
[ -n "${STUB_TOUCH:-}" ] && : >"$STUB_TOUCH"  # lands in whatever CWD the dispatcher chose
if [ -n "${STUB_OUT_FILE:-}" ]; then cat "$STUB_OUT_FILE"; else printf '%s' "${STUB_OUT-}"; fi
exit "${STUB_RC:-0}"
