# vyges-loom-testbench

**Watch an AI run open silicon sign-off — live.**

[![test](https://github.com/vyges/vyges-loom-testbench/actions/workflows/test.yml/badge.svg)](https://github.com/vyges/vyges-loom-testbench/actions/workflows/test.yml)
· **[Live dashboard →](https://vyges.github.io/vyges-loom-testbench/)**

A capable model is shown the [Vyges Loom](https://vyges.com) sign-off engines through
`vyges mcp` and — with nothing but each engine's self-description — picks the right tool,
forms its arguments, and runs it. Every result is the engine's own **real, content-addressed
sign-off output**. No mock-ups, no handwaving.

<!-- BEGIN:engines (generated) -->
The testbench exercises **14** read-only engines through `vyges mcp`: `cdc`, `char`, `drc`, `em-ir`, `extract`, `gds-view`, `glitch`, `lec`, `lvs`, `meas`, `opendb`, `power`, `sta-si`, `thermal`.

How many of them the model drives correctly is whatever the badge above reports from the last run — not a number kept here.
<!-- END:engines -->

## The live demo (blinky)

A local browser dashboard where each engine lights up as the AI drives it — pending →
*AI is choosing the tool* → running → **PASS** with the engine's real headline (timing met,
IR-drop OK, LVS match, …):

```sh
# Install the Vyges CLI + engines once (https://vyges.com), then:
export PATH="$HOME/.vyges/bin:$PATH"

# Watch the AI drive it (uses your GitHub Models token):
GITHUB_TOKEN=$(gh auth token) python3 demo/live_demo.py --driver github --model openai/gpt-4.1

# …or the deterministic replay (no model, instant):
python3 demo/live_demo.py --driver echo
```

Opens `http://localhost:8756`. Stdlib only — no pip installs.

## What each engine shows

| Engine | Real result you'll see |
| --- | --- |
| `sta-si` | timing met · WNS · max frequency |
| `extract` | net count · total capacitance |
| `lvs` | layout = schematic |
| `power` | dynamic power |
| `em-ir` | IR-drop within limit |
| `thermal` | peak temperature vs limit |
| `glitch` | hazard count |
| `lec` | equivalent / not |
| `gds-view` | layout rendered |

## How it works

`vyges mcp` exposes each installed Loom engine as a tool with a typed, self-describing
interface. A **driver** forms one call per engine; the harness runs it and validates the
`loom-result` envelope (right tool, `status: ok`, content-addressed `input_hash`, plus the
expected result). Three drivers: `echo` (deterministic replay), `github` (GitHub Models),
`anthropic`. The agentic drivers see the *whole* surface and must choose correctly from the
descriptors alone — a legibility test as much as a functional one.

## CI + published dashboard

`.github/workflows/test.yml`, run manually (`workflow_dispatch`):

- **deterministic** — replays known-good calls; **gates** the run.
- **agentic** — one GitHub Models model drives the surface; **advisory** (never fails CI).
- **report** — publishes the matrix to **[the live dashboard](https://vyges.github.io/vyges-loom-testbench/)**.

Model access uses a `models: read` token via the `MODELS_TOKEN` secret (falls back to the
Actions token where the org has GitHub Models enabled).

## Construction, driven from a shell

The engines above are read-only and are driven through `vyges mcp`. [`flows/`](./flows) is the
other half — the **construction** engines, driven from an ordinary shell script with no MCP and no
model in the loop:

```sh
./flows/floorplan.sh --netlist build/my_block.v --die-area '0 0 700 700'
```

`import → ifp → make-tracks → tap → global-connect → pdn` — six steps, four static binaries, no
OpenROAD, with the PDK resolved through `vyges pdk-store`. [`flows/edge-sensor-demo.sh`](./flows/edge-sensor-demo.sh)
is a thin wrapper that runs it on a **taped-out** block of the
[Vyges edge-sensor SoC](https://github.com/vyges/vyges-edge-sensor-soc) and checks the rows and
tracks it produces against the silicon.

[`flows/io-ring.sh`](./flows/io-ring.sh) does the other half of the die — the IO ring and the RDL
that reaches it. Nine steps and three binaries, from `make-io-sites` through `rdl-route`; on a
238-pad flip-chip, 273 of 273 nets routed. Its exit status is the router's: leave a net unrouted
and it writes the partial DEF, says so, and exits non-zero.

## Coverage

The read-only engines listed above run against bundled Apache-2.0 fixtures under [`fixtures/`](./fixtures).
`drc`, `cdc`, and `char` are documented placeholders pending heavier inputs (a PDK DRC deck /
a multi-clock netlist / ngspice + PDK models).

## License

Apache-2.0. Bundled fixtures are copied from the corresponding Loom engine repositories.
