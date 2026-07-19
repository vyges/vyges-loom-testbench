#!/usr/bin/env python3
"""Keep the README's engine counts in step with cases.json.

The README claimed "9/9 read-only engines" in two places while cases.json held 12 and
fixtures/ held 11 — three numbers that should agree and did not. On a page whose pitch is
"no mock-ups, no handwaving", a count that contradicts the repo is the wrong kind of error,
and the wrong reconciliation later reads as inflation.

So the number is not written by hand. This fills the marked block from cases.json, and CI
runs it with --check so a case added without regenerating fails the build rather than
quietly drifting.

Usage:  sync-readme.py [--check]
"""
from __future__ import annotations
import json, pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent
BEGIN, END = "<!-- BEGIN:engines (generated) -->", "<!-- END:engines -->"


def render(cases: list[dict]) -> str:
    tools = sorted({c["tool"] for c in cases})
    n = len(tools)
    listed = ", ".join(f"`{t}`" for t in tools)
    # States COVERAGE, which cases.json establishes, and deliberately not a pass rate, which
    # only a run establishes. Generating "drives N/N correctly" from the case count would let
    # a claim about the model's behaviour grow every time a case is added, without anyone
    # having watched the model do it -- the exact overstatement this file exists to prevent.
    return (
        f"{BEGIN}\n"
        f"The testbench exercises **{n}** read-only engines through `vyges mcp`: {listed}.\n\n"
        f"How many of them the model drives correctly is whatever the badge above reports "
        f"from the last run — not a number kept here.\n"
        f"{END}"
    )


def main() -> int:
    check = "--check" in sys.argv
    cases_path, readme_path = ROOT / "cases.json", ROOT / "README.md"
    raw = json.loads(cases_path.read_text())
    cases = raw if isinstance(raw, list) else raw["cases"]
    readme = readme_path.read_text()

    if BEGIN not in readme or END not in readme:
        print(f"README is missing the {BEGIN} / {END} markers", file=sys.stderr)
        return 2
    block = re.compile(re.escape(BEGIN) + r".*?" + re.escape(END), re.S)
    updated = block.sub(render(cases), readme)

    if check:
        if updated != readme:
            print("README engine counts are stale — run scripts_sync_readme.py", file=sys.stderr)
            return 1
        print(f"README in sync ({len({c['tool'] for c in cases})} engines)")
        return 0
    readme_path.write_text(updated)
    print(f"README synced ({len({c['tool'] for c in cases})} engines)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
