#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["jsonschema>=4.21"]
# ///
"""Enforce the traceability rule from specs/README.md.

Three checks:

  1. Structure   — every requirement heading is well formed, has an RFC 2119 keyword
                   and an `*Accept:*` line, and no ID is duplicated or out of order.
  2. Coverage    — every MUST in an `accepted` or `implemented` spec has at least one
                   test whose name contains its ID. Draft specs report but do not fail.
  3. Fixtures    — every `examples/*.json` validates against the matching schema in
                   `schema/`, by filename prefix.

Run:  uv run tools/spec-trace/spec_trace.py [--json]
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPECS = ROOT / "specs"

# `#### PRX-R-012 — Unknown actions fail closed`  (em dash or hyphen)
HEADING = re.compile(r"^####\s+(?P<id>[A-Z]{2,6}-R-\d{3})\s+[—-]\s+(?P<title>.+?)\s*$")
ID_ANYWHERE = re.compile(r"\b[A-Z]{2,6}-R-\d{3}\b")
ACCEPT = re.compile(r"^\*Accept:\*\s*(?P<text>.+)", re.S)
STATUS = re.compile(r"^\*\*Status:\*\*\s*(?P<status>[a-z ]+?)(?:\s*·|$)", re.M)
RFC2119 = ("MUST NOT", "MUST", "SHOULD NOT", "SHOULD", "MAY")

# Where tests live. Go and Python both name tests in a way that carries the ID.
TEST_GLOBS = ("**/*_test.go", "**/test_*.py", "**/*_test.py", "**/*.spec.ts")
SKIP_DIRS = {".git", "node_modules", "vendor", ".venv", "dist", "target"}


@dataclass
class Requirement:
    id: str
    title: str
    spec: str
    line: int
    keyword: str | None = None
    accept: str | None = None
    problems: list[str] = field(default_factory=list)


@dataclass
class Spec:
    slug: str
    path: Path
    status: str
    requirements: list[Requirement]


def parse_spec(path: Path) -> Spec:
    text = path.read_text(encoding="utf-8")
    m = STATUS.search(text)
    status = m.group("status").strip() if m else "unknown"

    lines = text.splitlines()
    reqs: list[Requirement] = []
    for i, line in enumerate(lines, 1):
        h = HEADING.match(line)
        if not h:
            continue
        req = Requirement(id=h["id"], title=h["title"], spec=path.parent.name, line=i)

        # Body runs to the next heading of any level.
        body: list[str] = []
        for nxt in lines[i:]:
            if nxt.startswith("#"):
                break
            body.append(nxt)
        blob = "\n".join(body)

        for kw in RFC2119:
            if re.search(rf"\b{kw}\b", blob):
                req.keyword = kw
                break
        if req.keyword is None:
            req.problems.append("no RFC 2119 keyword in body")

        for b in body:
            a = ACCEPT.match(b.strip())
            if a:
                req.accept = a["text"].strip()
                break
        if not req.accept:
            req.problems.append("missing *Accept:* line")

        reqs.append(req)

    # Duplicate / ordering checks.
    seen: dict[str, Requirement] = {}
    last = -1
    for r in reqs:
        if r.id in seen:
            r.problems.append(f"duplicate of line {seen[r.id].line}")
        seen[r.id] = r
        n = int(r.id.rsplit("-", 1)[1])
        if n <= last:
            r.problems.append(f"out of order (follows {last:03d})")
        last = n

    return Spec(slug=path.parent.name, path=path, status=status, requirements=reqs)


def collect_test_ids() -> dict[str, list[str]]:
    """Map requirement ID -> list of files whose test names mention it."""
    hits: dict[str, list[str]] = {}
    for pattern in TEST_GLOBS:
        for f in ROOT.glob(pattern):
            if any(p in SKIP_DIRS for p in f.parts):
                continue
            try:
                content = f.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            for line in content.splitlines():
                if not re.search(r"\b(func Test|def test_|it\(|test\()", line):
                    continue
                for rid in ID_ANYWHERE.findall(line):
                    hits.setdefault(rid, []).append(str(f.relative_to(ROOT)))
    return hits


def check_fixtures(spec_dir: Path) -> list[str]:
    schema_dir, ex_dir = spec_dir / "schema", spec_dir / "examples"
    if not ex_dir.is_dir():
        return []
    try:
        from jsonschema import Draft202012Validator
    except ImportError:
        return ["jsonschema not installed — fixture validation skipped"]

    validators = {}
    for s in schema_dir.glob("*.schema.json"):
        doc = json.loads(s.read_text(encoding="utf-8"))
        Draft202012Validator.check_schema(doc)
        validators[s.name.removesuffix(".schema.json")] = Draft202012Validator(doc)

    problems = []
    for fx in sorted(ex_dir.glob("*.json")):
        prefix = fx.stem.split("-", 1)[0]
        v = validators.get(prefix)
        if v is None:
            continue  # not every fixture is an instance of a schema
        for err in sorted(v.iter_errors(json.loads(fx.read_text(encoding="utf-8"))),
                          key=lambda e: list(e.path)):
            problems.append(f"{fx.name}: {list(err.path)} {err.message.splitlines()[0]}")
    return problems


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    args = ap.parse_args()

    specs = [parse_spec(p) for p in sorted(SPECS.glob("*/spec.md"))]
    tests = collect_test_ids()

    failures: list[str] = []
    report = []

    for spec in specs:
        enforced = spec.status in ("accepted", "implemented")
        musts = [r for r in spec.requirements if r.keyword in ("MUST", "MUST NOT")]
        untested = [r for r in musts if r.id not in tests]
        structural = [(r.id, p) for r in spec.requirements for p in r.problems]
        fixtures = check_fixtures(spec.path.parent)

        report.append({
            "spec": spec.slug, "status": spec.status, "enforced": enforced,
            "requirements": len(spec.requirements), "musts": len(musts),
            "tested": len(musts) - len(untested), "untested": [r.id for r in untested],
            "structural": structural, "fixtures": fixtures,
        })

        for rid, p in structural:
            failures.append(f"{spec.slug}: {rid}: {p}")
        for p in fixtures:
            failures.append(f"{spec.slug}: fixture: {p}")
        if enforced:
            for r in untested:
                failures.append(f"{spec.slug}: {r.id} is a {r.keyword} with no test carrying its ID")

    if args.json:
        print(json.dumps({"specs": report, "failures": failures}, indent=2))
        return 1 if failures else 0

    for r in report:
        mark = "enforced" if r["enforced"] else "advisory"
        print(f"\n{r['spec']}  [{r['status']}, {mark}]")
        print(f"  requirements {r['requirements']}   MUST {r['musts']}   "
              f"covered {r['tested']}/{r['musts']}")
        if r["untested"]:
            head = ", ".join(r["untested"][:8])
            more = f" (+{len(r['untested']) - 8} more)" if len(r["untested"]) > 8 else ""
            print(f"  no test: {head}{more}")
        for rid, p in r["structural"]:
            print(f"  STRUCTURE {rid}: {p}")
        for p in r["fixtures"]:
            print(f"  FIXTURE {p}")

    print()
    if failures:
        print(f"FAIL — {len(failures)} problem(s)")
        return 1
    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
