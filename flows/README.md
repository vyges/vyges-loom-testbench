# flows — construction, driven from a shell

The rest of this testbench drives **read-only** Loom engines (timing, power, DRC, LVS …) through
`vyges mcp`, and asks whether a model can pick the right tool from the descriptors alone.

This directory is the other half: the **construction** engines, driven from an ordinary shell
script with no MCP and no model in the loop. What is being shown is not tool choice but that the
engines compose — each one reading what the previous one wrote — and that the result matches
silicon.

There are two scripts. [`floorplan.sh`](./floorplan.sh) is the tool — point it at your own
netlist. [`edge-sensor-demo.sh`](./edge-sensor-demo.sh) is a thin wrapper over it that runs a
taped-out block and checks the answer against silicon, so the demo exercises the same code path a
developer would use rather than a parallel copy of it.

## [`floorplan.sh`](./floorplan.sh) — your design

```sh
vyges install physical && vyges install loom
export PATH="$HOME/.vyges/bin:$PATH"

vyges pdk-store list                 # what is registered
vyges pdk-store fetch sky130a        # materialize it, if it is not local yet
export PDK_ROOT=/where/sky130A/lives # the directory CONTAINING sky130A

./flows/floorplan.sh --netlist build/my_block.v --die-area '0 0 700 700'
```

The PDK is resolved through `vyges pdk-store`, so no vendor directory layout is hard-coded here —
`--pdk` takes any registered name and `--library` any library in it. `--help` lists the rest: site,
margins or an explicit core area, supply nets and pin patterns, tap and endcap masters, rail and
strap geometry, and `--check-def` to compare the result against a reference.

It is fast enough for a dev loop — seconds on a small block, well under a minute on a large one —
so it belongs in the edit-run cycle rather than at the end of one.

## [`edge-sensor-demo.sh`](./edge-sensor-demo.sh) — a block that was fabricated

Builds a floorplan for a block of the [Vyges edge-sensor SoC](https://github.com/vyges/vyges-edge-sensor-soc):

```text
import  ->  ifp  ->  make-tracks  ->  tap  ->  global-connect  ->  pdn
```

Six steps, four static binaries — `vyges-opendb`, `vyges-ifp`, `vyges-tap`, `vyges-pdn` — and no
OpenROAD. Nothing starts a container, sources a Tcl script, or needs anything from PyPI.

```sh
git clone --depth 1 https://github.com/vyges/vyges-edge-sensor-soc
./flows/edge-sensor-demo.sh --repo vyges-edge-sensor-soc --design fft_ctrl_tlul
```

The design repo is **only ever read** — it is taped-out silicon, and nothing here writes into it.
Output goes to `--out` (default `./build`). Any option it does not recognise is passed through to
`floorplan.sh`.

### Where the numbers come from

Every value the flow uses is read from the block's own signed-off `resolved.json` — die area, site,
PDN layers, widths, pitches and offsets. The wrapper chooses nothing; it refuses outright, rather
than quietly building something else, if a block asks for `FP_SIZING` other than absolute or for a
PDN core ring. The one number not in that
file is the core area, which with `FP_SIZING: absolute` is the die inset by the margins:
`LEFT/RIGHT_MARGIN_MULT` site widths and `TOP/BOTTOM_MARGIN_MULT` row heights.

The input netlist is filtered first. The repo ships **post-PnR** netlists, which already contain
the fillers, decaps, tapcells and diodes a floorplan flow inserts — asking `tap` to insert tapcells
into a design that has 17,000 of them would test nothing. Every master removed has power-only
connectivity, so removing it cannot change logic.

### Checked against the silicon

Where the design repo also ships the block's taped-out DEF, the wrapper passes it to
`--check-def`, and the flow finishes by comparing its own rows and tracks against it, exiting
non-zero if they differ. Rows and tracks are settled at
floorplan and never move afterwards, so they can be compared against a routed DEF; components and
power shapes cannot, because placement, CTS and routing all change them.

For `fft_ctrl_tlul` — 42,270 cells — all 543 rows and all 12 track records are identical to the
DEF that was taped out.

### Logging

Every engine logs through one path: `VYGES_LOG` (`trace|debug|info|warn|error`) sets the level and
`VYGES_LOG_FORMAT` (`text|json`) the rendering. `VYGES_LOG=debug` adds each stage's own counters.

## License

These scripts are Apache-2.0 — see [LICENSE](../LICENSE) and [NOTICE](../NOTICE).
© 2026 <https://vyges.com.> All Rights Reserved.

The engines they invoke and the PDK they resolve are separate: each carries its own terms, from
its own repository or its own supplier. Nothing here relicenses them, and the PDK in particular
may well be one you cannot redistribute at all.
