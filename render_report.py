#!/usr/bin/env python3
"""Render conformance report JSON(s) into a static HTML dashboard for GitHub Pages.

Usage: render_report.py --out site report-echo.json report-gpt-4.1.json …
Each report is a column; each engine case is a row (PASS / FAIL / SKIP).
"""
import argparse
import html
import json
import os


def load(path):
    with open(path) as f:
        return json.load(f)


def col_label(rep):
    if rep.get("driver") == "echo":
        return "Deterministic<br><span class='sub'>(known-good replay)</span>"
    model = rep.get("model") or rep.get("driver")
    return f"AI agent<br><span class='sub'>{html.escape(str(model))}</span>"


def cell(case):
    """Return (css_class, label, detail) for one case in one report."""
    if case is None:
        return ("na", "—", "")
    if case.get("skipped"):
        return ("skip", "SKIP", case.get("reason", ""))
    if case.get("passed"):
        note = case.get("called_tool", "")
        return ("pass", "PASS", f"called {note}" if note else "")
    fails = [c for c in case.get("checks", []) if not c.get("ok")]
    detail = "; ".join(f"{c['check']}: {c['detail']}" for c in fails)
    return ("fail", "FAIL", detail)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="site")
    ap.add_argument("--commit", default=os.environ.get("GITHUB_SHA", "")[:7])
    ap.add_argument("--run-url", default="")
    ap.add_argument("reports", nargs="+")
    args = ap.parse_args()

    reports = [load(p) for p in args.reports]
    reports.sort(key=lambda r: 0 if r.get("driver") == "echo" else 1)  # deterministic first

    # union of case names, in first-seen order
    names = []
    for r in reports:
        for c in r.get("cases", []):
            if c["name"] not in names:
                names.append(c["name"])
    by_name = [{c["name"]: c for c in r.get("cases", [])} for r in reports]

    generated = reports[0].get("generated_at", "") if reports else ""

    # agent summary (first non-echo report)
    agent = next((r for r in reports if r.get("driver") != "echo"), None)
    agent_line = ""
    if agent:
        agent_line = (
            f"The AI agent (<b>{html.escape(str(agent.get('model')))}</b>) drove "
            f"<b>{agent.get('passed', 0)}/{agent.get('ran', 0)}</b> engines correctly "
            f"— choosing the tool and forming its arguments from the engine descriptors alone."
        )

    rows = []
    for name in names:
        tds = [f"<th class='rowh'>{html.escape(name)}</th>"]
        for i, _r in enumerate(reports):
            cls, label, detail = cell(by_name[i].get(name))
            tds.append(f"<td class='{cls}' title='{html.escape(detail)}'>{label}</td>")
        rows.append("<tr>" + "".join(tds) + "</tr>")

    headers = "".join(f"<th>{col_label(r)}</th>" for r in reports)
    meta = " · ".join(x for x in [generated, (f"commit {args.commit}" if args.commit else "")] if x)
    run_link = f" · <a href='{html.escape(args.run_url)}'>run log</a>" if args.run_url else ""

    doc = f"""<!doctype html>
<html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Vyges Loom — live sign-off demo</title>
<style>
  :root {{ color-scheme: light dark; }}
  body {{ font: 15px/1.5 -apple-system, Segoe UI, Roboto, Helvetica, Arial, sans-serif;
         max-width: 820px; margin: 2rem auto; padding: 0 1rem; }}
  h1 {{ font-size: 1.5rem; margin-bottom: .2rem; }}
  .lede {{ color: #666; margin-top: 0; }}
  .meta {{ color: #888; font-size: .85rem; }}
  table {{ border-collapse: collapse; width: 100%; margin: 1.2rem 0; }}
  th, td {{ padding: .5rem .6rem; text-align: center; border-bottom: 1px solid #8883; }}
  th.rowh, td.rowh {{ text-align: left; font-weight: 600; }}
  thead th {{ font-weight: 600; vertical-align: bottom; }}
  .sub {{ font-weight: 400; color: #888; font-size: .8rem; }}
  td.pass {{ color: #0a7c2f; font-weight: 700; }}
  td.fail {{ color: #c1121f; font-weight: 700; }}
  td.skip {{ color: #999; }}
  td.na {{ color: #bbb; }}
  .callout {{ background: #0a7c2f14; border-left: 3px solid #0a7c2f; padding: .7rem 1rem; border-radius: 4px; }}
  footer {{ color: #999; font-size: .82rem; margin-top: 2rem; }}
  a {{ color: #2563eb; }}
</style></head><body>
<h1>Vyges Loom — live sign-off demo</h1>
<p class="lede">An AI model drives the open <b>Loom</b> silicon sign-off engines through <code>vyges&nbsp;mcp</code>,
end-to-end, on a fresh GitHub Actions runner. Each engine below was invoked for real; the result is the
engine's own structured, content-addressed output.</p>
<div class="callout">{agent_line}</div>
<table>
  <thead><tr><th class="rowh">Engine</th>{headers}</tr></thead>
  <tbody>
    {"".join(rows)}
  </tbody>
</table>
<p class="meta">{meta}{run_link}</p>
<footer>
  <b>Deterministic</b> replays known-good calls (no model) and gates the run.
  <b>AI agent</b> is shown the whole tool surface and must pick the tool + arguments from the
  descriptors alone — a legibility test, advisory by design. SKIP = fixture not bundled in this demo.
  Reproduce: <a href="https://github.com/vyges/vyges-loom-testbench">vyges/vyges-loom-testbench</a>.
</footer>
</body></html>
"""
    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, "index.html"), "w") as f:
        f.write(doc)
    print(f"wrote {os.path.join(args.out, 'index.html')} ({len(names)} engines, {len(reports)} columns)")


if __name__ == "__main__":
    main()
