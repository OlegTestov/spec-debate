#!/usr/bin/env python3
"""Static checks on the shipped files — the class of drift that survives every runtime test.

Subcommands (each exits 0 = pass, 1 = fail with a reason on stderr):
  desc-len <SKILL.md> <max>   the YAML description must fit the plugin-manifest limit
  refs <repo>                 every helper script SKILL.md invokes must exist
  layout <README> <repo>      every file drawn in the README layout block must exist
  json <file>                 the file must parse as one JSON document
"""
import json
import pathlib
import re
import sys


def fail(msg):
    print(f"check_docs: {msg}", file=sys.stderr)
    return 1


def frontmatter(p):
    text = p.read_text()
    m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    return (m.group(1) if m else ""), text


def description_of(skill):
    """The description as a YAML parser sees it — the same view the marketplace validator measures.

    Falls back to a regex when PyYAML is absent (CI images without it): that fallback understands the
    plain and folded (`>-`) forms only, so it can disagree with the validator if the field is ever
    rewritten as a literal `|` block. The parser is preferred precisely to keep the two in step.
    """
    fm, _ = frontmatter(pathlib.Path(skill))
    try:
        import yaml
        val = (yaml.safe_load(fm) or {}).get("description")
        if isinstance(val, str):
            return " ".join(val.split()), "yaml"
    except ImportError:
        pass
    m = re.search(r"^description:\s*(?:>-?\s*\n((?:[ \t]+.*\n?)+)|(.+))", fm, re.M)
    if not m:
        return None, "regex"
    raw = m.group(1) if m.group(1) else m.group(2)
    return " ".join(raw.split()), "regex"


def desc_len(skill, limit):
    try:
        cap = int(limit)
    except ValueError:
        return fail(f"limit must be an integer, got {limit!r}")
    desc, how = description_of(skill)
    if desc is None:
        return fail("no description in the frontmatter")
    n = len(desc)
    print(f"description: {n} chars (limit {cap}, measured via {how})")
    return 0 if n <= cap else fail(f"description is {n} chars, over the {cap} limit")


def refs(repo):
    repo = pathlib.Path(repo)
    named = set(re.findall(r"[\w./-]*?(run_[a-z_]+\.sh)", (repo / "SKILL.md").read_text()))
    missing = [n for n in named if not (repo / "scripts" / n).exists()]
    print(f"scripts referenced by SKILL.md: {sorted(named) or 'none'}")
    return fail(f"SKILL.md invokes missing scripts: {missing}") if missing else 0


def layout(readme, repo):
    """Every name drawn in the README tree must exist. Names only, not their place in the tree: a file
    drawn under the wrong parent still passes. That is deliberate — the check exists to catch a README
    promising files an install does not carry, which is the failure that actually happened."""
    repo, text = pathlib.Path(repo), pathlib.Path(readme).read_text()
    block = re.search(r"```\n(spec-debate/\n(?:.*\n)*?)```", text)
    if not block:
        return fail("no layout block found in the README")
    names = re.findall(r"[├└]── ([\w.-]+)", block.group(1))
    files = {p.name for p in repo.rglob("*") if p.is_file()}
    dirs = {p.name for p in repo.rglob("*") if p.is_dir()}
    missing = [n for n in names if n not in files and n not in dirs]
    print(f"layout entries: {len(names)}")
    return fail(f"README layout lists things that do not exist: {missing}") if missing else 0


def main(argv):
    if len(argv) < 2:
        return fail("usage: check_docs.py <subcommand> [args]")
    cmd, args = argv[1], argv[2:]
    try:
        if not args:
            return fail(f"{cmd}: missing argument(s)")
        if cmd == "desc-len":
            return desc_len(*args)
        if cmd == "refs":
            return refs(*args)
        if cmd == "layout":
            return layout(*args)
        if cmd == "json":
            json.loads(pathlib.Path(args[0]).read_text())
            return 0
    except (TypeError, IndexError, ValueError, OSError, json.JSONDecodeError) as ex:
        return fail(f"{cmd}: {ex}")
    return fail(f"unknown subcommand {cmd!r}")


if __name__ == "__main__":
    sys.exit(main(sys.argv))
