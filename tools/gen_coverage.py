#!/usr/bin/env python3
"""gen_coverage.py — regenerate the coverage table in docs/index.md.

The table is derived from the filesystem so it can never drift from what
actually exists (conventions rule 4, profile/doc lockstep):

  captured  footprint + raw profile exist
  reviewed  a <distro>-access.yml exists, VERIFIED: pending
  verified  that profile carries a real VERIFIED: <date> stamp
  N/A — …   the matrix cell says so (reason included)

Run it after a capture or verify pass; CI can run it with --check.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent
INDEX = REPO / "docs" / "index.md"
START = "<!-- coverage:start -->"
END = "<!-- coverage:end -->"


def cell(app: str, distro: str, spec: dict) -> str:
    if "na" in spec:
        return f"N/A — {spec['na'].split('—')[0].strip()[:34]}"
    reviewed = REPO / "profiles" / app / f"{distro}-access.yml"
    raw = REPO / "profiles" / app / f"{distro}-raw.yml"
    if reviewed.exists():
        head = reviewed.read_text()[:2000]
        m = re.search(r"VERIFIED:\s*(\S+)", head)
        if m and m.group(1) != "pending":
            return "**verified**"
        return "reviewed"
    return "captured" if raw.exists() else "—"


def main() -> int:
    matrix = yaml.safe_load((REPO / "matrix.yml").read_text())
    distros = list(matrix["distros"])
    rows = ["| App | " + " | ".join(distros) + " | Dev doc | Ops doc | Role eval |",
            "| --- | " + " | ".join("---" for _ in distros) + " | --- | --- | --- |"]
    for app, cells in matrix["apps"].items():
        vals = [cell(app, d, cells.get(d) or {}) for d in distros]
        def link(kind: str, path: Path, label: str) -> str:
            return f"[{label}]({path.relative_to(REPO / 'docs')})" if path.exists() else "—"
        dev = link("dev", REPO / "docs" / "apps" / app / "dev.md", "dev")
        ops = link("ops", REPO / "docs" / "apps" / app / "ops.md", "ops")
        ev = link("eval", REPO / "docs" / "role-evals" / f"{app}.md", "eval")
        rows.append(f"| {app} | " + " | ".join(vals) + f" | {dev} | {ops} | {ev} |")
    table = "\n".join(rows)

    text = INDEX.read_text()
    if START not in text:
        print(f"{INDEX}: missing {START} marker", file=sys.stderr)
        return 2
    new = re.sub(f"{re.escape(START)}.*?{re.escape(END)}",
                 f"{START}\n{table}\n{END}", text, flags=re.S)
    if "--check" in sys.argv:
        if new != text:
            print("coverage table is stale — run tools/gen_coverage.py")
            return 1
        print("coverage table current")
        return 0
    INDEX.write_text(new)
    print("coverage table regenerated")
    return 0


if __name__ == "__main__":
    sys.exit(main())
