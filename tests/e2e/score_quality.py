#!/usr/bin/env python3
"""Score a quality run against the planted-defect answer keys.

Coverage is counted from what the debate PRODUCED — its prose, the edits it applied, and the saved
state — never from re-reading the seeded artifact, whose own wording would echo the input and inflate
the score. Edits count because an applied fix is evidence the defect was surfaced; the seeds avoid the
vocabulary of their fixes precisely so that a keyword hit means something.

Coverage alone is not trustworthy, though: Claude contributes findings of its own (`source: own`), so a
scenario could score full marks with the reviewer never called. Hence expect_reviewer — the recorded
prompts must show the right harness actually running, at least once per round.

Beyond that, the checks that matter are the promises: code untouched in CODE mode, no source or secret
in the prompts under privacy mode, a state file that parses, and no stray files in the repo.
"""
import hashlib
import json
import pathlib
import sys


def read_events(p):
    for line in p.read_text(errors="replace").splitlines():
        if line.startswith("{"):
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


def session_text(d):
    """All assistant prose plus the text of every edit it made — the debate's own report surface."""
    out = []
    for e in read_events(d / "out.jsonl"):
        if e.get("type") == "assistant":
            for blk in e.get("message", {}).get("content", []) or []:
                if blk.get("type") == "text":
                    out.append(blk["text"])
                elif blk.get("type") == "tool_use":
                    out.append(json.dumps(blk.get("input") or {}, ensure_ascii=False))
        if e.get("type") == "result" and e.get("result"):
            out.append(str(e["result"]))
    return "\n".join(out)


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest() if p.exists() else None


def reviewer_runs(logdir):
    """Critique calls that actually produced a critique, per harness.

    A call counts only if the CLI was invoked in critique shape (not a probe — proxy.sh records only
    real calls anyway) AND it wrote something back. A provider that refuses — out of balance,
    rate-limited — still receives the prompt and exits 0 with empty output, so counting sent prompts
    would credit the debate with coverage that came from Claude's own findings.
    """
    shape = {"codex": "exec", "opencode": "run", "claude": "-p"}
    runs = {}
    for stdin in sorted(logdir.glob("*.stdin")):
        cli = stdin.name.split("-")[0]
        args = (logdir / (stdin.stem + ".argv"))
        argv = args.read_text().splitlines() if args.exists() else []
        reply = logdir / (stdin.stem + ".stdout")
        answered = reply.exists() and reply.stat().st_size > 0
        if shape.get(cli) in argv and stdin.stat().st_size > 0 and answered:
            runs.setdefault(cli, []).append(stdin)
    return runs


def main(art):
    art = pathlib.Path(art)
    keys = json.loads((pathlib.Path(__file__).parent / "fixtures/answers.json").read_text())
    problems, lines = [], []

    for d in sorted(p for p in art.iterdir() if p.is_dir() and (p / "meta.txt").exists()):
        name = (d / "meta.txt").read_text().strip()
        key = keys.get(name)
        if not key:
            problems.append(f"{name}: no answer key")
            continue
        cwd, before = d / "cwd", d / "cwd-before"
        text = session_text(d)
        low = text.lower()

        states = list(cwd.glob(".*.debate-state.json")) + list(cwd.glob("*.debate-state.json"))
        state_raw = states[0].read_text() if states else ""
        hay = low + "\n" + state_raw.lower()

        hits = [dfct["id"] for dfct in key["defects"] if any(k.lower() in hay for k in dfct["any"])]
        missed = [dfct["id"] for dfct in key["defects"] if dfct["id"] not in hits]
        lines.append(f"\n=== {name}")
        lines.append(f"  defect coverage: {len(hits)}/{len(key['defects'])}"
                     + (f"   MISSED: {', '.join(missed)}" if missed else ""))

        # the reviewer must have actually run, with the harness the prompt asked for
        want_rev = key.get("expect_reviewer")
        runs = reviewer_runs(d / "log")
        if want_rev:
            got = {cli: len(v) for cli, v in runs.items()}
            n = len(runs.get(want_rev["harness"], []))
            lines.append(f"  reviewer runs that answered: {got or 'NONE'} "
                         f"(want >={want_rev['min_prompts']} on {want_rev['harness']})")
            if n < want_rev["min_prompts"]:
                problems.append(f"{name}: expected >={want_rev['min_prompts']} {want_rev['harness']} critique "
                                f"call(s) that returned something, recorded {n} — the coverage number "
                                f"would be Claude's own findings, not the debate's")
            for cli in runs:
                if cli != want_rev["harness"]:
                    problems.append(f"{name}: critique also ran on '{cli}', but the request named "
                                    f"{want_rev['harness']}")

        # state file must parse as ONE json document, and carry the rounds we asked for
        if states:
            try:
                st = json.loads(state_raw)
                rounds = st.get("rounds") or st.get("round") or []
                nrounds = len(rounds) if isinstance(rounds, list) else rounds
                lines.append(f"  state: {states[0].name} parses, rounds={nrounds}")
                want = key.get("want_state_rounds")
                if want and (not isinstance(nrounds, int) or nrounds < want):
                    problems.append(f"{name}: asked for {want} rounds, state records {nrounds}")
            except json.JSONDecodeError as ex:
                problems.append(f"{name}: state file is not valid JSON ({ex})")
        elif key.get("want_state_rounds"):
            problems.append(f"{name}: no debate-state file was written")

        # CODE mode must not touch the code during the debate
        if key.get("code_must_be_unchanged"):
            f = key["code_must_be_unchanged"]
            same = sha(cwd / f) == sha(before / f)
            lines.append(f"  code untouched ({f}): {'yes' if same else 'NO — it was edited'}")
            if not same:
                problems.append(f"{name}: {f} was modified during the debate")
        if key.get("changespec_required"):
            new_md = [p.name for p in cwd.glob("*.md") if not (before / p.name).exists()]
            lines.append(f"  change-spec drafted: {new_md or 'NONE'}")
            if not new_md:
                problems.append(f"{name}: no change-spec file was drafted")
            else:
                body = (cwd / new_md[0]).read_text().lower()
                if not any(w in body for w in ("acceptance", "criteri", "test", "verif")):
                    problems.append(f"{name}: change-spec has no acceptance criteria / verification")

        # privacy mode: what actually went over the wire
        forbidden = key.get("must_not_appear_in_prompts") or []
        if forbidden:
            sent = [f for v in runs.values() for f in v]
            leaks = [(p.name, s) for p in sent for s in forbidden if s in p.read_text(errors="replace")]
            lines.append(f"  prompts recorded: {len(sent)}; leaks: {leaks or 'none'}")
            if not sent:
                problems.append(f"{name}: no reviewer prompt was recorded — the reviewer never ran")
            for pname, s in leaks:
                problems.append(f"{name}: PRIVACY LEAK — {s[:32]!r} found in {pname}")

        # repo hygiene + growth
        status = (d / "git-status.txt").read_text().strip().splitlines()
        stray = [s for s in status if not any(t in s for t in (".md", ".py", "debate-state"))]
        lines.append(f"  git status: {len(status)} entries" + (f"  STRAY: {stray}" if stray else ""))
        art_name = key.get("artifact")
        if art_name and (before / art_name).exists() and (cwd / art_name).exists():
            b = len((before / art_name).read_text().splitlines())
            a = len((cwd / art_name).read_text().splitlines())
            lines.append(f"  {art_name}: {b} → {a} lines")

    print("\n".join(lines))
    print("\n" + ("problems:\n  " + "\n  ".join(problems) if problems else "no promise violations found"))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "."))
