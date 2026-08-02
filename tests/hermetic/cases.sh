# shellcheck shell=bash
# shellcheck disable=SC2034   # RC/OUT/ERR are read by the assert helpers in run.sh
# Cases for tests/hermetic/run.sh — sourced, not run directly. Every case: `c <name> && { ... }`.
# Naming matters: the first word is the group, and `run.sh <substring>` filters on the whole name.

# ------------------------------------------------------------------ contract / arguments
group "contract"

c "contract: no args → usage error, no marker" && {
  install_stub codex opencode claude; dispatch
  check "rc nonzero" rc_nonzero; check "no CRITIQUE_EXIT" out_lacks "CRITIQUE_EXIT"; verdict; }

c "contract: harness without prompt file → error" && {
  dispatch codex
  check "rc nonzero" rc_nonzero; check "no marker" out_lacks "CRITIQUE_EXIT"; verdict; }

c "contract: unknown harness → exit 5" && {
  dispatch gpt5 "$PROMPT"
  check "rc 5" rc_is 5; check "names the valid set" err_has "codex|opencode|claude"; verdict; }

c "contract: prompt file missing → exit 4" && {
  dispatch codex "$CASEDIR/nope.txt"
  check "rc 4" rc_is 4; check "says not readable" err_has "prompt file not readable"; verdict; }

c "contract: prompt file unreadable → exit 4" && {
  # chmod cannot hide a file from root, which is who runs CI containers — skip rather than assert a
  # permission model the environment does not have.
  if [ "$(id -u)" = 0 ]; then skip "running as root: chmod 000 leaves the file readable"; else
    chmod 000 "$PROMPT"; dispatch codex "$PROMPT"; chmod 644 "$PROMPT"
    check "rc 4" rc_is 4; verdict
  fi; }

c "contract: unreadable prompt path (dangling symlink) → exit 4" && {
  # Same branch as above, but unreadable for root too — so CI covers it.
  ln -s "$CASEDIR/no-such-target" "$CASEDIR/dangling.txt"
  dispatch codex "$CASEDIR/dangling.txt"
  check "rc 4" rc_is 4; check "says not readable" err_has "prompt file not readable"; verdict; }

c "contract: invalid effort → exit 5" && {
  dispatch codex "$PROMPT" ultra
  check "rc 5" rc_is 5; check "lists valid efforts" err_has "low|medium|high|max"; verdict; }

c "contract: workdir not found → exit 6" && {
  dispatch codex "$PROMPT" high "$CASEDIR/no-such-dir"
  check "rc 6" rc_is 6; check "says workdir" err_has "workdir not found"; verdict; }

c "contract: default workdir is the prompt file's dir" && {
  install_stub codex; STUB_OUT="ok"; dispatch codex "$PROMPT"
  check "codex -C <promptdir>" argv_after codex "-C" "$CASEDIR"; verdict; }

c "contract: prompt path with spaces works" && {
  install_stub opencode; mv "$PROMPT" "$CASEDIR/my spec prompt.txt"; PROMPT="$CASEDIR/my spec prompt.txt"
  STUB_CATALOG="$CATALOG" STUB_OUT="finding one" dispatch opencode "$PROMPT"
  check "rc 0" rc_is 0; check "marker 0" out_last_is "CRITIQUE_EXIT:0"; verdict; }

c "contract: workdir with spaces works" && {
  install_stub claude; mkdir -p "$CASEDIR/my work dir"
  STUB_OUT="finding" dispatch claude "$PROMPT" high "$CASEDIR/my work dir"
  check "rc 0" rc_is 0; check "cwd is the spaced workdir" pwd_is claude "$CASEDIR/my work dir"; verdict; }

# ------------------------------------------------------------------ codex path
group "codex"

c "codex: CLI missing → exit 2 with install hint" && {
  clear_stubs; dispatch codex "$PROMPT"
  check "rc 2" rc_is 2; check "install hint" err_has "npm"; verdict; }

c "codex: happy path → CODEX_EXIT normalized to CRITIQUE_EXIT:0" && {
  install_stub codex; STUB_OUT='1. No TTL on the cache.
2. No idempotency key.' dispatch codex "$PROMPT"
  check "rc 0" rc_is 0; check "critique replayed" out_has "No idempotency key"
  check "marker last" out_last_is "CRITIQUE_EXIT:0"; check "no CODEX_EXIT leak" out_lacks "CODEX_EXIT"; verdict; }

c "codex: reviewer failure → CRITIQUE_EXIT:7, process still exits 0" && {
  install_stub codex; STUB_RC=7 STUB_OUT="partial" dispatch codex "$PROMPT"
  check "rc 0 (marker contract)" rc_is 0; check "marker 7" out_last_is "CRITIQUE_EXIT:7"; verdict; }

c "codex: zero exit with empty output is a failure, not consensus" && {
  # The guard the other harnesses have: an empty critique at exit 0 is a failed pass (provider error,
  # rejected permission), never agreement. The codex path must not be the exception.
  install_stub codex; STUB_OUT="" STUB_RC=0 dispatch codex "$PROMPT"
  check "rc 0 (marker contract)" rc_is 0; check "marker 1" out_last_is "CRITIQUE_EXIT:1"
  check "explains on stderr" err_has "ERROR-EMPTY"; verdict; }

c "codex: effort max maps to xhigh" && {
  install_stub codex; STUB_OUT=x dispatch codex "$PROMPT" max
  check "xhigh passed to codex" argv_has codex 'model_reasoning_effort="xhigh"'; verdict; }

c "codex: an explicit high is still passed as high" && {
  install_stub codex; STUB_OUT=x dispatch codex "$PROMPT" high
  check "high passed to codex" argv_has codex 'model_reasoning_effort="high"'; verdict; }

c "codex: no effort requested → no -c, so the user's own config decides" && {
  # Forcing a default here would silently downgrade anyone who configured a higher effort.
  install_stub codex; STUB_OUT=x dispatch codex "$PROMPT"
  check "no reasoning-effort override" argv_lacks codex "model_reasoning_effort"
  check "no -c at all" argv_lacks_flag codex "-c"
  check "still ran" out_last_is "CRITIQUE_EXIT:0"; verdict; }

c "codex: no model requested → no -m, so the configured model stands" && {
  install_stub codex; STUB_OUT=x dispatch codex "$PROMPT"
  check "no -m" argv_lacks_flag codex "-m"; verdict; }

c "codex: a named model is passed through unvalidated" && {
  install_stub codex; STUB_OUT=x dispatch codex "$PROMPT" "" "" gpt-5.4-mini
  check "-m gpt-5.4-mini" argv_after codex "-m" "gpt-5.4-mini"; verdict; }

c "codex: effort xhigh alias accepted" && {
  install_stub codex; STUB_OUT=x dispatch codex "$PROMPT" xhigh
  check "rc 0" rc_is 0; check "xhigh passed" argv_has codex 'model_reasoning_effort="xhigh"'; verdict; }

c "codex: read-only sandbox and git-check skip are set" && {
  install_stub codex; STUB_OUT=x dispatch codex "$PROMPT"
  check "-s read-only" argv_after codex "-s" "read-only"
  check "--skip-git-repo-check" argv_has codex "--skip-git-repo-check"; verdict; }

c "codex: prompt goes over stdin, never argv" && {
  PROMPT_TEXT="SECRET-SPEC-TOKEN-Q7 the cache has no TTL"; install_stub codex; new_case "$CASE"
  STUB_OUT=x dispatch codex "$PROMPT"
  check "stdin carries the spec" stdin_has codex "SECRET-SPEC-TOKEN-Q7"
  check "argv does not" argv_lacks codex "SECRET-SPEC-TOKEN-Q7"
  check "argv uses the - sentinel" argv_has codex "-"; verdict; PROMPT_TEXT=""; }

c "codex: one-at-a-time guard refuses a concurrent run → exit 3" && {
  install_stub codex; use_real_pgrep
  ( export PATH="$BIN:$BASE_PATH" STUB_LOG="$LOG/bg" STUB_SLEEP=4 STUB_OUT=bg; \
    "$BIN/codex" exec --background-probe >/dev/null 2>&1 </dev/null & ) ; sleep 0.4
  CASE_ENV="CODEX_MAX_WAIT_SECS=1" STUB_OUT=x dispatch codex "$PROMPT"
  check "rc 3" rc_is 3; check "explains the guard" err_has "another 'codex exec' is still running"
  check "no marker" out_lacks "CRITIQUE_EXIT"; verdict; wait 2>/dev/null; }

c "codex: invalid CODEX_MAX_WAIT_SECS → exit 5" && {
  install_stub codex; CASE_ENV="CODEX_MAX_WAIT_SECS=abc" STUB_OUT=x dispatch codex "$PROMPT"
  check "rc 5" rc_is 5; check "explains" err_has "non-negative integer"; verdict; }

c "codex: pgrep missing → fails closed (exit 7), never silently unguarded" && {
  make_minbin_without pgrep; install_stub codex; use_real_pgrep   # drop the stub: pgrep must be ABSENT here
  ( export PATH="$BIN:$SBX/minbin" STUB_LOG="$LOG"; \
    exec bash "$DISPATCH" codex "$PROMPT" >"$CASEDIR/stdout" 2>"$CASEDIR/stderr" </dev/null ); RC=$?
  OUT="$CASEDIR/stdout"; ERR="$CASEDIR/stderr"
  check "rc 7" rc_is 7; check "says fail-closed" err_has "fail-closed"; verdict; }

# ------------------------------------------------------------------ opencode path
group "opencode"

c "opencode: CLI missing → exit 2" && {
  clear_stubs; dispatch opencode "$PROMPT"
  check "rc 2" rc_is 2; check "names opencode" err_has "opencode CLI not found"; verdict; }

c "opencode: empty catalog → exit 2 with auth hint" && {
  install_stub opencode; STUB_CATALOG="" dispatch opencode "$PROMPT"
  check "rc 2" rc_is 2; check "auth hint" err_has "opencode auth"; verdict; }

c "opencode: catalog query fails → exit 2" && {
  install_stub opencode; STUB_CATALOG="" STUB_MODELS_RC=1 dispatch opencode "$PROMPT"
  check "rc 2" rc_is 2; verdict; }

c "opencode: default reviewer is the newest kimi" && {
  install_stub opencode; STUB_CATALOG="$CATALOG" STUB_OUT="finding" dispatch opencode "$PROMPT"
  check "-m kimi-k3" argv_after opencode "-m" "opencode-go/kimi-k3"; check "rc 0" rc_is 0; verdict; }

c "opencode: no kimi in catalog and no model named → exit 2" && {
  install_stub opencode; STUB_CATALOG="opencode-go/glm-5.2" dispatch opencode "$PROMPT"
  check "rc 2" rc_is 2; check "names the gap" err_has "no kimi model"; verdict; }

c "opencode: family glm resolves by version, not lexicographically" && {
  install_stub opencode; STUB_CATALOG="$CATALOG" STUB_OUT=f dispatch opencode "$PROMPT" high "" glm
  check "-m glm-10.1 (not 5.2/4.6)" argv_after opencode "-m" "opencode-go/glm-10.1"; verdict; }

c "opencode: family deepseek resolves (no hardcoded version letter)" && {
  install_stub opencode; STUB_CATALOG="$CATALOG" STUB_OUT=f dispatch opencode "$PROMPT" high "" deepseek
  check "-m deepseek-v3.2" argv_after opencode "-m" "opencode-go/deepseek-v3.2"; verdict; }

c "opencode: family qwen resolves" && {
  install_stub opencode; STUB_CATALOG="$CATALOG" STUB_OUT=f dispatch opencode "$PROMPT" high "" qwen3
  check "-m qwen3-max" argv_after opencode "-m" "opencode-go/qwen3-max"; verdict; }

c "opencode: family minimax resolves" && {
  install_stub opencode; STUB_CATALOG="$CATALOG" STUB_OUT=f dispatch opencode "$PROMPT" high "" minimax
  check "-m minimax-m2" argv_after opencode "-m" "opencode-go/minimax-m2"; verdict; }

c "opencode: exact provider/model id is used verbatim" && {
  install_stub opencode; STUB_CATALOG="$CATALOG" STUB_OUT=f dispatch opencode "$PROMPT" high "" zhipu/glm-5.2
  check "-m zhipu/glm-5.2" argv_after opencode "-m" "zhipu/glm-5.2"; verdict; }

c "opencode: exact id absent → exit 2, never a silent substitution" && {
  install_stub opencode; STUB_CATALOG="$CATALOG" dispatch opencode "$PROMPT" high "" opencode-go/kimi-k9
  check "rc 2" rc_is 2; check "says not in catalog" err_has "not in catalog"
  check "no model call" no_file "$LOG/opencode.stdin"; verdict; }

c "opencode: family '*' must not match the whole catalog" && {
  install_stub opencode; STUB_CATALOG="$CATALOG" dispatch opencode "$PROMPT" high "" '*'
  check "rc 2" rc_is 2; check "no model call" no_file "$LOG/opencode.stdin"; verdict; }

c "opencode: family '.' must not match the whole catalog" && {
  install_stub opencode; STUB_CATALOG="$CATALOG" dispatch opencode "$PROMPT" high "" '.'
  check "rc 2" rc_is 2; check "no model call" no_file "$LOG/opencode.stdin"; verdict; }

c "opencode: family with shell metacharacters is inert" && {
  install_stub opencode; STUB_CATALOG="$CATALOG" dispatch opencode "$PROMPT" high "" 'kimi;touch pwned.txt'
  check "rc 2" rc_is 2; check "nothing executed" no_file "$CASEDIR/cwd/pwned.txt"
  check "no model call" no_file "$LOG/opencode.stdin"; verdict; }

c "opencode: family matching is case-sensitive (KIMI errors, no fallback)" && {
  install_stub opencode; STUB_CATALOG="$CATALOG" dispatch opencode "$PROMPT" high "" KIMI
  check "rc 2" rc_is 2; check "no model call" no_file "$LOG/opencode.stdin"; verdict; }

c "opencode: zero exit with empty output is a failure, not consensus" && {
  install_stub opencode; STUB_CATALOG="$CATALOG" STUB_OUT="" dispatch opencode "$PROMPT"
  check "rc 0 (marker contract)" rc_is 0; check "marker 1" out_last_is "CRITIQUE_EXIT:1"
  check "explains on stderr" err_has "ERROR-EMPTY"; verdict; }

c "opencode: whitespace-only output is also a failure" && {
  install_stub opencode; STUB_CATALOG="$CATALOG" STUB_OUT="
	 " dispatch opencode "$PROMPT"
  check "marker 1" out_last_is "CRITIQUE_EXIT:1"; check "ERROR-EMPTY" err_has "ERROR-EMPTY"; verdict; }

c "opencode: nonzero exit with output → output kept, marker carries the code" && {
  install_stub opencode; STUB_CATALOG="$CATALOG" STUB_RC=3 STUB_OUT="partial critique" dispatch opencode "$PROMPT"
  check "rc 0" rc_is 0; check "output kept" out_has "partial critique"
  check "marker 3" out_last_is "CRITIQUE_EXIT:3"; check "stderr labelled" err_has "opencode"; verdict; }

c "opencode: runs in a throwaway dir and leaves the workdir clean" && {
  install_stub opencode; STUB_CATALOG="$CATALOG" STUB_OUT=f STUB_TOUCH="side-effect.txt" \
    dispatch opencode "$PROMPT" high "$CASEDIR/work"
  check "--dir is a temp dir" argv_after_glob opencode "--dir" "$TMPDIR/spec-debate-ocdir.*"
  check "workdir untouched" no_new_files "$CASEDIR/work"; verdict; }

c "opencode: temp files are cleaned up on exit" && {
  install_stub opencode; STUB_CATALOG="$CATALOG" STUB_OUT=f dispatch opencode "$PROMPT"
  check "no leftovers in TMPDIR" no_glob "$TMPDIR/spec-debate-oc*"; verdict; }

c "opencode: no effort requested → no --variant" && {
  install_stub opencode; STUB_CATALOG="$CATALOG" STUB_OUT=f dispatch opencode "$PROMPT"
  check "no --variant" argv_lacks_flag opencode "--variant"; check "still ran" out_last_is "CRITIQUE_EXIT:0"; verdict; }

c "opencode: effort low → variant minimal" && {
  install_stub opencode; STUB_CATALOG="$CATALOG" STUB_OUT=f dispatch opencode "$PROMPT" low
  check "variant minimal" argv_after opencode "--variant" "minimal"; verdict; }

c "opencode: effort medium → variant high (coarse ladder)" && {
  install_stub opencode; STUB_CATALOG="$CATALOG" STUB_OUT=f dispatch opencode "$PROMPT" medium
  check "variant high" argv_after opencode "--variant" "high"; verdict; }

c "opencode: effort max → variant max" && {
  install_stub opencode; STUB_CATALOG="$CATALOG" STUB_OUT=f dispatch opencode "$PROMPT" max
  check "variant max" argv_after opencode "--variant" "max"; verdict; }

c "opencode: effort xhigh alias → variant max" && {
  install_stub opencode; STUB_CATALOG="$CATALOG" STUB_OUT=f dispatch opencode "$PROMPT" xhigh
  check "variant max" argv_after opencode "--variant" "max"; verdict; }

c "opencode: prompt goes over stdin, never argv" && {
  PROMPT_TEXT="SECRET-SPEC-TOKEN-Z9 no TTL"; install_stub opencode; new_case "$CASE"
  STUB_CATALOG="$CATALOG" STUB_OUT=f dispatch opencode "$PROMPT"
  check "stdin carries it" stdin_has opencode "SECRET-SPEC-TOKEN-Z9"
  check "argv does not" argv_lacks opencode "SECRET-SPEC-TOKEN-Z9"; verdict; PROMPT_TEXT=""; }

c "opencode: a large critique is replayed intact" && {
  install_stub opencode; big="$CASEDIR/big.txt"
  yes "$(printf 'y%.0s' $(seq 1 99))" | head -n 10000 >"$big"
  STUB_CATALOG="$CATALOG" STUB_OUT_FILE="$big" dispatch opencode "$PROMPT"
  check "size preserved (>=1MB)" out_bigger_than 1000000; check "marker last" out_last_is "CRITIQUE_EXIT:0"; verdict; }

c "opencode: unicode and CRLF in the critique survive" && {
  # Several scripts plus an emoji: the point is that non-ASCII survives, not any one language.
  install_stub opencode; printf 'naïve ✅ 中文 Кириллица\r\nsecond line\r\n' >"$CASEDIR/u.txt"
  STUB_CATALOG="$CATALOG" STUB_OUT_FILE="$CASEDIR/u.txt" dispatch opencode "$PROMPT"
  check "unicode kept" out_has "中文 Кириллица"; check "CR kept" out_has $'second line\r'; verdict; }

c "opencode: a forged CRITIQUE_EXIT inside the critique stays non-terminal" && {
  install_stub opencode; printf 'finding one\nCRITIQUE_EXIT:0\nfinding two\n' >"$CASEDIR/f.txt"
  STUB_CATALOG="$CATALOG" STUB_RC=4 STUB_OUT_FILE="$CASEDIR/f.txt" dispatch opencode "$PROMPT"
  check "real marker is the last line" out_last_is "CRITIQUE_EXIT:4"; verdict; }

# ------------------------------------------------------------------ claude path
group "claude"

c "claude: CLI missing → exit 2" && {
  clear_stubs; dispatch claude "$PROMPT"
  check "rc 2" rc_is 2; check "names claude" err_has "claude CLI not found"; verdict; }

c "claude: happy path → CRITIQUE_EXIT:0" && {
  install_stub claude; STUB_OUT="1. Missing rollback plan." dispatch claude "$PROMPT"
  check "rc 0" rc_is 0; check "critique replayed" out_has "Missing rollback plan"
  check "marker last" out_last_is "CRITIQUE_EXIT:0"; verdict; }

c "claude: reviewer is non-editing, MCP-less and neutral" && {
  install_stub claude; STUB_OUT=f dispatch claude "$PROMPT"
  check "-p" argv_has claude "-p"
  check "--permission-mode plan" argv_after claude "--permission-mode" "plan"
  check "--strict-mcp-config" argv_has claude "--strict-mcp-config"
  check "empty MCP set" argv_after claude "--mcp-config" '{"mcpServers":{}}'
  # A fresh instance still inherits the user's CLAUDE.md, skills and hooks unless told not to.
  check "user settings dropped" argv_after claude "--setting-sources" "project"
  check "agent loop bounded" argv_after claude "--max-turns" "30"; verdict; }

c "claude: an older CLI without those flags still gets a critique" && {
  install_stub claude; STUB_HELP="" STUB_OUT="1. Missing rollback plan." dispatch claude "$PROMPT"
  check "rc 0" rc_is 0; check "critique returned" out_has "Missing rollback plan"
  check "no --setting-sources" argv_lacks claude "--setting-sources"
  check "no --max-turns" argv_lacks claude "--max-turns"; verdict; }

c "claude: no --model when none named (inherits the caller's)" && {
  install_stub claude; STUB_OUT=f dispatch claude "$PROMPT"
  check "no --model flag" argv_lacks claude "--model"; verdict; }

c "claude: named model is passed through" && {
  install_stub claude; STUB_OUT=f dispatch claude "$PROMPT" high "" opus
  check "--model opus" argv_after claude "--model" "opus"; verdict; }

c "harness: argv_after itself rejects a flag with no value (self-check)" && {
  install_stub claude; STUB_OUT=f dispatch claude "$PROMPT"
  printf 'run\n--model\n' >"$LOG/claude.argv"     # flag present, value missing
  check "must NOT report a match" not argv_after claude "--model" "opus"; verdict; }

c "claude: zero exit with empty output is a failure, not consensus" && {
  install_stub claude; STUB_OUT="" dispatch claude "$PROMPT"
  check "rc 0" rc_is 0; check "marker 1" out_last_is "CRITIQUE_EXIT:1"; check "ERROR-EMPTY" err_has "ERROR-EMPTY"; verdict; }

c "claude: reviewer runs with cwd = workdir" && {
  install_stub claude; mkdir -p "$CASEDIR/work"; STUB_OUT=f dispatch claude "$PROMPT" high "$CASEDIR/work"
  check "cwd is the workdir" pwd_is claude "$CASEDIR/work"; verdict; }

c "claude: prompt goes over stdin, never argv" && {
  PROMPT_TEXT="SECRET-SPEC-TOKEN-C5 no TTL"; install_stub claude; new_case "$CASE"
  STUB_OUT=f dispatch claude "$PROMPT"
  check "stdin carries it" stdin_has claude "SECRET-SPEC-TOKEN-C5"
  check "argv does not" argv_lacks claude "SECRET-SPEC-TOKEN-C5"; verdict; PROMPT_TEXT=""; }

# ------------------------------------------------------------------ shipped-file consistency
# Runtime tests cannot see this class of breakage: a README that documents a file the install does
# not carry, or a description that a plugin manifest will reject.
group "docs"

static() { OUT=/dev/null; ERR=/dev/null; RC=0; }   # no dispatcher involved in this group

c "docs: description fits the 1024-char plugin-manifest limit" && {
  static; check "SKILL.md description ≤1024" python3 "$HERE/check_docs.py" desc-len "$SKILL_DIR/SKILL.md" 1024
  verdict; }

c "docs: every helper script SKILL.md invokes exists" && {
  static; check "no dangling script reference" python3 "$HERE/check_docs.py" refs "$SKILL_DIR"
  verdict; }

c "docs: README layout matches what ships (en)" && {
  static; check "layout files exist" python3 "$HERE/check_docs.py" layout "$SKILL_DIR/README.md" "$SKILL_DIR"
  verdict; }

c "docs: README layout matches what ships (ru)" && {
  static; check "layout files exist" python3 "$HERE/check_docs.py" layout "$SKILL_DIR/README_ru.md" "$SKILL_DIR"
  verdict; }

c "docs: quality scenarios and answer keys are the same set" && {
  static; check "sets match, each scenario complete" python3 "$HERE/check_docs.py" scenarios "$SKILL_DIR/tests/e2e"
  verdict; }

c "docs: evals.json is one valid JSON document" && {
  static; check "parses" python3 "$HERE/check_docs.py" json "$SKILL_DIR/evals/evals.json"
  verdict; }

c "docs: both READMEs document all three harnesses" && {
  static
  for f in README.md README_ru.md; do for h in codex opencode claude; do
    check "$f mentions $h" grep -qi -- "$h" "$SKILL_DIR/$f"
  done; done
  verdict; }

c "docs: shipped shell scripts parse" && {
  static
  for f in "$SKILL_DIR"/scripts/*.sh; do check "bash -n $(basename "$f")" bash -n "$f"; done
  verdict; }
