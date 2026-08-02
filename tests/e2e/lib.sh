# shellcheck shell=bash
# Shared setup for the e2e suites. The candidate plugin build lives here because it was duplicated in
# three runners, and a bug in it is invisible: a session that starts with an empty plugin reports every
# must-fire case as "quiet" and every quality scenario as a bad result, with no error anywhere.

# Where run output goes. Outside the repo by default: a dir INSIDE the repo used to be copied into the
# candidate by `cp -R "$REPO"` — GNU cp refuses that outright ("cannot copy a directory into itself"),
# and BSD cp silently dragged previous runs' recorded prompts into the candidate.
default_art() {  # default_art <suite-name>
  mktemp -d "${TMPDIR:-/tmp}/spec-debate-$1.XXXXXX"
}

# Build a session-only plugin holding just the candidate skill. Copies the SHIPPED files by name — not
# the repo — so no test artifact can ever end up inside, and verifies the result instead of trusting cp.
build_candidate_plugin() {  # build_candidate_plugin <repo> <plugin-dir>
  local repo="$1" plug="$2" dest="$2/skills/spec-debate" item
  mkdir -p "$plug/.claude-plugin" "$dest"
  for item in SKILL.md README.md README_ru.md LICENSE scripts evals; do
    [ -e "$repo/$item" ] || continue
    cp -R "$repo/$item" "$dest/" || { echo "FATAL: could not copy $item into the candidate" >&2; exit 2; }
  done
  printf '{ "name": "spec-debate-candidate", "version": "1.1.0", "description": "spec-debate under test" }\n' \
    >"$plug/.claude-plugin/plugin.json"
  # Fail loudly here rather than let every case come back "quiet".
  for item in SKILL.md scripts/run_critique.sh scripts/run_codex_critique.sh; do
    [ -r "$dest/$item" ] || { echo "FATAL: candidate is missing $item — the run would be meaningless" >&2; exit 2; }
  done
}

# Reviewer CLIs replaced by the recording stub (routing questions) — see tests/hermetic/stub.sh.
install_stub_clis() {  # install_stub_clis <repo> <bin-dir> <names...>
  local repo="$1" bin="$2"; shift 2
  mkdir -p "$bin"
  local n
  for n in "$@"; do cp "$repo/tests/hermetic/stub.sh" "$bin/$n"; chmod +x "$bin/$n"; done
}
