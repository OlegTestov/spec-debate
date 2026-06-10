**English** · [Русский](README_ru.md)

# spec-debate — a two-model debate over your plan, spec, or proposed solution

A skill for **Claude Code**. Each round, **two models independently propose improvements** — Claude
and a **second model (OpenAI Codex)** — and Claude acts as the **editor with veto power**: it verifies
every proposal (its own and Codex's), keeps only what genuinely improves the work, and rejects the rest
with a reason.

The thing being improved is **always a spec**, and there are three ways in:

- **a task** → Claude drafts a solution spec, then debates it;
- **code to improve** → Claude drafts a *change-spec*; the code itself isn't touched during the debate —
  it's applied afterwards, as a separate step;
- **an existing spec / plan / design** → it's taken as-is.

You can also just "consult Codex" on a bounded question mid-flight — the skill runs a single
**prompt-only** pass and hands back an independent take, vetted by Claude, with no state saved. If you
decide to keep going, it materializes the spec file and switches to standard debate mode.

> A critic that's always obeyed is just a second author.
> A critic that's argued with produces a better result than either model alone.

By default, one invocation = one round: propose → veto → edits → report → saved state
(`.<name>.debate-state.json` next to the document). Need several rounds? Invoke again (it continues
where it left off), or ask up front — "run 3 rounds" or "keep going until no significant findings
remain". Settled findings are handed to Codex so it doesn't raise them again. The built-in principle:
a **better** result, not a **bigger** one — the skill actively resists complexity creep.

## Requirements

- **Claude Code** (Anthropic's CLI).
- **OpenAI Codex CLI** — installed and authenticated:
  ```bash
  npm install -g @openai/codex
  codex login status    # auth check (if not logged in: codex login)
  ```
  You specifically need an *independent* second engine — that's the whole point of the debate.
- **`bash` and `pgrep`** on PATH — used by the helper script. Present by default on **macOS and standard Linux**.
  **Windows: use WSL2** (a normal Linux environment) — that's the supported path. Native Windows isn't supported:
  under Git Bash `pgrep` is typically absent so the helper fail-closes, and without Git Bash there's no `bash` to
  run the script at all.

## Data & privacy

By default spec-debate sends the **full text of the spec** (plus any files Codex reads in the workdir)
to OpenAI via the Codex CLI. For sensitive material, opt into **privacy mode** ("privacy mode" /
"don't send the code"): Codex then gets only an approved abstracted summary — its confidence marked
limited — or the pass is declined if the question can't be judged without the material. Don't put
secrets in the spec, and don't run the default mode on data you can't share with OpenAI.

## Install

The simplest way — if your Claude Code can run shell commands — is to ask it to install the skill:

> Install https://github.com/OlegTestov/spec-debate into ~/.claude/skills/spec-debate

It'll clone the repo into your skills folder. If that doesn't work, clone it manually:

```bash
git clone https://github.com/OlegTestov/spec-debate ~/.claude/skills/spec-debate
```

The skill folder can live in either of:

- `~/.claude/skills/spec-debate/` — personal, available in every project;
- `<project>/.claude/skills/spec-debate/` — inside a specific repo (can be committed).

It works in either location without edits: SKILL.md resolves the helper script relative to its own
folder. Layout:

```
spec-debate/
├── SKILL.md
├── README.md
├── README_ru.md
├── LICENSE
├── scripts/
│   └── run_codex_critique.sh
└── evals/
    └── evals.json
```

## Usage

```
/spec-debate                       # target = the plan/spec from the current conversation
/spec-debate path/to/spec.md       # explicit path
/spec-debate path --xhigh          # maximum Codex reasoning depth (default is high); noticeably slower
```

Want another round? Just invoke the skill again — it picks up the state and continues. You can
also add free-form instructions, e.g. "run 3 rounds" or "keep going until no significant findings
remain".

## How it works (in brief)

1. **Picks the mode and resolves the spec.** A quick scope scan decides between a one-pass *prompt-only*
   consult and an *iterable spec*; for a task or code, Claude first drafts the spec / change-spec to a
   minimal shape (goal, non-goals, constraints, acceptance criteria, …) and names its **type and altitude**.
2. **Both models propose, independently.** Claude lists its own improvements; Codex proposes its own
   without seeing Claude's list (so it isn't anchored). The helper `run_codex_critique.sh` feeds the
   prompt via stdin — the document never lands on argv — and refuses to start a second `codex exec`
   (concurrent runs hang). *(Optional `thorough`: one extra pass where Codex also rebuts Claude's list.)*
3. **Merges with veto.** Both lists — Codex's and Claude's own — go through one procedure: check each is
   real (re-read the section, `grep` referenced files/numbers), judge its value at the spec's altitude,
   then accept / partial / reject with a one-line reason (rejected own proposals are reported too).
4. **Applies surgical edits**, then re-reads the changed sections for self-consistency.
5. **Reports** (accepted / partial / rejected) and **saves state**, recommending STOP once only minor
   findings remain. For a code change-spec, applying it to the code is a separate post-debate step,
   reported apart from the debate.

## License

MIT. See [LICENSE](LICENSE).
