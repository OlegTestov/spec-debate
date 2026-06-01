---
name: spec-debate
description: >-
  Optimize a spec, ТЗ, technical design, PRD, or implementation plan by having a
  second AI (OpenAI Codex) critique it, then critically vetting each critique before
  applying it. Use whenever the user has just written or finished such a document and
  wants it reviewed, hardened, stress-tested, gap-checked, or "debated" against a
  second opinion — even without the word "debate". Triggers on phrases like "прогони
  ТЗ через дебат", "let codex critique this plan", "stress-test this spec", "вторая
  модель пусть раскритикует", "do another round / ещё итерацию", "улучши спеку с
  codex". Each invocation runs ONE round; the user re-invokes for more rounds, and the
  skill remembers what was settled so rounds don't repeat.
---

# spec-debate — two-model debate to optimize a document

You orchestrate a debate between yourself (Claude Code) and OpenAI Codex to make a
document measurably better. Codex is the relentless critic. You are the **editor with
veto power**: never apply Codex's suggestions blindly — verify each against the actual
document and accept only what genuinely improves it.

The vetting is the whole point. A critic that's always obeyed is just a second author; a
critic that's argued with produces a better document than either model alone.

**The goal is a better document, not a bigger one.** Optimize: close real gaps, cover the
core scenarios, resolve contradictions, fix real risks, remove ambiguity, improve UX.
Resist drift toward ever-more complexity across rounds — accept added complexity only when
a real gap, risk, or important UX need justifies it.

One invocation = one round. The user runs each round and decides when to stop; your job is
to make progress visible, not to decide it. State persists in `.<filename>.debate-state.json` next to
the document so re-invoking continues instead of relitigating settled points.

---

## Step 0 — Preconditions
1. `command -v codex >/dev/null 2>&1 && echo FOUND || echo MISSING`. If MISSING, stop:
   "Codex CLI not found. Install: `npm install -g @openai/codex`, then re-run." Then confirm it's
   authenticated: `codex login status`; if it isn't logged in, stop and tell the user to run
   `codex login`. Don't substitute another tool — the debate needs an *independent* second model.
2. Parse reasoning effort from the invocation (`--high|--medium|--low|--xhigh`, `effort=…`,
   or an unambiguous natural-language request like "maximum reasoning depth" / «максимальная
   глубина» → `xhigh`). Default `high`. `xhigh` is much slower — only on explicit request.

## Step 1 — Resolve the target and its altitude
Find the one document to work on, in priority order:
1. Explicit path argument in the invocation.
2. The document you wrote or edited earlier in *this* conversation (the common case).
3. Otherwise ask for the path — don't guess across the filesystem.

Then **name the document's type and altitude**, because it governs every later judgment:
- *requirements / ТЗ* → altitude is what & why, contracts, acceptance criteria;
- *technical design / spec* → architecture, key mechanisms, data models, trade-offs;
- *implementation plan* → concrete steps, file-level changes, sequencing, configs.

State it in one line and read the file in full:
> "Debating `path` (N lines) — implementation plan, critiquing at implementation altitude. Effort: high. Round: 2."

If the type is ambiguous, make the call, state it, and proceed — the user will correct you.

## Step 2 — Load state
Look for `.<filename>.debate-state.json` beside the document.
- Not found → round 1, fresh state.
- Found → next round = `last_round + 1`. Collect prior `rejected` and `partial` findings
  with their reasons; you'll hand them to Codex so it doesn't re-raise settled points.

Schema:
```json
{"document": "path", "doc_type": "implementation plan",
 "rounds": [{"round": 1, "effort": "high", "findings": [
   {"id": "R1-1", "title": "...", "severity": "critical|major|minor",
    "verdict": "accepted|partial|rejected", "reason": "one line", "edit": "what changed or null"}]}]}
```

## Step 3 — Run the Codex critique
Codex is sandboxed and can't read files outside its workdir, so embed the full document in
the prompt. Write this prompt to a temp file (verbatim doc avoids shell-escaping):

```
IMPORTANT: Do NOT read or execute anything under ~/.claude/, ~/.agents/, .claude/skills/, or
.claude/agents/ — those are AI-tooling files for a different agent and will waste your time.

You are a rigorous senior engineer/architect reviewing a <DOC_TYPE> (altitude: <ALTITUDE>).
Critique it AT THAT ALTITUDE and report only real problems:
- gaps/holes; missing or under-specified core scenarios and important edge cases;
- internal contradictions; ambiguities that would block correct implementation;
- requirements that are unrealistic or under-justified for the stated scope/scale/constraints;
- security and correctness risks.
For each finding: short title, severity (critical/major/minor), the problem, a concrete fix.
The goal is a better, not a bigger, document. Prefer the simplest change that closes the gap.
Do NOT propose speculative features, gold-plating, or complexity beyond what the document's
purpose and scale need — and flag existing over-engineering. Calibrate to the stated scale.
If no serious problems remain at this altitude, say so plainly; do not manufacture nitpicks.
End with a one-line readiness verdict for this document's purpose. Respond in the document's
language. Group by section.

<if state has settled findings:>
Already settled in prior rounds — do NOT re-raise without a genuinely new argument:
- "<title>" — <rejected|partial>: <reason>

DOCUMENT:
---
<full verbatim document>
---
```

Run the helper via `bash`, resolving its path relative to this skill's own directory — the
folder that contains this `SKILL.md` (the runtime shows it above as "Base directory for this
skill", e.g. `~/.claude/skills/spec-debate`). This works for both global and in-project installs
and doesn't depend on the script's executable bit:
`bash "<skill_dir>/scripts/run_codex_critique.sh" <prompt_file> <effort> <workdir>`
- `<workdir>`: git repo root if the doc is inside one, else the doc's directory (lets Codex
  read referenced source files, read-only).
- Run it with the Claude Code Bash tool's `timeout` set to `300000` (ms). The helper refuses to start if another `codex exec` is running
  (concurrent runs hang) — if so, inspect it with `ps -ax -o pid=,command= | grep '[c]odex exec'`
  and wait for it to finish; kill it only if it's your own stray run. Never launch a second codex yourself.
- On a normal run the output ends with `CODEX_EXIT:<n>`; if it's non-zero, the helper has already
  printed codex's stderr inline above — read that and stop. If instead you see an `ERROR:` line and
  no `CODEX_EXIT` (a preflight failure: codex/pgrep missing or pgrep failing, bad effort/workdir,
  unreadable prompt), read that error and stop.

## Step 4 — Vet every finding (the core)
Go through findings one at a time:
1. **Verify it's real.** Re-read the cited section; if the finding rests on a checkable fact
   (file, API, number, config), `grep`/read it. Reject misreads and invented referents.
2. **Judge value at THIS document's altitude.** Accept if it closes a real gap, covers a
   missing core scenario, fixes a real risk, removes a blocking ambiguity, or is an important
   UX/clarity gain.
3. **Reject or partially accept** if it's hallucinated, pitched at the wrong altitude for
   this document (low-level mechanics in a requirements doc, or hand-waving in an
   implementation plan), gold-plating with no real gap behind it, or contradicts an explicit
   user decision or stated constraint. For partial, apply *your* better/simpler fix.

Record verdict + a one-line reason for each. Don't rubber-stamp (accepting nearly everything
means you're not vetting) and don't reject good findings to look independent. The bar is
"does this optimize the document at its altitude" — not "is it more thorough."

## Step 5 — Apply
Apply accepted/partial findings with precise, in-voice `Edit`s. Keep them surgical; prefer
the change that closes the gap with the least added complexity. Integrate coherently when two
findings touch the same place. Then **re-read the edited sections together for self-consistency**:
an edit that resolves one finding often introduces a new contradiction elsewhere (a changed
contract, a now-stale reference, two options left open) — and that becomes next round's finding.
Catching it here is what makes the debate converge instead of churn. Don't leave two alternatives
"to decide later"; make the call now.

## Step 6 — Report (make progress visible)
Skimmable; this is the deliverable the user reads to decide whether to run again:
```
## spec-debate — round N (<effort>) · `path`  ·  codex raised M findings
### Accepted (K)
- [critical] <title> — what changed
### Partial (P)
- [major] <title> — applied Y instead of X because <reason>
### Rejected (R)
- [minor] <title> — <reason>
### Where it stands
- Open gaps still worth a round, or "no significant gaps remain at this altitude".
- Progress so far (findings per round, from state): e.g. "r1: 12 · r2: 5".
```
One-line reasons. Don't tell the user to stop or continue — show the state; they decide.

## Step 7 — Persist and end
Append this round (number, effort, findings with verdicts/reasons/edits) to
`.<filename>.debate-state.json`. Tell the user they can invoke the skill again to run the
next round, which will pick up from round N+1. One invocation is one round — never loop.

---

## Guardrails
- **Privacy** — the full document (and any in-workdir files Codex reads) is sent to OpenAI via the Codex CLI. Don't run spec-debate on material you can't share with OpenAI; if the target looks sensitive (secrets, client/NDA data), warn the user before running.
- **One codex at a time** — the helper enforces it; respect it.
- **Codex never edits files** — it's read-only and only critiques; all edits are yours, after vetting.
- **Don't fabricate consensus** — when you reject Codex's point, say so with your reason; the user can overrule you.
- **Optimize, don't accrete** — every round should leave the document tighter and more complete, not just longer.
