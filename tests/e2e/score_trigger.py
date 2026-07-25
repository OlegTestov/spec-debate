#!/usr/bin/env python3
"""Score a triggering+routing run: for each case decide FIRED / QUIET, and where it routed.

FIRED means the model actually invoked the skill (a Skill tool_use naming spec-debate, or a Bash
call into the skill's own dispatcher). A text-only mention is recorded separately: the description
reached the model but it narrated instead of acting — signal, not a pass.

The route comes from what the stubbed reviewer CLIs recorded (argv + a stdin file proving a real
critique call, not just a catalog query), so "it said codex" and "it ran codex" can't be confused.

Isolation is asserted per case from the session's own init event: the candidate skill must be
loaded, with no user skills/plugins/MCP servers leaking in.
"""
import json
import pathlib
import sys

BUILTIN_MAX = 60  # a plain session lists ~45 built-ins; far more means user skills leaked in


def read_events(p):
    for line in p.read_text(errors="replace").splitlines():
        line = line.strip()
        if line.startswith("{"):
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


def after(args, flag):
    if flag in args:
        i = args.index(flag)
        if i + 1 < len(args):
            return args[i + 1]
    return None


def route_of(logdir):
    """What the stubs saw. A .stdin file means the CLI was actually fed a critique prompt."""
    def argv(cli):
        f = logdir / f"{cli}.argv"
        return f.read_text().splitlines() if f.exists() else []

    def ran(cli):
        # a recorded stdin AND a critique-shaped argv: an auth probe like `codex login status` is not a run
        shape = {"codex": "exec", "opencode": "run", "claude": "-p"}[cli]
        return (logdir / f"{cli}.stdin").exists() and shape in argv(cli)

    if ran("codex"):
        eff = next((a.split("=", 1)[1].strip('"') for a in argv("codex") if "model_reasoning_effort" in a), "")
        return "codex" if eff in ("high", "") else f"codex+{eff}"
    if ran("opencode"):
        m = after(argv("opencode"), "-m") or "?"
        return "opencode:" + m.split("/")[-1]
    if ran("claude"):
        return "claude:" + (after(argv("claude"), "--model") or "default")
    return "none"


def score_case(d):
    out = d / "out.jsonl"
    base = {"fired": None, "mentioned_only": False, "isolation": {}, "cost": 0.0, "turns": 0,
            "route": route_of(d / "log"), "text": "no output produced"}
    if not out.exists():
        return base
    fired, isolation, texts, cost, turns = False, {}, [], 0.0, 0
    for e in read_events(out):
        if e.get("type") == "system" and e.get("subtype") == "init":
            sc = e.get("slash_commands") or []
            isolation = {"candidate_loaded": any("spec-debate" in s for s in sc),
                         "commands": len(sc), "mcp": len(e.get("mcp_servers") or []),
                         "model": e.get("model")}
        if e.get("type") == "assistant":
            turns += 1
            for blk in e.get("message", {}).get("content", []) or []:
                if blk.get("type") == "tool_use":
                    name, inp = blk.get("name") or "", json.dumps(blk.get("input") or {}, ensure_ascii=False)
                    if name == "Skill" and "spec-debate" in inp:
                        fired = True
                    if name == "Bash" and ("run_critique.sh" in inp or "run_codex_critique.sh" in inp):
                        fired = True
                if blk.get("type") == "text":
                    texts.append(blk["text"])
        if e.get("type") == "result":
            cost = e.get("total_cost_usd") or 0.0
    blob = " ".join(texts).lower()
    base.update({"fired": fired, "mentioned_only": ("spec-debate" in blob and not fired),
                 "isolation": isolation, "cost": cost, "turns": turns,
                 "text": (texts[-1][:200].replace("\n", " ") if texts else "")})
    return base


def main(art):
    art = pathlib.Path(art)
    rows, hard, soft, route_fail, cost, iso_problems = [], 0, 0, 0, 0.0, []
    for d in sorted(p for p in art.iterdir() if p.is_dir() and (p / "meta.tsv").exists()):
        expect, name, want_route = (d / "meta.tsv").read_text().strip().split("\t")
        r = score_case(d)
        want_fire = expect.endswith("FIRE") and not expect.endswith("NOFIRE")
        fire_ok = (r["fired"] is True) == want_fire
        # A fired case that never reached a reviewer within the turn cap is not a routing verdict.
        # Routing is only a verdict when the skill actually fired: a direct CLI call the agent made on
        # its own (e.g. the user asked for raw output) is not this skill routing anywhere.
        route_ok = (not r["fired"]) or (r["route"] == want_route) or (want_fire and r["route"] == "none")
        route_capped = want_fire and fire_ok and r["route"] == "none"
        ok = fire_ok and route_ok
        if not fire_ok:
            soft += 1 if expect.startswith("SOFT") else 0
            hard += 0 if expect.startswith("SOFT") else 1
        elif not route_ok:
            route_fail += 1
        cost += r["cost"] or 0
        iso = r.get("isolation") or {}
        if not iso.get("candidate_loaded") or iso.get("mcp") or (iso.get("commands") or 0) > BUILTIN_MAX:
            iso_problems.append(f"{name}: {iso}")
        rows.append((ok, expect, name, want_route, r, route_capped))

    for ok, expect, name, want_route, r, capped in rows:
        mark = "ok  " if ok else ("SOFT" if expect.startswith("SOFT") else "FAIL")
        got = "FIRED" if r["fired"] else ("mention-only" if r["mentioned_only"] else "quiet")
        route = r["route"] + (" (turn-capped)" if capped else "")
        print(f"  {mark} {name:26s} want={expect:11s}/{want_route:17s} got={got:12s}/{route:20s} "
              f"turns={r['turns']} ${r['cost']:.3f}")
        if not ok:
            print(f"       ↳ {r['text']}")

    n = len(rows)
    print(f"\ntriggering: {n - hard - soft - route_fail}/{n} fully as expected — "
          f"{hard} trigger fail, {route_fail} route fail, {soft} soft/ambiguous, ~${cost:.2f}")
    if iso_problems:
        print("ISOLATION PROBLEMS:")
        for p in iso_problems:
            print("  ", p)
    else:
        print("isolation verified per case from init events: candidate skill loaded; no user skills/plugins/MCP")
    return 1 if (hard or route_fail or iso_problems) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "."))
