#!/usr/bin/env python3
"""Check that every stocked pipeline has one reachable packaged reference card."""
from __future__ import annotations

import csv
from pathlib import Path
import re
import sys
from urllib.parse import unquote, urlsplit


def check(root: Path) -> list[str]:
    errors: list[str] = []
    refs = root / "skills/bioinfo-analyze/references"
    cards = refs / "pipelines"
    rows = list(csv.reader(
        (line for line in (root / "config/pipelines.tsv").read_text(encoding="utf-8").splitlines()
         if line and not line.startswith("#")), delimiter="\t"))
    if not rows or rows[0] != ["pipeline", "revision", "schema_checked", "note"]:
        return ["pipelines.tsv: expected unchanged four-column header"]
    names: set[str] = set()
    router = (refs / "pipeline-selection.md").read_text(encoding="utf-8")
    for lineno, row in enumerate(rows[1:], 2):
        if len(row) != 4:
            errors.append(f"pipelines.tsv data row {lineno}: expected four fields")
            continue
        name, revision, checked, note = row
        if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", name) or name in names:
            errors.append(f"pipelines.tsv data row {lineno}: invalid or duplicate name {name!r}")
        names.add(name)
        expected = f"skills/bioinfo-analyze/references/pipelines/{name}.md"
        if note != expected:
            errors.append(f"{name}: note must point to {expected}")
        if not (cards / f"{name}.md").is_file():
            errors.append(f"{name}: missing packaged card")
        if f"](pipelines/{name}.md)" not in router:
            errors.append(f"{name}: missing routing link")
        if not revision or not checked:
            errors.append(f"{name}: revision/schema_checked must remain populated")
    actual = {p.stem for p in cards.glob("*.md")}
    if actual != names:
        errors.append(f"card/stocked-set mismatch: extra={sorted(actual - names)}, missing={sorted(names - actual)}")
    for p in (cards / "stubs").glob("*.md"):
        if p.stem not in names:
            errors.append(f"{p.name}: stub policy has no stocked pipeline")
        elif (cards / p.name).is_file() and f"](stubs/{p.name})" not in (cards / p.name).read_text(encoding="utf-8"):
            errors.append(f"{p.name}: exact stub policy is not linked from its card")
    # Audit the modular pages, not historical run records or external links.
    pages = [refs / "pipeline-selection.md", refs / "host-runtime.md", refs / "intake-reuse.md",
             refs / "workflow-chains.md", refs / "repeat-expansion.md", refs / "selection-boundaries.md",
             *cards.rglob("*.md")]
    for p in pages:
        if not p.is_file():
            errors.append(f"missing reference: {p.relative_to(root)}")
            continue
        for target in re.findall(r"\[[^\]\n]+\]\(([^)\s]+)\)", p.read_text(encoding="utf-8")):
            uri = urlsplit(target)
            if uri.scheme or uri.netloc or not uri.path:
                continue
            dest = (p.parent / unquote(uri.path)).resolve()
            if not dest.is_relative_to(root.resolve()) or not dest.is_file():
                errors.append(f"{p.relative_to(root)}: broken local link {target}")
    return errors


if __name__ == "__main__":
    repo = Path(__file__).resolve().parent.parent
    findings = check(repo)
    for finding in findings:
        print(f"FAIL {finding}", file=sys.stderr)
    if findings:
        sys.exit(1)
    print("PASS: stocked set, four-column metadata, pipeline cards, stub routes and local links")
