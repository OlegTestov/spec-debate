**English** · [Русский](README_ru.md)

# spec-debate — a two-model debate over your plan, spec, or proposed solution

A skill for **Claude Code**. Each round, **two models independently propose improvements** — Claude
and a **second AI reviewer** — and Claude acts as the **editor with veto power**: it verifies every
proposal (its own and the reviewer's), keeps only what genuinely improves the work, and rejects the
rest with a reason.

**The reviewer is one of three harnesses**, chosen from how you ask:

- **OpenAI Codex** — GPT models (the default);
- **opencode** — open-source models via `opencode run`, e.g. **kimi**, **glm** (also deepseek, qwen);
- **a fresh Claude instance** (`claude -p`) — **opus** / **sonnet**, independent of the current session.

Name a model or a harness — *"ask kimi"*, *"let glm critique it"*, *"посоветуйся с кодексом"*,
*"пусть опус оценит"* — and the skill routes there (latest version of that model). With no name it
defaults to the first installed of **codex → opencode → claude**. Naming a model only triggers when
it's framed as *reviewing* an artifact — *"rewrite this with kimi"* is a task, not a review, and does
not trigger.

The thing being improved is **always a spec**, and there are four ways in:

- **a task** → Claude drafts a solution spec, then debates it;
- **code to improve** → Claude drafts a *change-spec*; the code itself isn't touched during the debate —
  it's applied afterwards, as a separate step;
- **an existing spec / plan / design** → it's taken as-is;
- **an idea / claim / thesis** → Claude drafts a short position-spec (a bounded one-pass version stays prompt-only, no file).

You can also just "get a second opinion" on a bounded question mid-flight — the skill runs a single
**prompt-only** pass and hands back an independent take, vetted by Claude, with no state saved. If you
decide to keep going, it materializes the spec file and switches to standard debate mode.

> A critic that's always obeyed is just a second author.
> A critic that's argued with produces a better result than either model alone.

By default, one invocation = one round: propose → veto → edits → report → saved state
(`.<name>.debate-state.json` next to the document). Need several rounds? Invoke again (it continues
where it left off), or ask up front — "run 3 rounds" or "keep going until no significant findings
remain". Settled findings are handed to the reviewer so it doesn't raise them again. The built-in
principle: a **better** result, not a **bigger** one — the skill actively resists complexity creep.

## Requirements

- **Claude Code** (Anthropic's CLI).
- **At least one reviewer harness** — the debate needs an *independent* second engine. Install whichever
  you prefer (or several); the skill uses what's present:
  - **Codex** (default): `npm install -g @openai/codex`, then `codex login status` (else `codex login`);
  - **opencode**: install per its docs with a configured provider (`opencode models` must be non-empty);
  - **Claude**: nothing extra — a fresh `claude -p` is always available and is the final fallback.
- **`bash`** on PATH (plus **`pgrep`** for the Codex path — it enforces one `codex exec` at a time,
  and **`python3`**, which the skill uses to verify the state file it writes).
  Present by default on **macOS and standard Linux**. **Windows: use WSL2** — native Windows isn't supported.

## Data & privacy

By default spec-debate sends the **full text of the spec** to the reviewer's provider: **OpenAI**
(Codex, plus files it reads in its workdir) or **Anthropic** (a fresh Claude, plus files it reads in its
workdir). For **opencode**, the first recipient is the provider/gateway configured in opencode — for
`opencode-go/*` model ids that is the **OpenCode Go** gateway, which relays to the model's vendor (e.g.
Moonshot for kimi, Zhipu for glm); a direct `provider/model` id goes to that provider. The skill names
the resolved provider in its report; if a fallback changed it from the one you named, it says so. For sensitive material,
opt into **privacy mode** ("privacy mode" / "don't send the code"): the reviewer then gets only an
approved abstracted summary — confidence marked limited — or the pass is declined. Don't put secrets in
the spec, and don't run the default mode on data you can't share with that provider.

> **Same-model note.** When the reviewer is a fresh Claude of your own model, a fresh instance removes
> anchoring but not correlated blind spots — prefer **codex** or **opencode** for true cross-provider
> independence. (Codex is the default, so this is the exception.)

## Install

Clone straight into your Claude Code skills folder:

```bash
git clone https://github.com/OlegTestov/spec-debate.git ~/.claude/skills/spec-debate
```

The skill is then available as `/spec-debate` in Claude Code (and triggers on the phrasings above).
To update later: `git -C ~/.claude/skills/spec-debate pull`.

SKILL.md resolves the helper scripts relative to its own folder, so any location Claude Code loads
skills from works. If you also get this skill through a plugin marketplace, keep only one copy to
avoid double registration. Layout:

```
spec-debate/
├── SKILL.md
├── README.md
├── README_ru.md
├── LICENSE
├── scripts/
│   ├── run_critique.sh          # dispatcher: codex | opencode | claude
│   └── run_codex_critique.sh    # hardened Codex adapter (called by the dispatcher)
├── evals/
│   └── evals.json
└── tests/                       # not needed at runtime; `bash tests/hermetic/run.sh` verifies an install
    ├── hermetic/                # dispatcher contract, reviewer CLIs stubbed — free, ~15s
    └── e2e/                     # triggering, fallback, real-debate quality (manual gate)
```

## Usage

```
/spec-debate                       # plan/spec from the current conversation; default reviewer (codex)
/spec-debate path/to/spec.md       # explicit path
спроси кими по этому плану           # route to opencode / kimi
пусть glm раскритикует spec.md       # route to opencode / glm
посоветуйся с опусом по плану         # route to a fresh Claude instance
/spec-debate path --max            # max reasoning depth (default high; slower) — codex→xhigh, opencode→max
```

Effort levels are **low / medium / high / max** and map per harness: codex spans all four (max→xhigh);
opencode is coarse (minimal / high / max, so medium≈high); claude has no effort knob. Want another
round? Invoke again — it picks up the state. You can add free-form instructions, e.g. "run 3
rounds" or "keep going until no significant findings remain".

## How it works (in brief)

1. **Picks the reviewer, mode, and spec.** Step 0 resolves the harness + model (above); a quick scope
   scan decides between a one-pass *prompt-only* consult and an *iterable spec*; for a task or code,
   Claude first drafts the spec / change-spec to a minimal shape (goal, non-goals, constraints,
   acceptance criteria, …) and names its **type and altitude**.
2. **Both models propose, independently.** Claude lists its own improvements; the reviewer proposes its
   own without seeing Claude's list (so it isn't anchored). The dispatcher `run_critique.sh <harness>`
   feeds the prompt via **stdin** — the document never lands on argv — preflights the CLI, and (for the
   Codex path) runs one `codex exec` at a time. *(One extra pass where the reviewer also rebuts Claude's
   list — on request (`thorough`) or automatically when Claude's own proposals carry major weight.)*
3. **Merges with veto.** Both lists — the reviewer's and Claude's own — go through one procedure: check
   each is real (re-read the section, `grep` referenced files/numbers), judge its value at the spec's
   altitude, then accept / partial / reject with a one-line reason (rejected own proposals are reported too).
4. **Applies surgical edits**, then re-reads the changed sections for self-consistency.
5. **Reports** (accepted / partial / rejected, naming the reviewer) and **saves state**, recommending
   STOP once only minor findings remain. For a code change-spec, applying it to the code is a separate
   post-debate step, reported apart from the debate.

## License

MIT. See [LICENSE](LICENSE).
