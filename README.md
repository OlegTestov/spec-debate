**English** · [Русский](README_ru.md)

# spec-debate — a two-model debate over your document

A skill for **Claude Code**. Once you've written a spec / requirements doc / technical design /
implementation plan, you run `/spec-debate`, and a **second model (OpenAI Codex)** starts tearing
into the document, while Claude acts as the **editor with veto power**: it verifies every objection
against the actual file (by reading and `grep`, not on faith), applies only what genuinely improves
the document, and rejects the rest with a reason.

> A critic that's always obeyed is just a second author.
> A critic that's argued with produces a better document than either model alone.

One invocation = one round. State is written to `.<name>.debate-state.json` next to the document,
so re-invoking continues the debate from where it left off — and rejected findings are handed to
Codex so it doesn't raise them again. The built-in principle: a **better** document, not a
**bigger** one — the skill actively resists complexity creep.

## Requirements

- **Claude Code** (Anthropic's CLI).
- **OpenAI Codex CLI** — installed and authenticated:
  ```bash
  npm install -g @openai/codex
  codex login status    # auth check (if not logged in: codex login)
  ```
  You specifically need an *independent* second engine — that's the whole point of the debate.
- **`bash` and `pgrep`** on PATH — used by the helper script. Present by default on **macOS and standard Linux**.
  **Windows: use WSL2** (a normal Linux environment). Native-Windows Claude Code runs the script via Git Bash,
  which ships no `pgrep` — the helper then fail-closes with a clear error rather than running unguarded.

## Data & privacy

spec-debate sends the **full text of the document** (and any files Codex reads in the workdir) to
OpenAI via the Codex CLI. Don't run it on material you can't share with OpenAI — secrets,
client/NDA data.

## Install

The fastest way is to clone straight into your skills folder:

```bash
git clone https://github.com/OlegTestov/spec-debate ~/.claude/skills/spec-debate
```

Or place the skill folder manually in one of:

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
/spec-debate                       # target = the document from the current conversation
/spec-debate path/to/spec.md       # explicit path
/spec-debate --high                # Codex reasoning depth: high (default)
/spec-debate path --xhigh          # maximum — noticeably slower
```

Want another round? Just invoke the skill again — it picks up the state and continues.

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
