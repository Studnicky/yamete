#!/usr/bin/env python3
"""Resolve and validate Tests/Mutation/mutation-catalog.json against the
live test surface.

Each catalog entry names an `expectedFailingTest` of the form
`<XCTestCase subclass>/<method>`. The mutation runner passes this to
`swift test --filter` to find the test that should fail when the
mutation lands. When the test class gets renamed or the method moves
between suites, the filter resolves to zero tests, the empty test set
"passes", and the runner reports the mutation as ESCAPED — a false
negative that hides real coverage gaps.

This script walks `Tests/` for `final class <X>: XCTestCase` blocks
and `func test*(...)` methods inside them, builds a method-to-class
map, then either:

  * `validate` mode (default): refuse the run if any catalog entry's
    `expectedFailingTest` cannot be resolved to a live class+method.
    Used by `make mutate-pr` and by CI to catch drift before the
    mutation runner reports false negatives.
  * `--fix` mode: rewrite each drifting entry's `expectedFailingTest`
    to use the live class. Refuses to fix entries whose method appears
    in multiple classes (ambiguous) or doesn't exist anywhere in the
    test surface (developer must resolve manually).

Run from the repository root.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

CLASS_BASE_RE = re.compile(r"^\s*(?:public|internal|fileprivate|private)?\s*(?:final\s+)?class\s+(\w+)\s*:\s*([\w\s,]+?)\s*\{", re.MULTILINE)
FUNC_RE = re.compile(r"^\s*(?:public|internal|fileprivate|private|@MainActor)?\s*func\s+(test\w+)\s*\(", re.MULTILINE)

REPO_ROOT = Path(__file__).resolve().parent.parent
TESTS_DIR = REPO_ROOT / "Tests"
CATALOG_PATH = REPO_ROOT / "Tests" / "Mutation" / "mutation-catalog.json"


def discover_tests() -> dict[str, list[str]]:
    """Walk Tests/ and build a {method-name: [class-name, ...]} map.

    Two passes. Pass 1 collects every `final class X: ...` declaration
    along with its base-class names; pass 2 walks the inheritance graph
    to find every class that ultimately extends `XCTestCase` (directly
    or transitively through helper bases like `IntegrationTestCase`),
    then enumerates `func test*(...)` methods inside each.

    Methods are scoped per class by tracking brace depth from the
    class opening brace.
    """
    declarations: list[tuple[str, list[str], str]] = []  # (class_name, [base_names], class_body)
    for swift in TESTS_DIR.rglob("*.swift"):
        if "__Snapshots__" in swift.parts:
            continue
        text = swift.read_text(encoding="utf-8", errors="replace")
        for class_match in CLASS_BASE_RE.finditer(text):
            class_name = class_match.group(1)
            base_names = [b.strip() for b in class_match.group(2).split(",") if b.strip()]
            body = _extract_block(text, class_match.end() - 1)
            declarations.append((class_name, base_names, body))

    # Walk the inheritance graph to find every class that extends
    # XCTestCase. Seed with classes that name XCTestCase directly,
    # then iterate until the set stabilises.
    bases_by_class: dict[str, list[str]] = {name: bases for name, bases, _ in declarations}
    test_classes: set[str] = set()
    grew = True
    while grew:
        grew = False
        for name, bases in bases_by_class.items():
            if name in test_classes:
                continue
            for b in bases:
                if b == "XCTestCase" or b in test_classes:
                    test_classes.add(name)
                    grew = True
                    break

    method_to_classes: dict[str, list[str]] = defaultdict(list)
    for class_name, _bases, body in declarations:
        if class_name not in test_classes:
            continue
        for func_match in FUNC_RE.finditer(body):
            method_to_classes[func_match.group(1)].append(class_name)
    return method_to_classes


def _extract_block(text: str, start: int) -> str:
    """Return the substring spanning a balanced `{...}` whose opening
    brace is the next non-whitespace character at or after `start`.
    """
    i = start
    while i < len(text) and text[i] != "{":
        i += 1
    if i == len(text):
        return ""
    depth = 0
    body_start = i + 1
    j = i
    while j < len(text):
        ch = text[j]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return text[body_start:j]
        j += 1
    return text[body_start:]


def parse_filter(value: str) -> tuple[str, str]:
    """Split `Class/method`, `Class.method`, or bare `method` into
    `(class_or_empty, method)`. Bare-method entries return `("", method)`.
    """
    for sep in ("/", "."):
        if sep in value:
            cls, _, method = value.rpartition(sep)
            return cls, method
    return "", value


def resolve(catalog: list[dict], method_map: dict[str, list[str]]) -> list[dict]:
    """For each catalog entry, classify its `expectedFailingTest`:

    * `ok`             — references a live class+method
    * `fixable`        — method exists in exactly one class, but the
                         catalog names a different (or empty) class
    * `ambiguous`      — method exists in multiple classes; the catalog
                         must disambiguate manually
    * `missing`        — method doesn't exist in any test class

    Returns the list of report dicts in input order so callers can
    print and act on the diagnoses.
    """
    report = []
    for entry in catalog:
        raw = entry.get("expectedFailingTest", "")
        cls, method = parse_filter(raw)
        live_classes = method_map.get(method, [])
        diagnosis = {
            "id": entry.get("id"),
            "raw": raw,
            "namedClass": cls,
            "method": method,
            "liveClasses": live_classes,
        }
        if not live_classes:
            diagnosis["status"] = "missing"
        elif cls in live_classes:
            diagnosis["status"] = "ok"
        elif len(live_classes) == 1:
            diagnosis["status"] = "fixable"
            diagnosis["resolvedClass"] = live_classes[0]
        else:
            diagnosis["status"] = "ambiguous"
        report.append(diagnosis)
    return report


def render_diagnostics(report: list[dict]) -> str:
    lines = []
    drift = [d for d in report if d["status"] != "ok"]
    if not drift:
        return ""
    lines.append(f"mutation catalog drift — {len(drift)} entry(s) need attention:")
    for d in drift:
        prefix = f"  [{d['id']}]"
        if d["status"] == "fixable":
            lines.append(f"{prefix} {d['raw']} → {d['resolvedClass']}/{d['method']}")
        elif d["status"] == "ambiguous":
            opts = ", ".join(d["liveClasses"])
            lines.append(f"{prefix} {d['raw']} ambiguous — method '{d['method']}' lives in: {opts}")
        elif d["status"] == "missing":
            lines.append(f"{prefix} {d['raw']} unresolved — method '{d['method']}' has no live class")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fix", action="store_true",
                        help="Rewrite catalog entries whose method exists in exactly one class.")
    args = parser.parse_args()

    method_map = discover_tests()
    with CATALOG_PATH.open("r", encoding="utf-8") as f:
        catalog_doc = json.load(f)
    catalog = catalog_doc.get("mutations", [])

    report = resolve(catalog, method_map)
    diagnostics = render_diagnostics(report)
    drift = [d for d in report if d["status"] != "ok"]

    if not drift:
        print(f"mutation catalog: {len(catalog)} entries, all expectedFailingTest references resolve to live tests")
        return 0

    print(diagnostics)
    if not args.fix:
        return 1

    fixed = 0
    blocked = 0
    for entry, diag in zip(catalog, report):
        if diag["status"] == "fixable":
            entry["expectedFailingTest"] = f"{diag['resolvedClass']}/{diag['method']}"
            fixed += 1
        elif diag["status"] in ("ambiguous", "missing"):
            blocked += 1

    with CATALOG_PATH.open("w", encoding="utf-8") as f:
        json.dump(catalog_doc, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(f"\n--fix: rewrote {fixed} entry(s); {blocked} entry(s) still need manual resolution")
    return 0 if blocked == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
