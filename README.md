**English** · [Русский](README_ru.md)

# spec-debate — a two-model debate over your plan, spec, or proposed solution

A skill for **Claude Code**. Once you've written a plan, spec, requirements doc, or technical
design, you run `/spec-debate`, and a **second model (OpenAI Codex)** starts tearing into it,
while Claude acts as the **editor with veto power**: it carefully verifies every objection,
applies only what genuinely improves it, and rejects the rest with a reason.

It's not only for finished specs: you can "consult Codex" mid-flight — the skill runs one round
and hands back an independent review with no state saved. If you decide to keep working with
Codex, it automatically creates the iterations file and switches to standard debate mode.

> A critic that's always obeyed is just a second author.
> A critic that's argued with produces a better result than either model alone.

By default, one invocation = one round: critique → veto → edits → report → saved state
(`.<name>.debate-state.json` next to the document). Need several rounds? Invoke again (it
continues where it left off), or just ask up front — "run 3 rounds" or "keep going until no
significant findings remain". Rejected findings are handed to Codex so it doesn't raise them
again. The built-in principle: a **better** result, not a **bigger** one — the skill actively
resists complexity creep.

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

spec-debate sends the **full text of the document** (and any files Codex reads in the workdir) to
OpenAI via the Codex CLI. Don't run it on material you can't share with OpenAI — secrets,
client/NDA data.

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

1. Finds the document and names its **type and altitude** (requirements / design / plan) — this sets the bar for the critique.
2. Runs Codex as a "relentless reviewer" strictly at that altitude (the helper script
   `run_codex_critique.sh` feeds the prompt via stdin — the document never lands on argv — and
   refuses to start a second `codex exec`: concurrent runs hang).
3. **Vets every finding**: checks that it's real (re-reads the section, `grep`s any referenced
   files/numbers) and judges its value at the document's altitude. Accept / partial / reject —
   each with a one-line reason.
4. Applies surgical edits, then re-reads the changed sections for self-consistency.
5. Writes a skimmable report (accepted / partial / rejected) and saves the round's state.

## License

MIT. See [LICENSE](LICENSE).
