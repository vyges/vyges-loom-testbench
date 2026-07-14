#!/usr/bin/env python3
"""Live demo — watch an AI drive the Loom sign-off engines, in your browser.

Starts a local dashboard, then sweeps the conformance cases through the real
`vyges mcp` server. Each engine card animates: pending → (AI is choosing the
tool) → running → PASS/FAIL with the engine's real headline result.

  python3 demo/live_demo.py                 # AI driver if a token is present, else replay
  python3 demo/live_demo.py --driver echo   # force the deterministic replay
  GITHUB_TOKEN=$(gh auth token) python3 demo/live_demo.py --driver github --model openai/gpt-4.1

Open http://localhost:8756 (opens automatically). Stdlib only; Python 3.8+.
"""
import argparse
import http.server
import json
import os
import socketserver
import subprocess
import sys
import threading
import time
import webbrowser

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from conformance import DRIVERS, McpServer, run_checks  # noqa: E402

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS_DIR = os.path.join(REPO_ROOT, "assets")
HERO = {"png": None}  # a rendered real-chip thumbnail (PNG bytes), when available


# tool -> (emoji, human title, headline(result)->str) for a demo-friendly one-liner
def _sta(r):
    return (f"MET · WNS {r.get('wns_ns', 0):+.2f} ns · {r.get('max_freq_mhz', 0):.0f} MHz"
            if r.get("met") else "TIMING NOT MET")


DISPLAY = {
    "sta-si":   ("⏱️", "Static Timing", _sta),
    "extract":  ("🕸️", "RC Extraction", lambda r: f"{r.get('nets', '?')} nets · {r.get('total_cap_ff', 0):.1f} fF"),
    "gds-view": ("🖼️", "Layout Render", lambda r: "rendered"),
    "lvs":      ("🔍", "LVS", lambda r: "LAYOUT = SCHEMATIC" if r.get("matched") else "MISMATCH"),
    "power":    ("🔋", "Power", lambda r: f"{r.get('dynamic_w', 0) * 1e6:.2f} µW dynamic"),
    "em-ir":    ("⚡", "EM / IR-drop", lambda r: "IR-drop within limit" if r.get("ir_met") else "IR-drop VIOLATION"),
    "thermal":  ("🌡️", "Thermal", lambda r: f"peak {r.get('tmax_c', 0):.1f} °C (limit {r.get('t_limit_c', '?')})"),
    "glitch":   ("〰️", "Glitch / Hazard", lambda r: f"{r.get('hazards', '?')} hazard(s)"),
    "lec":      ("🟰", "Logic Equivalence", lambda r: "EQUIVALENT" if r.get("equivalent") else "NOT EQUIVALENT"),
    "drc":      ("📐", "DRC (real taped-out block)", lambda r: "CLEAN · 0 violations" if r.get("clean") else f"{r.get('violations', '?')} violation(s)"),
    "cdc":      ("🔀", "Clock-Domain Crossing", lambda r: f"{r.get('domains', '?')} domains · {r.get('unsynchronized', '?')} unsynchronized crossing(s)"),
    "char":     ("📊", "Characterization", lambda r: "ok"),
}

STATE = {"cases": [], "model": "", "driver": "", "done": 0, "total": 0, "started": False, "finished": False}
LOCK = threading.Lock()


def load_cases(path):
    with open(path) as f:
        doc = json.load(f)
    defaults = doc.get("defaults", {})
    return [{**defaults, **c} for c in doc.get("cases", [])]


def _gds_view_bin():
    """Resolve the gds-view engine without relying on PATH (next to VYGES_BIN, in
    ~/.vyges/bin, or on PATH)."""
    import shutil
    cands = []
    vb = os.environ.get("VYGES_BIN")
    if vb:
        cands.append(os.path.join(os.path.dirname(vb), "vyges-gds-view"))
    cands.append(os.path.expanduser("~/.vyges/bin/vyges-gds-view"))
    for c in cands:
        if os.path.isfile(c):
            return c
    return shutil.which("vyges-gds-view") or "vyges-gds-view"


def render_hero():
    """Render the bundled real taped-out block to a PNG thumbnail (needs a gds-view
    with raster support). Best-effort — the demo runs fine without it."""
    gds = os.path.join(REPO_ROOT, "fixtures", "drc", "edge_sensor_glue.gds")
    if not os.path.isfile(gds):
        return
    try:
        r = subprocess.run(
            [_gds_view_bin(), "render", gds, "--top", "edge_sensor_glue", "--png", "--width", "760"],
            capture_output=True, timeout=40,
        )
        if r.returncode == 0 and r.stdout[:8] == bytes([137, 80, 78, 71, 13, 10, 26, 10]):
            with LOCK:
                HERO["png"] = r.stdout
    except Exception:
        pass


def set_status(i, status, **kw):
    with LOCK:
        STATE["cases"][i].update(status=status, **kw)


def resolve_cwd(raw, base):
    if raw.startswith("~") or os.path.isabs(raw):
        return os.path.expanduser(raw)
    return os.path.join(base, raw)


def sweep(cases_path, driver, opts, pace):
    base = os.path.dirname(os.path.abspath(cases_path))
    cases = load_cases(cases_path)
    with LOCK:
        STATE["cases"] = [{
            "name": c["name"], "tool": c["tool"],
            "emoji": DISPLAY.get(c["tool"], ("🔧", c["tool"], None))[0],
            "title": DISPLAY.get(c["tool"], ("", c["tool"], None))[1],
            "task": c.get("task", ""),          # the plain-English ask the AI is given
            "call": "",                          # the tool + input the AI chose
            "status": "pending", "headline": "", "detail": "",
        } for c in cases]
        STATE["total"] = sum(1 for c in cases if not c.get("skip"))
        STATE["driver"], STATE["model"] = driver, (opts.get("model") if driver != "echo" else "deterministic replay")
        STATE["started"] = True

    for i, c in enumerate(cases):
        if c.get("skip"):
            set_status(i, "skip", headline="fixture not bundled")
            continue
        profile = c.get("profile", "core")
        cwd = resolve_cwd(c.get("cwd", "."), base)
        srv = McpServer(opts["vyges_bin"], profile, cwd)
        try:
            srv.initialize()
            tools = srv.list_tools()
            set_status(i, "thinking", headline="AI is choosing a tool…" if driver != "echo" else "preparing…")
            time.sleep(pace)
            called, args = DRIVERS[driver](c, tools, opts)
            inputs = ", ".join(str(v) for v in args.values()) if isinstance(args, dict) else str(args)
            set_status(i, "running", call=f"{called}  ·  {inputs}", headline=f"running {called}…")
            time.sleep(pace)
            result = srv.call_tool(called, args)
            checks = run_checks(c, called, result)
            ok = all(x[1] for x in checks)
            env = result.get("structuredContent", {}) if isinstance(result, dict) else {}
            res = env.get("result", {}) if isinstance(env, dict) else {}
            hf = DISPLAY.get(c["tool"], (None, None, None))[2]
            headline = (hf(res) if hf and ok else "") or ("PASS" if ok else "check failed")
            set_status(i, "pass" if ok else "fail", headline=headline,
                       detail="" if ok else "; ".join(f"{n}: {d}" for n, o, d in checks if not o))
        except Exception as e:
            set_status(i, "fail", headline="error", detail=f"{type(e).__name__}: {e}")
        finally:
            srv.close()
        with LOCK:
            STATE["done"] += 1
    with LOCK:
        STATE["finished"] = True


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, body, ctype):
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body.encode())

    def do_GET(self):
        if self.path.startswith("/hero.png"):
            with LOCK:
                png = HERO["png"]
            if png:
                self.send_response(200)
                self.send_header("Content-Type", "image/png")
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(png)
            else:
                self.send_response(404)
                self.end_headers()
            return
        if self.path.startswith("/assets/"):
            self._send_asset(os.path.basename(self.path))
        elif self.path.startswith("/state"):
            with LOCK:
                self._send(json.dumps(STATE), "application/json")
        else:
            self._send(PAGE, "text/html; charset=utf-8")

    def _send_asset(self, name):
        path = os.path.join(ASSETS_DIR, name)
        if not os.path.isfile(path):
            self.send_response(404)
            self.end_headers()
            return
        with open(path, "rb") as f:
            body = f.read()
        ctype = "image/svg+xml" if name.endswith(".svg") else "application/octet-stream"
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)


PAGE = r"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Vyges Loom — live AI sign-off</title>
<link rel="icon" type="image/svg+xml" href="/assets/favicon.svg">
<script async src="https://www.googletagmanager.com/gtag/js?id=G-HDGN88SSHD"></script>
<script>
  window.dataLayer = window.dataLayer || [];
  function gtag(){dataLayer.push(arguments);}
  gtag('js', new Date());
  gtag('config', 'G-HDGN88SSHD');
</script>
<style>
  :root{ --bg:#0b0f17; --card:#141a26; --line:#232c3d; --dim:#7c89a0; }
  *{ box-sizing:border-box; }
  body{ margin:0; background:radial-gradient(1200px 600px at 50% -10%, #16203a, #0b0f17);
        color:#e7edf5; font:15px/1.45 -apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif; min-height:100vh; }
  header{ padding:1.6rem 1.2rem .4rem; text-align:center; }
  h1{ margin:.1rem 0; font-size:1.5rem; letter-spacing:.2px; }
  .sub{ color:#9fb0c8; font-size:.95rem; }
  .explain{ max-width:720px; margin:.9rem auto 0; color:#93a2ba; font-size:.88rem; line-height:1.5; text-align:left; }
  .bot{ font-weight:700; color:#7bd88f; }
  #hero{ max-width:600px; margin:1.2rem auto .2rem; text-align:center; }
  #hero img{ max-width:100%; border-radius:10px; border:1px solid #232c3d; box-shadow:0 6px 34px #0009; }
  #hero .cap{ color:#93a2ba; font-size:.85rem; margin-top:.55rem; }
  .bar{ max-width:900px; margin:1rem auto .4rem; height:8px; border-radius:99px; background:#1c2536; overflow:hidden; }
  .bar > i{ display:block; height:100%; width:0; background:linear-gradient(90deg,#4f8cff,#7bd88f); transition:width .4s ease; }
  .count{ text-align:center; color:#9fb0c8; font-size:.9rem; margin-bottom:1rem; }
  .grid{ max-width:900px; margin:0 auto 3rem; padding:0 1rem; display:grid;
         grid-template-columns:repeat(auto-fill,minmax(250px,1fr)); gap:.8rem; }
  .card{ background:var(--card); border:1px solid var(--line); border-radius:12px; padding:.9rem 1rem;
         opacity:.55; transition:opacity .3s, border-color .3s, transform .2s, box-shadow .3s; }
  .card .top{ display:flex; align-items:center; gap:.55rem; }
  .emoji{ font-size:1.3rem; }
  .name{ font-weight:600; }
  .tool{ color:#8595ad; font-size:.78rem; }
  .task{ margin-top:.5rem; color:#93a2ba; font-size:.8rem; font-style:italic; }
  .call{ margin-top:.35rem; font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-size:.78rem;
         color:#8fb3ff; min-height:1em; }
  .call:empty{ display:none; }
  .hl{ margin-top:.4rem; font-size:.9rem; color:#c7d3e6; min-height:1.1em; }
  .dot{ margin-left:auto; width:11px; height:11px; border-radius:99px; background:#3a4560; }
  /* states */
  .card.pending{ }
  .card.thinking,.card.running{ opacity:1; border-color:#f2b53c; box-shadow:0 0 0 1px #f2b53c55, 0 0 22px #f2b53c33; }
  .card.thinking .dot,.card.running .dot{ background:#f2b53c; animation:pulse 1s infinite; }
  .card.thinking .hl,.card.running .hl{ color:#f2b53c; }
  .card.pass{ opacity:1; border-color:#2f8f52; }
  .card.pass .dot{ background:#7bd88f; }
  .card.pass .hl{ color:#7bd88f; font-weight:600; }
  .card.pass{ animation:pop .4s ease; }
  .card.fail{ opacity:1; border-color:#c1121f; }
  .card.fail .dot{ background:#ff5a67; }
  .card.fail .hl{ color:#ff8088; }
  .card.skip{ opacity:.4; }
  .card.skip .dot{ background:#556; }
  @keyframes pulse{ 0%,100%{ transform:scale(1); opacity:1; } 50%{ transform:scale(1.5); opacity:.5; } }
  @keyframes pop{ 0%{ transform:scale(.97);} 55%{ transform:scale(1.03);} 100%{ transform:scale(1);} }
  footer{ text-align:center; color:#63748f; font-size:.8rem; padding-bottom:2rem; color:#63748f; }
  .done-banner{ text-align:center; font-size:1.15rem; font-weight:700; color:#7bd88f; margin:.4rem 0 1rem; min-height:1.3em; }
  a{ color:#8fb3ff; text-decoration:none; } a:hover{ text-decoration:underline; }
  .cta{ max-width:640px; margin:1rem auto 2rem; text-align:center; color:#c7d3e6; font-size:.95rem; }
  .cta-links{ margin-top:.8rem; display:flex; gap:.6rem; justify-content:center; flex-wrap:wrap; }
  .btn{ padding:.5rem 1rem; border:1px solid #2f3c55; border-radius:8px; color:#c7d3e6; font-weight:600; }
  .btn:hover{ border-color:#4f8cff; text-decoration:none; }
  .btn.primary{ background:#2f6df6; border-color:#2f6df6; color:#fff; }
</style></head><body>
<header>
  <img src="/assets/logo.svg" alt="Vyges" height="34" style="margin-bottom:.4rem">
  <h1>🤖 Watch an AI run silicon sign-off</h1>
  <div class="sub"><span class="bot" id="model">…</span> is driving the open <b>Loom</b> engines through <code>vyges mcp</code> — live.</div>
  <p class="explain">Each card is a <b>real chip sign-off engine</b> (timing, power, IR-drop, LVS, thermal…).
  The AI is handed a plain-English request and the engines' self-descriptions — nothing else — and must
  decide <b>which engine to run and which input file to feed it</b>. The engine then runs for real and
  returns its own content-addressed result. The intelligence is in the routing; the ground truth is
  deterministic — swap the model out and the same call reproduces the same numbers.
  <br><br>The model is a <b>stock, general-purpose LLM</b> — no fine-tuning, no training on these tools.
  It gets it right purely by reading each engine's self-description at runtime.</p>
</header>
<div id="hero" style="display:none">
  <img id="heroimg" alt="real chip layout">
  <div class="cap">☝ A <b>real taped-out sky130 block</b> (edge-sensor SoC glue) — rendered by <code>vyges gds-view</code>. The AI signs it off, live, below.</div>
</div>
<div class="bar"><i id="fill"></i></div>
<div class="count" id="count">connecting…</div>
<div class="done-banner" id="banner"></div>
<div class="grid" id="grid"></div>
<div class="cta">
  <b>Vyges Loom</b> — open silicon sign-off you can drive with any model, on your own machine.
  <div class="cta-links">
    <a class="btn" href="https://vyges.com">Learn more</a>
    <a class="btn primary" href="https://vyges.com/contact">Talk to us</a>
    <a class="btn" href="https://github.com/vyges/vyges-loom-testbench">Run this demo</a>
  </div>
</div>
<footer>
  Every card is a real engine invocation returning its own content-addressed sign-off result.<br>
  <a href="https://vyges.com">vyges.com</a> ·
  <a href="https://vyges.com/publications">Publications</a> ·
  <a href="https://github.com/vyges/vyges-loom-testbench">Source</a>
</footer>
<script>
const grid = document.getElementById('grid');
let built = false;
function build(cases){
  grid.innerHTML = '';
  cases.forEach(c=>{
    const el = document.createElement('div');
    el.className = 'card '+c.status; el.id = 'c-'+c.name;
    el.innerHTML = `<div class="top"><span class="emoji">${c.emoji}</span>
      <div><div class="name">${c.title}</div><div class="tool">${c.tool}</div></div>
      <span class="dot"></span></div>
      <div class="task">“${c.task||''}”</div>
      <div class="call"></div>
      <div class="hl"></div>`;
    grid.appendChild(el);
  });
  built = true;
}
async function tick(){
  try{
    const s = await (await fetch('/state',{cache:'no-store'})).json();
    if(s.started){
      document.getElementById('model').textContent = s.model || s.driver;
      if(!built || grid.children.length !== s.cases.length) build(s.cases);
      s.cases.forEach(c=>{
        const el = document.getElementById('c-'+c.name); if(!el) return;
        el.className = 'card '+c.status;
        el.querySelector('.call').textContent = c.call ? ('→ '+c.call) : '';
        el.querySelector('.hl').textContent = c.headline || '';
      });
      const pct = s.total ? Math.round(100*s.done/s.total) : 0;
      document.getElementById('fill').style.width = pct+'%';
      document.getElementById('count').textContent = `${s.done} / ${s.total} engines`;
      if(s.finished){
        const passed = s.cases.filter(c=>c.status==='pass').length;
        document.getElementById('banner').textContent = `✅ ${passed}/${s.total} engines signed off by the AI`;
      }
    }
  }catch(e){}
}
setInterval(tick, 350); tick();
let heroTries=0;
function loadHero(){
  const img=document.getElementById('heroimg');
  img.onload=()=>{document.getElementById('hero').style.display='block';};
  img.onerror=()=>{ if(++heroTries<15) setTimeout(loadHero,1500); };
  img.src='/hero.png?t='+Date.now();
}
loadHero();
</script></body></html>"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cases", nargs="?", default=os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "cases.json"))
    ap.add_argument("--driver", choices=list(DRIVERS), default=None)
    ap.add_argument("--model", default="openai/gpt-4.1")
    ap.add_argument("--vyges-bin", default=os.environ.get("VYGES_BIN", "vyges"))
    ap.add_argument("--port", type=int, default=8756)
    ap.add_argument("--pace", type=float, default=0.5, help="dwell (s) on thinking/running so it's watchable")
    ap.add_argument("--no-open", action="store_true")
    args = ap.parse_args()

    driver = args.driver
    if driver is None:  # auto: AI if a token is present, else deterministic replay
        driver = "github" if (os.environ.get("GITHUB_TOKEN") or os.environ.get("GITHUB_MODELS_TOKEN")) else "echo"
    opts = {"vyges_bin": args.vyges_bin, "model": args.model}

    threading.Thread(target=render_hero, daemon=True).start()  # real-chip thumbnail (best-effort)
    threading.Thread(target=sweep, args=(args.cases, driver, opts, args.pace), daemon=True).start()

    url = f"http://localhost:{args.port}"
    print(f"live demo → {url}  (driver={driver})")
    if not args.no_open:
        threading.Timer(0.8, lambda: webbrowser.open(url)).start()
    with socketserver.ThreadingTCPServer(("", args.port), Handler) as httpd:
        httpd.allow_reuse_address = True
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
