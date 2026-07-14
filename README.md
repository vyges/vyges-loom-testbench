# vyges-loom-testbench

A small, self-contained **conformance testbench** for the [Vyges Loom](https://vyges.com)
sign-off engines, driven through the `vyges mcp` tool server.

It answers one question, repeatably: **can a model actually drive the Loom engines
end-to-end?** For each engine it starts the real `vyges mcp` JSON-RPC server, has a
*driver* form one tool call, executes it, and validates the structured `loom-result`
envelope that comes back (right tool, structured result, `status: ok`, a
content-addressed `input_hash`, plus per-case expectations).

## Drivers

| driver | who forms the tool call | needs |
| --- | --- | --- |
| `echo` | replays the case's known-good arguments — no LLM, fully deterministic | nothing |
| `github` | a **GitHub Models** LLM picks the tool + forms its args from the engine descriptor alone (free in public repos) | `GITHUB_TOKEN` (`models: read`) |
| `anthropic` | same, via the Anthropic API | `ANTHROPIC_API_KEY` |

The deterministic `echo` run is the gate. An LLM run is **advisory** — it measures how
legible the engine descriptors are to a competent reader and yields a model-capability
snapshot, but model output isn't bit-reproducible, so it never fails CI.

## Run locally

```sh
# Install the Vyges CLI + the Loom engines (see https://vyges.com), then:
export PATH="$HOME/.vyges/bin:$PATH"          # so the engines are discoverable

python3 conformance.py cases.json --driver echo            # deterministic
python3 conformance.py --list-tools                        # inspect the tool surface

# With a free GitHub Models token (models: read):
GITHUB_TOKEN=… python3 conformance.py cases.json --driver github --model openai/gpt-4o-mini
```

Exit code is non-zero if any non-skipped case fails.

## CI

`.github/workflows/test.yml` installs the CLI + engines, runs the deterministic sweep
(gates), then runs the agentic sweep across a couple of free GitHub Models (advisory),
and writes a results table to the job summary. Triggered on PR, weekly, or manually.

## Coverage

Nine read-only engines run against bundled [`fixtures/`](./fixtures) (Apache-2.0 Loom
engine examples): `sta-si`, `extract`, `gds-view`, `lvs`, `power`, `em-ir`, `thermal`,
`glitch`, `lec`. `drc`, `cdc`, and `char` are `skip`-documented in `cases.json` pending
heavier inputs (a PDK DRC deck / a multi-clock netlist / ngspice + PDK models).

## License

Apache-2.0. Bundled fixtures are copied from the corresponding Loom engine repositories.
