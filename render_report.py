#!/usr/bin/env python3
"""Render conformance report JSON(s) into a static HTML dashboard for GitHub Pages.

Usage: render_report.py --out site --cases cases.json report-echo.json report-agentic.json …
Each report is a column; each engine is a row showing the task the AI was given,
the input it was fed, and PASS / FAIL / SKIP per driver.
"""
import argparse
import html
import json
import os

EMOJI = {
    "sta-si": "⏱️", "extract": "🕸️", "gds-view": "🖼️", "lvs": "🔍", "power": "🔋",
    "em-ir": "⚡", "thermal": "🌡️", "glitch": "〰️", "lec": "🟰",
    "drc": "📐", "cdc": "🔀", "char": "📊",
}


def load(path):
    with open(path) as f:
        return json.load(f)


def col_label(rep):
    if rep.get("driver") == "echo":
        return "Deterministic<br><span class='sub'>known-good replay</span>"
    model = rep.get("model") or rep.get("driver")
    return f"AI agent<br><span class='sub'>{html.escape(str(model))}</span>"


def cell(case):
    if case is None:
        return ("na", "—", "")
    if case.get("skipped"):
        return ("skip", "SKIP", case.get("reason", ""))
    if case.get("passed"):
        return ("pass", "PASS", f"called {case.get('called_tool','')}")
    fails = [c for c in case.get("checks", []) if not c.get("ok")]
    return ("fail", "FAIL", "; ".join(f"{c['check']}: {c['detail']}" for c in fails))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="site")
    ap.add_argument("--cases", default="cases.json")
    ap.add_argument("--assets", default="assets")
    ap.add_argument("--commit", default=os.environ.get("GITHUB_SHA", "")[:7])
    ap.add_argument("--run-url", default="")
    ap.add_argument("reports", nargs="+")
    args = ap.parse_args()

    reports = [load(p) for p in args.reports]
    reports.sort(key=lambda r: 0 if r.get("driver") == "echo" else 1)  # deterministic first

    # task + input per engine, from the cases file
    tasks = {}
    try:
        doc = load(args.cases)
        for c in doc.get("cases", []):
            a = c.get("arguments", {})
            inp = ", ".join(str(v) for v in a.values()) if isinstance(a, dict) else str(a)
            tasks[c["name"]] = (c.get("tool", ""), c.get("task", ""), inp)
    except Exception:
        pass

    names = []
    for r in reports:
        for c in r.get("cases", []):
            if c["name"] not in names:
                names.append(c["name"])
    by_name = [{c["name"]: c for c in r.get("cases", [])} for r in reports]
    generated = reports[0].get("generated_at", "") if reports else ""

    agent = next((r for r in reports if r.get("driver") != "echo"), None)
    agent_line = ""
    if agent:
        agent_line = (f"The AI agent (<b>{html.escape(str(agent.get('model')))}</b>) drove "
                      f"<b>{agent.get('passed', 0)}/{agent.get('ran', 0)}</b> engines correctly "
                      f"— choosing the tool and forming its arguments from the engine descriptors alone.")

    rows = []
    for name in names:
        tool, task, inp = tasks.get(name, ("", "", ""))
        emoji = EMOJI.get(tool, "🔧")
        eng = (f"<div class='eng'><span class='e'>{emoji}</span>"
               f"<div><div class='etitle'>{html.escape(tool or name)}</div>"
               f"<div class='task'>“{html.escape(task)}”</div>"
               + (f"<div class='inp'>input: <code>{html.escape(inp)}</code></div>" if inp else "")
               + "</div></div>")
        tds = [f"<td class='rowh'>{eng}</td>"]
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
<title>Vyges Loom — AI-driven sign-off</title>
<link rel="icon" type="image/svg+xml" href="favicon.svg">
<!-- Google tag (gtag.js) -->
<script async src="https://www.googletagmanager.com/gtag/js?id=G-HDGN88SSHD"></script>
<script>
  window.dataLayer = window.dataLayer || [];
  function gtag(){{dataLayer.push(arguments);}}
  gtag('js', new Date());
  gtag('config', 'G-HDGN88SSHD');
</script>
<style>
  :root {{ color-scheme: light dark; }}
  body {{ font: 15px/1.5 -apple-system, Segoe UI, Roboto, Helvetica, Arial, sans-serif;
         max-width: 880px; margin: 2rem auto; padding: 0 1rem; }}
  h1 {{ font-size: 1.5rem; margin-bottom: .2rem; }}
  .lede {{ color: #777; margin-top: 0; }}
  .explain {{ background: #8884; border-left: 3px solid #4f8cff; padding: .7rem 1rem;
             border-radius: 4px; font-size: .9rem; line-height: 1.55; }}
  .callout {{ background: #0a7c2f22; border-left: 3px solid #0a7c2f; padding: .7rem 1rem; border-radius: 4px; margin: 1rem 0; }}
  .meta {{ color: #888; font-size: .85rem; }}
  table {{ border-collapse: collapse; width: 100%; margin: 1rem 0; }}
  th, td {{ padding: .55rem .6rem; border-bottom: 1px solid #8883; vertical-align: middle; text-align: center; }}
  td.rowh {{ text-align: left; }}
  thead th {{ font-weight: 600; vertical-align: bottom; }}
  .sub {{ font-weight: 400; color: #888; font-size: .8rem; }}
  .eng {{ display: flex; gap: .5rem; align-items: flex-start; }}
  .e {{ font-size: 1.2rem; }}
  .etitle {{ font-weight: 600; font-family: ui-monospace, Menlo, monospace; }}
  .task {{ color: #888; font-size: .82rem; font-style: italic; max-width: 460px; }}
  .inp {{ color: #999; font-size: .78rem; }}
  .inp code {{ color: #4f8cff; }}
  td.pass {{ color: #0a7c2f; font-weight: 700; }}
  td.fail {{ color: #c1121f; font-weight: 700; }}
  td.skip {{ color: #999; }}  td.na {{ color: #bbb; }}
  footer {{ color: #888; font-size: .82rem; margin-top: 1rem; }}
  .cta {{ margin-top: 2rem; padding: .9rem 1rem; background: #2f6df618; border: 1px solid #2f6df655;
         border-radius: 8px; font-size: .92rem; }}
  a {{ color: #2563eb; }}
</style></head><body>
<p><img src="logo.svg" alt="Vyges" height="38"></p>
<h1>Loom — AI-driven silicon sign-off</h1>
<p class="lede">A live conformance run on a clean GitHub Actions runner.</p>
<div class="explain">
  Each row is a <b>real chip sign-off engine</b> (timing, power, IR-drop, LVS, thermal, …), run
  through <code>vyges&nbsp;mcp</code>. The <b>AI agent</b> is handed only a plain-English request
  and the engines' self-descriptions, and must decide <b>which engine to run and which input to
  feed it</b>; the engine then executes for real and returns its own content-addressed result. The
  <b>deterministic</b> column replays known-good calls with no model. The intelligence is in the
  routing — the ground truth is reproducible without any AI.
  <br><br>The model is a <b>stock, general-purpose LLM</b> — no fine-tuning, no training on these
  tools. It gets it right purely by reading each engine's self-description at runtime.
</div>
<div class="callout">{agent_line}</div>
<table>
  <thead><tr><th class="rowh">Engine · task · input</th>{headers}</tr></thead>
  <tbody>
    {"".join(rows)}
  </tbody>
</table>
<p class="meta">{meta}{run_link}</p>
<div class="cta">
  <b>Vyges Loom</b> — open silicon sign-off you can drive with any model, on your own machine.
  &nbsp; <a href="https://vyges.com">Learn more</a> ·
  <a href="https://vyges.com/contact"><b>Talk to us</b></a> ·
  <a href="https://github.com/vyges/vyges-loom-testbench">Reproduce this</a>
</div>
<footer>
  SKIP = fixture not bundled in this demo. ·
  <a href="https://vyges.com/publications">Publications</a>
</footer>
</body></html>
"""
    os.makedirs(args.out, exist_ok=True)
    for asset in ("favicon.svg", "logo.svg"):  # copy brand assets alongside the page
        src = os.path.join(args.assets, asset)
        if os.path.exists(src):
            with open(src, "rb") as s, open(os.path.join(args.out, asset), "wb") as d:
                d.write(s.read())
    with open(os.path.join(args.out, "index.html"), "w") as f:
        f.write(doc)
    print(f"wrote {os.path.join(args.out, 'index.html')} ({len(names)} engines, {len(reports)} columns)")


if __name__ == "__main__":
    main()
