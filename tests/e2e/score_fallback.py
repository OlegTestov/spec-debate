#!/usr/bin/env python3
"""Score a fallback/universality run.

Stricter than the triggering scorer in one way that matters: when the expected route is "none"
because the user NAMED a harness that isn't installed, the run must both (a) call no reviewer at all
and (b) say so — a silent substitution with a different provider is the failure mode being tested.
"""
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from score_trigger import route_of, score_case  # noqa: E402


def main(art):
    art = pathlib.Path(art)
    problems, lines = [], []
    for d in sorted(p for p in art.iterdir() if p.is_dir() and (p / "meta.tsv").exists()):
        _, name, want_route = (d / "meta.tsv").read_text().strip().split("\t")
        must = (d / "must_text.txt").read_text().strip()
        r = score_case(d)
        route = route_of(d / "log")
        ok = route == want_route
        note = ""
        if must:
            full = (d / "out.jsonl").read_text(errors="replace")   # the whole transcript, not just the last message
            if not re.search(must, full):
                ok = False
                note = "  (never told the user the named CLI is missing)"
        lines.append(f"  {'ok  ' if ok else 'FAIL'} {name:24s} want={want_route:18s} got={route:18s}"
                     f" fired={r['fired']} ${r['cost']:.3f}{note}")
        if not ok:
            problems.append(name)
            lines.append(f"       ↳ {r['text'][:180]}")
    print("\n".join(lines))
    n = len(lines) - sum(1 for x in lines if x.strip().startswith("↳"))
    print(f"\nfallback: {n - len(problems)}/{n} as expected")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "."))
