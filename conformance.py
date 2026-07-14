#!/usr/bin/env python3
"""Agentic conformance harness for the ``vyges mcp`` tool surface.

Drives the **real** ``vyges mcp`` JSON-RPC server end-to-end: a *driver* forms
each tool call, the harness executes it over stdio, and then validates the
``loom-result`` envelope that comes back — a repeatable "can a model actually
drive these engines?" sweep.

Driver modes:

  echo       Deterministic driver — replays the ``arguments`` in the case file.
             Exercises the full MCP round-trip + envelope with **no LLM and no
             network**. Runs anywhere; this is the deterministic subset.

  anthropic  A capable model is shown the whole tool surface (native tool-use) and
             must pick the right tool and form its arguments from the descriptor
             alone. Needs ``ANTHROPIC_API_KEY``.

  github     Same, via **GitHub Models** (OpenAI-compatible tool-calling). Free for
             public repos through ``GITHUB_TOKEN`` (``permissions: models: read``).

An LLM driver measures **descriptor legibility** (can a competent reader pick the
tool + form args from ``--describe`` alone?) and yields a model-capability matrix.
Treat an LLM run as an **advisory** smoke test — model output isn't bit-reproducible,
so don't hard-gate a release on it; the ``echo`` driver is the deterministic subset.

Stdlib only. Python 3.8+.
"""
from __future__ import annotations

import argparse
import json
import os
import select
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

# --------------------------------------------------------------------------- #
# MCP stdio client — newline-delimited JSON-RPC 2.0, matching `vyges mcp`.
# --------------------------------------------------------------------------- #


class McpServer:
    """A spawned ``vyges mcp`` process we talk JSON-RPC to over stdio.

    `vyges mcp` frames one JSON object per line and may interleave
    ``notifications/message`` frames (live engine logs) during a ``tools/call``;
    we read past those until the response with our request id arrives.
    """

    def __init__(self, vyges_bin, profile, cwd, env_extra=None):
        env = dict(os.environ)
        env["VYGES_MCP_PROFILE"] = profile
        if env_extra:
            env.update(env_extra)
        self.proc = subprocess.Popen(
            [vyges_bin, "mcp"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            cwd=os.path.expanduser(cwd) if cwd else None,
            env=env,
        )
        self._id = 0
        self.notifications = []  # collected live log frames, for debugging

    def _send(self, obj):
        assert self.proc.stdin is not None
        self.proc.stdin.write(json.dumps(obj) + "\n")
        self.proc.stdin.flush()

    def _read_response(self, want_id, timeout):
        assert self.proc.stdout is not None
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"no response to id={want_id} within {timeout}s")
            ready, _, _ = select.select([self.proc.stdout], [], [], remaining)
            if not ready:
                continue
            line = self.proc.stdout.readline()
            if not line:
                raise RuntimeError("server closed stdout before responding")
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue  # ignore an unparsable frame, like the server does
            if msg.get("method") == "notifications/message":
                self.notifications.append(msg.get("params"))
                continue
            if msg.get("id") == want_id:
                return msg
            # a response to some other id — ignore

    def request(self, method, params=None, timeout=300):
        self._id += 1
        rid = self._id
        self._send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params or {}})
        return self._read_response(rid, timeout)

    def notify(self, method, params=None):
        self._send({"jsonrpc": "2.0", "method": method, "params": params or {}})

    def initialize(self):
        r = self.request(
            "initialize",
            {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "vyges-conformance", "version": "0.1"},
            },
        )
        self.notify("notifications/initialized")
        return r

    def list_tools(self):
        return self.request("tools/list").get("result", {}).get("tools", [])

    def call_tool(self, name, arguments, timeout=600):
        r = self.request("tools/call", {"name": name, "arguments": arguments}, timeout=timeout)
        if "error" in r:
            return {"_rpc_error": r["error"]}
        return r.get("result", {})

    def close(self):
        try:
            if self.proc.stdin:
                self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.wait(timeout=5)
        except Exception:
            self.proc.kill()


# --------------------------------------------------------------------------- #
# Drivers — each returns (tool_name, arguments) for a case.
# --------------------------------------------------------------------------- #


def driver_echo(case, tools, _opts):
    """Golden driver: replay the case's declared tool + arguments verbatim."""
    return case["tool"], case.get("arguments", {})


def driver_anthropic(case, tools, opts):
    """Show the *whole* surface to a capable model; it must pick + form the call.

    This is the honest conformance test — tool **selection** and **argument**
    formation, both from the descriptor alone (native tool-use, temperature 0).
    """
    key = os.environ.get("ANTHROPIC_API_KEY")
    if not key:
        raise RuntimeError("ANTHROPIC_API_KEY is not set (required for --driver anthropic)")
    api_tools = [
        {
            "name": t["name"],
            "description": t.get("description", ""),
            "input_schema": t.get("inputSchema") or {"type": "object", "properties": {}},
        }
        for t in tools
    ]
    body = {
        "model": opts["model"],
        "max_tokens": 1024,
        "temperature": 0,
        "tools": api_tools,
        "tool_choice": {"type": "any"},  # force a tool call, no prose
        "messages": [{"role": "user", "content": case["task"]}],
    }
    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages",
        data=json.dumps(body).encode(),
        headers={
            "content-type": "application/json",
            "x-api-key": key,
            "anthropic-version": "2023-06-01",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=120) as resp:
        data = json.loads(resp.read())
    for block in data.get("content", []):
        if block.get("type") == "tool_use":
            return block["name"], block.get("input", {})
    raise RuntimeError("model returned no tool_use block")


def driver_github(case, tools, opts):
    """Drive **GitHub Models** (OpenAI-compatible tool-calling). Free for public
    repos via the built-in `GITHUB_TOKEN` (needs `permissions: models: read`) — the
    basis for a public conformance CI. Same honest test as `anthropic`: the whole
    surface, temperature 0, forced tool call.
    """
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GITHUB_MODELS_TOKEN")
    if not token:
        raise RuntimeError("GITHUB_TOKEN (with models:read) not set (required for --driver github)")
    endpoint = os.environ.get("GITHUB_MODELS_ENDPOINT", "https://models.github.ai/inference")
    url = endpoint.rstrip("/") + "/chat/completions"
    # OpenAI function names disallow '.', which appears in composed tools (loom.feedback,
    # openroad.emap, txn.*). Sanitize for the request and map the reply back.
    namemap, fns = {}, []
    for t in tools:
        safe = t["name"].replace(".", "_")
        namemap[safe] = t["name"]
        fns.append({"type": "function", "function": {
            "name": safe,
            "description": t.get("description", ""),
            "parameters": t.get("inputSchema") or {"type": "object", "properties": {}},
        }})
    body = {
        "model": opts["model"],
        "temperature": 0,
        "messages": [
            {"role": "system", "content": "You are a silicon sign-off agent. Call exactly one tool to accomplish the task."},
            {"role": "user", "content": case["task"]},
        ],
        "tools": fns,
        "tool_choice": "required",
    }
    req = urllib.request.Request(
        url, data=json.dumps(body).encode(),
        headers={"content-type": "application/json", "authorization": f"Bearer {token}"},
        method="POST",
    )
    # Free-tier GitHub Models is rate-limited; retry on 429, honoring Retry-After.
    data = None
    for attempt in range(6):
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                data = json.loads(resp.read())
            break
        except urllib.error.HTTPError as e:
            if e.code == 429 and attempt < 5:
                wait = int(e.headers.get("Retry-After", 0) or 0) or (2 ** attempt)
                time.sleep(min(wait, 60))
                continue
            raise
    calls = (data.get("choices", [{}])[0].get("message", {}) or {}).get("tool_calls") or []
    if not calls:
        raise RuntimeError("model returned no tool_call")
    fn = calls[0]["function"]
    raw_args = fn.get("arguments") or "{}"
    args = json.loads(raw_args) if isinstance(raw_args, str) else raw_args
    return namemap.get(fn["name"], fn["name"]), args


DRIVERS = {"echo": driver_echo, "anthropic": driver_anthropic, "github": driver_github}


# --------------------------------------------------------------------------- #
# Checks — validate the returned tools/call result + loom-result envelope.
# --------------------------------------------------------------------------- #


def _dotted(obj, path):
    cur = obj
    for part in path.split("."):
        if isinstance(cur, dict) and part in cur:
            cur = cur[part]
        else:
            return (False, None)
    return (True, cur)


def run_checks(case, called_tool, result):
    """Return a list of (check_name, ok, detail)."""
    checks = case.get("checks", ["tool_matches", "structured_envelope", "status_ok", "has_input_hash"])
    env = result.get("structuredContent") if isinstance(result, dict) else None
    out = []
    for c in checks:
        if c == "tool_matches":
            ok = called_tool == case["tool"]
            out.append((c, ok, f"called={called_tool} expected={case['tool']}"))
        elif c == "structured_envelope":
            ok = isinstance(env, dict)
            out.append((c, ok, "structuredContent present" if ok else f"missing: {result}"))
        elif c == "status_ok":
            status = env.get("status") if isinstance(env, dict) else None
            ok = status == case.get("expect_status", "ok")
            out.append((c, ok, f"status={status}"))
        elif c == "has_input_hash":
            # `input_hash` is a top-level field of the loom-result envelope (the
            # content-addressed BLAKE3 of the resolved inputs); provenance carries cmd/env.
            ih = env.get("input_hash") if isinstance(env, dict) else None
            ok = isinstance(ih, str) and ih.startswith("blake3:")
            out.append((c, ok, f"input_hash={ih}"))
        else:
            out.append((c, False, f"unknown check '{c}'"))
    # optional dotted-path expectations against the envelope
    for path, want in case.get("expect", {}).items():
        found, got = _dotted(env or {}, path)
        ok = found and got == want
        out.append((f"expect:{path}", ok, f"got={got!r} want={want!r}"))
    return out


# --------------------------------------------------------------------------- #
# Runner
# --------------------------------------------------------------------------- #


def load_cases(path):
    with open(path) as f:
        doc = json.load(f)
    defaults = doc.get("defaults", {})
    cases = []
    for c in doc.get("cases", []):
        merged = {**defaults, **c}
        cases.append(merged)
    return defaults, cases


def run_case(case, driver_name, opts):
    # A case may declare `skip` (truthy = reason string) when its fixture isn't
    # available yet — it stays in the file as a documented checklist item, reported
    # SKIP, and never counts as a failure.
    if case.get("skip"):
        return {"name": case["name"], "driver": driver_name, "skipped": True,
                "reason": str(case["skip"]), "passed": None}
    profile = case.get("profile", "core")
    # Resolve `cwd`: `~`/absolute paths as-is; a *relative* cwd (e.g. "fixtures/power")
    # resolves against the cases-file directory, so bundled fixtures are portable
    # regardless of where the harness is invoked.
    raw_cwd = case.get("cwd", ".")
    if raw_cwd.startswith("~") or os.path.isabs(raw_cwd):
        cwd = os.path.expanduser(raw_cwd)
    else:
        cwd = os.path.join(opts.get("base_dir", "."), raw_cwd)
    srv = McpServer(opts["vyges_bin"], profile, cwd)
    rec = {"name": case["name"], "driver": driver_name, "profile": profile}
    try:
        srv.initialize()
        tools = srv.list_tools()
        called_tool, arguments = DRIVERS[driver_name](case, tools, opts)
        rec["called_tool"] = called_tool
        rec["arguments"] = arguments
        # if the model picked a tool that isn't advertised, that's a legibility fail
        if called_tool not in {t["name"] for t in tools}:
            rec["checks"] = [("tool_advertised", False, f"'{called_tool}' not in surface")]
            rec["passed"] = False
            return rec
        result = srv.call_tool(called_tool, arguments)
        checks = run_checks(case, called_tool, result)
        rec["checks"] = checks
        rec["passed"] = all(ok for _, ok, _ in checks)
    except Exception as e:  # a driver/transport failure is a case failure, never a crash
        rec["checks"] = [("exception", False, f"{type(e).__name__}: {e}")]
        rec["passed"] = False
    finally:
        srv.close()
    return rec


def main(argv=None):
    ap = argparse.ArgumentParser(description="Agentic conformance harness for `vyges mcp`.")
    ap.add_argument("cases", nargs="?", help="path to a cases JSON file")
    ap.add_argument("--driver", default="echo", choices=list(DRIVERS), help="who forms the tool call")
    ap.add_argument("--model", default="claude-opus-4-8", help="model id for LLM drivers")
    ap.add_argument("--vyges-bin", default=os.environ.get("VYGES_BIN", "vyges"))
    ap.add_argument("--report", help="write a JSON report to this path")
    ap.add_argument("--list-tools", action="store_true", help="just print the advertised surface + inputSchemas and exit")
    ap.add_argument("--profile", default="core", help="VYGES_MCP_PROFILE for --list-tools")
    args = ap.parse_args(argv)

    opts = {"vyges_bin": args.vyges_bin, "model": args.model}
    if args.cases:
        opts["base_dir"] = os.path.dirname(os.path.abspath(args.cases))

    if args.list_tools:
        srv = McpServer(args.vyges_bin, args.profile, ".")
        try:
            srv.initialize()
            for t in srv.list_tools():
                print(f"\n# {t['name']} — {t.get('description','')}")
                print(json.dumps(t.get("inputSchema", {}), indent=2))
        finally:
            srv.close()
        return 0

    if not args.cases:
        ap.error("a cases file is required (or use --list-tools)")

    _defaults, cases = load_cases(args.cases)
    records = [run_case(c, args.driver, opts) for c in cases]

    # ---- report -------------------------------------------------------------
    ran = [r for r in records if not r.get("skipped")]
    skipped = [r for r in records if r.get("skipped")]
    npass = sum(1 for r in ran if r["passed"])
    print(f"\nagentic-conformance · driver={args.driver} · "
          f"{npass}/{len(ran)} passed · {len(skipped)} skipped\n")
    print(f"{'RESULT':6}  {'CASE':32}  {'CALLED':14}  DETAIL")
    for r in records:
        if r.get("skipped"):
            print(f"{'SKIP':6}  {r['name']:32}  {'-':14}  {r['reason']}")
            continue
        badge = "PASS" if r["passed"] else "FAIL"
        called = r.get("called_tool", "-")
        fail_detail = "; ".join(f"{n}={d}" for n, ok, d in r.get("checks", []) if not ok) or "ok"
        print(f"{badge:6}  {r['name']:32}  {called:14}  {fail_detail}")

    report = {
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "driver": args.driver,
        "model": args.model if args.driver != "echo" else None,
        "passed": npass,
        "ran": len(ran),
        "skipped": len(skipped),
        "total": len(records),
        "cases": [
            {**r, "checks": [{"check": n, "ok": ok, "detail": d} for n, ok, d in r.get("checks", [])]}
            for r in records
        ],
    }
    if args.report:
        with open(args.report, "w") as f:
            json.dump(report, f, indent=2)
        print(f"\nreport → {args.report}")

    # Exit non-zero only on a real failure; skipped cases never fail the run.
    return 0 if npass == len(ran) else 1


if __name__ == "__main__":
    sys.exit(main())
