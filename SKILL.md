---
name: spec-debate
description: >-
  Debate a spec, plan, design, PRD, code change, or claim with a second AI
  reviewer, vetting every point with veto power. Reviewer = OpenAI Codex
  (default), an opencode model (kimi/glm…), or a fresh Claude instance
  (opus/sonnet), resolved from the request. Artifact is always a spec:
  task/code/claim gets one drafted; existing spec taken as-is. Use ONLY on an
  explicit outside-opinion request — "get a second opinion", "ask/consult
  Codex/kimi/glm", "debate/stress-test this", "спроси/посоветуйся с
  кодексом/кими/glm", "пусть кими/glm/опус раскритикует/оценит это", "дай
  кому-нибудь на второе мнение". Model names = reviewers reached THROUGH this
  skill (no standalone CLI). Named opus/sonnet: NEVER review yourself even if
  you ARE that model — a FRESH instance reviews. FIRES. Bare "review
  this"/"найди дыры"/"оцени" to you does NOT trigger, nor does "do the task
  with model X" ("перепиши на kimi", "use opus to refactor"). Bounded question
  → one prompt-only consult; else 1 invocation = 1 round; settled points not
  re-raised.
---

# spec-debate — debate a spec with a second model, with veto

You orchestrate a debate between yourself (Claude) and a **second AI reviewer** — resolved in Step 0:
OpenAI Codex, an opencode model (kimi/glm/…), or a fresh Claude instance — to make a **spec**
measurably better. You are the **editor with veto power**: never apply a point blindly — verify each
against the actual spec and keep only what genuinely improves it. The vetting is the whole point; a
critic that's always obeyed is just a second author.

**The iterated artifact is always a spec** (requirements / design / plan / PRD — any domain). There are
four ways in, all converging on iterating one spec:
- **TASK** → you draft a solution spec.
- **CODE** → you draft a *change-spec*; the code is reference material, **not edited during the
  debate** (it is applied afterwards, as a separate step, if you have access).
- **EXISTING SPEC** → you take it as the artifact.
- **IDEA/CLAIM/THESIS** → you draft a short position-spec; bounded one-pass versions go prompt-only (no file).

Each round, **both models independently propose improvements**; you **merge with veto** and apply the
result to the spec. **Goal: a better spec, not a bigger one** — close real gaps, cover core scenarios,
resolve contradictions, fix real risks, remove ambiguity; accept added complexity only when a real
gap/risk/UX need justifies it. One invocation = one round; state persists in
`.<filename>.debate-state.json` beside the spec so rounds don't relitigate settled points.

---

## Step 0 — Preconditions
1. **Pick the reviewer harness `<H>` + model** from the request (the debate needs an *independent*
   second opinion):
   - **Named model** — gpt/гпт→codex; kimi/glm/deepseek/qwen or a full `provider/model`→opencode;
     opus/opus·sonnet→claude. Use that harness at its latest version.
   - **Named harness** — codex/кодекс→codex; opencode/опенкод→opencode (default model: latest kimi);
     claude code/клод код→claude (a fresh instance).
   - **No name** (external review still requested) — default **codex → opencode → claude**: the first
     one installed. `<H>` ∈ {codex, opencode, claude}; CLIs `codex` / `opencode` / `claude`.
   - Several named ("пусть X и Y…") — run the first now, note the rest (panel = fast-follow).
2. **Preflight the *resolved* `<H>`** (not just the requested one): `command -v <cli>`; if missing, fall
   to the next default, or — for a *named* harness — stop and say which to install. Then auth/config:
   codex→`codex login status`; opencode→`opencode models` non-empty with the named family present;
   claude→a fresh instance is available. If none of the three is usable, stop: "No reviewer harness
   found — install one of codex / opencode / claude."
3. Parse reasoning effort → abstract `low|medium|high|max` (`--high|--medium|--low|--max`, `effort=…`,
   "maximum reasoning depth"→`max`; legacy "xhigh"→`max`). Default `high`; `max` is much slower, on
   explicit request only. (`run_critique.sh` maps it per harness; claude has no effort knob.)
4. Parse a round directive (a count like "run 3 rounds", or "until no significant findings remain");
   default one round. Parse a `thorough` request (cross-critique, Step 3c).

## Step 1 — Pick the mode, then resolve the working spec
First a **surface scope scan** — structure, size, number of files/components, whether the design is
non-trivial. This is a *shallow look, not deep reading*: deep study **of the referenced material**
happens inside the chosen mode (Step 3b), so you never pay for it twice. Then choose:
- **prompt-only** — a bounded advisory question whose output is advice/a comparison the user applies
  directly (a design comparison; a one-pass critique of a single diff or file you embed), with nothing
  worth iterating and the scan showing it closes in one pass.
- **iterable spec (the main flow)** — breadth or complexity (several files/components or substantial
  material; a design with several coupled decisions), or the user wants iteration / a written spec.

State the chosen mode in one line. If a prompt-only consult turns out under-scoped mid-pass, finish
that pass, then offer to escalate to an iterable-spec debate (don't abandon it half-done).

**Prompt-only path (compact):** one reviewer pass on the question (via `run_critique.sh <H>`) — a
free-form prompt (role line + the question + relevant conversation context: user statements verbatim,
your summaries marked as yours), `<workdir>` = current dir. Vet the answer with the Step 4 lens. Report
inline: the reviewer's position, your vetted take, the prompt-file path, and a one-line "sent to
<reviewer> (<provider>)" note (subject; refs/snippets; anything privacy-mode withheld). No state, no
rounds. For any follow-up round or edit, materialize the
subject into a spec file and seed `.<filename>.debate-state.json` as round 1 (each settled conclusion becomes a
finding). Then continue below.

**Iterable spec — seed the artifact:**
- Use the explicit path if given; else the spec you drafted/took earlier in *this* conversation; else
  ask — don't guess across the filesystem. If the spec lives only in the conversation, write it to a
  markdown file first (the debate needs a file to edit and to hold `.<filename>.debate-state.json`) —
  a descriptive `<topic>-spec.md` beside the related material or in the working dir; state the path.
- **TASK** → draft a solution spec. **CODE** → draft a change-spec. **EXISTING SPEC** → take the file.
- **Minimal spec shape (quality gate)** — so the debate doesn't converge on something under-specified.
  Every spec should conceptually carry: goal · non-goals · assumptions · constraints · acceptance
  criteria · open questions · what material was studied and what was deliberately skipped (if any). A
  **code change-spec** adds: changes by file/component · behavior preserved vs changed · risks/migrations
  · acceptance checks/tests. Tiny tasks may compress this, but the fields are conceptually present. If
  **material facts** are missing and would shape the spec, **ask the user before debating** — don't debate
  a fabricated spec. You ensure this shape when *you* author (TASK/CODE). For a **given** spec it is NOT
  a precondition — missing fields become debate findings, and you don't rewrite the input before
  discussing it; but if the given input is essentially empty (a stub, not a real spec), treat it as a
  TASK and draft.
- **Name the spec type and altitude** — it governs every later judgment — and read the spec artifact in
  full (distinct from deep-studying the referenced material, which is paced per Step 3b):
  - *requirements* → what & why, contracts, acceptance criteria;
  - *technical design / spec* → architecture, key mechanisms, data models, trade-offs;
  - *implementation / change plan* → concrete steps, component-level changes, sequencing, configs.
  > "Debating `path` (N lines) — design spec, design altitude. Effort: high. Round: 2."
  If the type is ambiguous, make the call, state it, and proceed — the user will correct you.

## Step 2 — Load state
Look for `.<filename>.debate-state.json` beside the spec. (If you move the spec, move its debate-state file with it.)
- Not found → round 1, fresh state.
- Found → next round = `last_round + 1`. Collect prior `rejected` and `partial` findings (both
  sources) with reasons; you'll hand them to the reviewer so it doesn't re-raise settled points.
- Malformed JSON → repair from its readable content first (rounds/findings are usually intact as text);
  don't discard history. Older files may omit the `reviewer` field (treat as null) and use
  `source ∈ codex|own` — both still parse.

Schema:
```json
{"spec": "path", "spec_type": "design spec",
 "rounds": [{"round": 1, "reviewer": {"harness": "codex|opencode|claude", "model": "id or null"},
   "effort": "high", "cross_critique": false, "findings": [
   {"id": "R1-1", "source": "codex|opencode|claude|own", "title": "...", "severity": "critical|major|minor",
    "verdict": "accepted|partial|rejected", "reason": "one line", "edit": "what changed or null"}]}]}
```

## Step 3 — Gather independent proposals
Both models independently propose improvements to the **round-start spec**. *Independence means only
this:* the reviewer does **not** see your current-round proposal list (so it isn't anchored). It **does**
get the shared context — the task statement, the spec itself, the relevant material, and the settled
verdicts — because those are the artifact and prior decisions, not this round's proposals.

**3a — Your proposals.** Independently list improvements at the spec's altitude: gaps, missing core
scenarios, contradictions, blocking ambiguities, unaddressed risks, over-engineering, requirements
unrealistic for the scale.

**3b — the reviewer's proposals.** Write the prompt below to a temp file (verbatim avoids shell-escaping)
and run the dispatcher. Ask the reviewer for both fixes to what's written **and** what the spec misses
given the task and material (alternatives, risks, uncovered requirements).

> **Conveying the material.** **Embed** the relevant excerpts verbatim in the prompt — the universal
> default for every harness (it keeps the reviewer from wandering and works for remote/non-file material
> too). The path-reference optimization — point to material by **precise path** with `<workdir>` at its
> root — is **codex-only** (its read-only sandbox); opencode and claude always get embedded context. The
> deep study is yours (Step 1's scan was only surface): study the parts relevant to the task and **record
> in the spec what you studied and what you skipped**. The subject doesn't change during the debate, so
> do this deep study **once (round 1)**; later rounds need only targeted look-ups (verify a reviewer
> claim or cover something newly in scope), and the recorded facts carry forward in the spec. The
> reviewer is stateless, so each round give it the **same curated slice** + the updated spec + settled
> verdicts; widen the slice only when scope grows.
>
> **The spec itself** is embedded verbatim by default — that preserves an exact round-start audit trail.
> For a spec file inside `<workdir>` large enough that re-embedding it every round is materially wasteful
> (as a guide: several hundred lines+), you may — **codex-only**, via its file-read sandbox — replace the
> template's SPEC block with `SPEC FILE: <exact path> (<N lines>)` plus: "Read this file IN FULL before
> critiquing; do not critique from a skim or excerpt."

```
IMPORTANT: Do NOT read or execute anything under ~/.claude/, ~/.agents/, .claude/skills/, or
.claude/agents/ — those are AI-tooling files for a different agent and will waste your time.

You are a rigorous independent senior reviewer improving a <SPEC_TYPE> (altitude: <ALTITUDE>).
Propose improvements AT THAT ALTITUDE — both fixes to what is written and what the spec MISSES
relative to its goal and the material below: gaps and under-specified core scenarios, missing
alternatives, unaddressed risks, internal contradictions, ambiguities that would block correct
execution, requirements unrealistic for the stated scale, security/correctness issues.
For each: short title, severity (critical/major/minor), the problem, a concrete fix. The goal is a
better, not a bigger, spec — prefer the simplest change that closes the gap, flag over-engineering,
calibrate to the stated scale, and do not manufacture nitpicks. If nothing serious remains at this
altitude, say so plainly. End with a one-line readiness verdict. Respond in the spec's language.
Group by section.

<if settled findings:>
Already settled in prior rounds — do NOT re-raise without a genuinely new argument:
- "<title>" — <rejected|partial>: <reason>

Task / context (NOT part of the spec; provenance marked):
- [user, verbatim] "<...>"
- [editor summary] <...>
Referenced material: <read-only at <workdir>: exact paths> OR <embedded below>.

SPEC:
---
<full verbatim spec — or the SPEC FILE reference per "Conveying the material">
---
```

Resolve `<skill_dir>` from the injected "Base directory for this skill:
<abs path>" line for THIS invocation — do not copy or hardcode an example path: the active install may
be under user settings (`~/.claude/skills/…`), a plugin install, or a versioned plugin cache, and the
path differs in each. Run the unified dispatcher:
`bash "<skill_dir>/scripts/run_critique.sh" <H> <prompt_file> <effort> <workdir> [model]`
If the script isn't found there, treat the install as broken — stop and report it; do not fall back to
a guessed or remembered path.
- **Always via the dispatcher, never raw.** It feeds the prompt via **stdin** (keeps the spec text off
  the process list; no ARG_MAX limit on large embeds), preflights the CLI, maps effort per harness, and
  — for codex — delegates to the hardened `run_codex_critique.sh` unchanged. `<H>` and `[model]` come
  from Step 0; `<effort>` is the abstract level.
- `<workdir>`: the material's repo/dir root when it's local (codex reads it read-only — see Conveying the
  material); else the prompt file's dir.
- Match the Bash tool's `timeout` to effort and prompt size (any harness): `300000` (ms) is usually
  enough for `low`/`medium` on a small prompt; for `high`/`max`, or a large embed (a big spec plus a full
  diff — hundreds of lines / tens of KB), raise it toward the `600000` max, or drop the effort. **Codex
  only:** one `codex exec` at a time — if a pass hit the timeout its codex may still be running and the
  next call trips the guard; wait for the slot with `CODEX_MAX_WAIT_SECS=<seconds>` (raise the Bash
  `timeout` to match) instead of firing a second run, and don't kill a run you don't own. opencode and
  claude have no such guard.
- Output ends with `CRITIQUE_EXIT:<n>`; if non-zero, the dispatcher already printed the reviewer's stderr
  inline — read it and stop. An `ERROR:` line with no `CRITIQUE_EXIT` is a preflight failure (CLI/auth
  missing, bad effort/workdir, unreadable prompt) — read it and stop.

**3c — Cross-critique (thorough or own major+).** Run ONE more reviewer call: give the reviewer **your**
proposal list (with the same context as 3b — spec, task, material) and ask, per item, agree / partial /
reject + a one-line argument — so your merge also sees the reviewer's
rebuttal of *your own* proposals. (Your review of the reviewer's proposals is the merge itself, Step 4 —
no extra call for that.) Run 3c when the user asked for `thorough` — honor that unconditionally — or when
your own 3a list contains any major+ proposal: without 3c, only the reviewer's list gets second-model
scrutiny. Skip it otherwise.

## Step 4 — Merge with veto (the core)
**You are always the merger** — the reviewer is read-only and has less context, and blind-applying its
output would break the veto. Put **both lists** — the reviewer's and your own from 3a — through ONE
procedure, item by item:
1. **Verify it's real.** Re-read the cited part; if it rests on a checkable fact, check it. Reject
   misreads and invented referents.
2. **Judge at the spec's altitude**, weighted by **impact × likelihood-of-trigger × altitude** —
   discount real-but-practically-unreachable points, but don't kill a plausible edge case.
3. **Decide:** accept / partial (apply *your* better, simpler fix) / reject — with a one-line reason.

Record **rejected items from your OWN list too** — that symmetric audit is what guards against your
self-bias, since the merger never rotates. Don't rubber-stamp, and don't reject good points to look
independent. Consolidate into ONE edit set; integrate coherently where points overlap.

## Step 5 — Apply to the spec
Apply accepted/partial items as precise, in-voice `Edit`s — the least added complexity that closes each
gap. Then **re-read the edited sections together for self-consistency**: an edit that resolves one point
often introduces a new contradiction (a changed contract, a now-stale reference, two options left open),
and that becomes next round's finding — catching it here is what makes the debate converge instead of
churn. Don't leave alternatives "to decide later"; make the call now.

## Step 6 — Report (make progress visible)
```
## spec-debate — round N · <reviewer> (<provider>, <effort>) · `path` · M proposals (reviewer K · own J)
### Accepted (…)
- [critical] <title> — what changed · (reviewer|own)
### Partial (…)
- [major] <title> — applied Y instead of X because <reason> · (reviewer|own)
### Rejected (…)
- [minor] <title> — <reason> · (reviewer|own)
### Where it stands
- Open gaps worth a round, or "no significant gaps remain at this altitude".
- Convergence: recommend STOP, or what a next round would target (see Step 7).
- Progress: r1: 12 · r2: 5.
```

## Step 7 — Persist, then continue or end
Append this round (number, effort, cross_critique, findings with source/verdict/reason/edit) to
`.<filename>.debate-state.json`. Rewrite the file as one complete JSON document (don't string-append a
round after the closing brackets) and verify it parses
(`python3 -c 'import json,sys; json.load(open(sys.argv[1]))' <file>`) — a malformed state file silently
breaks every later round.

**Convergence criterion:** if the round landed **no material edit** (only cosmetic/wording) OR only
**minor** proposals remain → explicitly **recommend STOP**. Then:
- **If the user explicitly asked for several rounds in this invocation** — run the next now: re-read the
  updated spec in full, gather ALL settled verdicts (incl. the round just appended), repeat Steps 3–6.
  Stop at the first of: the requested count (a maximum — stop early if a round is clean); a round with no
  accepted/partial finding of **major or higher** severity; a hard cap of **5 rounds** if the directive is
  open-ended ("until no significant findings remain"). Report each round.
- **Otherwise** — stop after this round and tell the user they can invoke again to continue from round
  N+1. Don't loop on a bare invocation.

**User-resolvable blockers mid-loop.** If a round surfaces a question only the user can answer and the
answer would materially reshape the spec (the Step 1 "don't debate a fabricated spec" bar — not a
routine open question), finish the current round, report, then pause the loop early and ask — even if
more rounds were requested. Apply the user's answers as **editor edits** (not as debate findings) before
the next round's gathering. Lesser questions go into the spec's open questions and the loop continues.

## Code change-specs — three extra rules (only when the subject is code)
- **Anchoring.** A change-spec encodes *your* plan, so the reviewer critiquing it is partly anchored.
  Default: accept that — in 3b, ask the reviewer to hunt for gaps, missing alternatives, and risks rather
  than rubber-stamp. Escalate only for high-impact / ambiguous / sensitive work: in round 1, run the
  reviewer as an **independent** analysis of the code + task *without* your draft, then fold both into the
  change-spec; later rounds critique the spec.
- **Re-ground each round.** A change-spec can drift into debating only its own text. Every round, re-check
  the round-start spec against the user's task and the relevant code facts (pacing per 3b); keep the
  studied/skipped areas and key facts *in the change-spec* so they carry across rounds.
- **Debate → implementation boundary.** Applying the change-spec to code is a **post-debate execution
  step, not part of the loop** — "the spec converged" ≠ "the code works", so the change-spec carries
  acceptance checks/tests. At convergence, if you have edit access, offer to apply it now; if you do, run
  a normal engineering loop (edit → run tests/checks → report) and report **implementation results
  separately from debate verdicts**. Otherwise: stop / another round.

---

## Guardrails
- **Privacy** — *default: unrestricted.* The spec and any referenced material are sent to the reviewer's
  provider: **OpenAI** (codex), the **opencode model's provider** (e.g. Moonshot for kimi, Zhipu for
  glm), or **Anthropic** (a fresh Claude). Name the resolved provider in your "sent to reviewer" note; if
  a fallback changed the provider from what the user named, say so. **Privacy-mode** is an explicit
  opt-in ("privacy mode" / "don't send the code"): then send only an approved abstracted summary (mark
  its confidence as limited), or decline the pass if it can't be judged without the material. Never embed
  obvious secrets — same bar for every provider.
- **One codex at a time** — codex-specific; the helper enforces it, never launch a second yourself.
  opencode and claude reviewers have no such limit.
- **The reviewer never edits files** — it only proposes. Codex is sandboxed read-only; the claude
  reviewer runs in non-editing `plan` mode; the opencode reviewer's default agent is *not* hard-sandboxed,
  so the dispatcher gives it a critique-only prompt and isolates it to the prompt file's dir (never point
  its workdir at your repo). All edits are yours, after vetting.
- **Same-model caveat** — if a fallback resolves to a claude reviewer that is your own model, a *fresh
  instance* removes anchoring but not correlated blind spots; prefer codex or opencode for true
  cross-provider independence (codex stays the default, so this is the exception).
- **Don't fabricate consensus** — when you reject a point, say so with your reason; the user can overrule.
