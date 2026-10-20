# flows — construction, driven from a shell

The rest of this testbench drives **read-only** Loom engines (timing, power, DRC, LVS …) through
`vyges mcp`, and asks whether a model can pick the right tool from the descriptors alone.

This directory is the other half: the **construction** engines, driven from an ordinary shell
script with no MCP and no model in the loop. What is being shown is not tool choice but that the
engines compose — each one reading what the previous one wrote — and that the result matches
silicon.

There are three scripts. [`floorplan.sh`](./floorplan.sh) is the tool — point it at your own
netlist. [`edge-sensor-demo.sh`](./edge-sensor-demo.sh) is a thin wrapper over it that runs a
taped-out block and checks the answer against silicon, so the demo exercises the same code path a
developer would use rather than a parallel copy of it. [`io-ring.sh`](./io-ring.sh) does the other
half of the die — the IO ring and the RDL that reaches it.

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

## [`place.sh`](./place.sh), [`route.sh`](./route.sh), [`implement.sh`](./implement.sh) — past the floorplan

The floorplan is the first third of a block. These take it the rest of the way, in the same style:
one numbered step per engine, each reading what the last one wrote.

```text
place.sh      io pins  ->  gpl  ->  rsz repair_design  ->  dpl legalize  ->  dpl check  ->  cts  ->  rsz repair_clock_nets  ->  dpl
route.sh      grt  ->  antenna repair  ->  dpl check  ->  drt  ->  write DEF  ->  ant  ->  disconnected pins  ->  fill
implement.sh  floorplan.sh  ->  place.sh  ->  route.sh
```

`route.sh` can also repair timing on the global routes before detailed routing (rsz
repair_timing, setup then hold, then legalize and route again). It is off by default, as the open
flow ships it; `--grt-timing-repair` turns it on, on `route.sh` or `implement.sh`.

Every step that adds cells (buffers, clock buffers, diodes, fillers) ends by connecting their supply
pins to the supply nets, as the open flow ends each of its steps. The floorplan's straps become the
supplies' block pins (`--no-pdn-pins` keeps them off), and `route.sh` stops on a critical disconnected
pin before filling the design (`--warn-disconnected-pins` reports it and goes on).

```sh
./flows/implement.sh --netlist build/my_block.v --die-area '0 0 400 400' \
                     --clock-port clk_i --clock-period 50 --skip-repair --ideal-clock
```

Each script also stands alone, so a segment can start from someone else's result: `route.sh --def`
routes any placed DEF, and `place.sh --def` places any floorplan.

Antenna repair runs inside the global router, on its routes: jumpers first, then a diode beside
each gate still in violation, the diodes legalized onto the rows and the nets they touched
rerouted, for up to `--antenna-iterations` passes (default 3, margin `--antenna-margin` 10 %).
`--diode-cell` names the diode; without it the library's first antenna cell is used.
`--no-antenna-repair` routes without it. `edge-sensor-demo.sh` reads all three from the block's
own configuration.

The IO pins are two engines: `ppl` chooses each pin's position on the die edge and `opendb`
writes it into the database as a pin shape. Constraints come from `--sdc`, or are generated from
`--clock-port` and `--clock-period` with input and output delays as a percentage of the period.

### `--skip-repair` and `--ideal-clock`

Two stages decline today's real netlists, and each says so with exit 3 and its reason:

- **`rsz`** declines a design with tie cells (a cell driving a constant). Almost every synthesized
  netlist has them. `--skip-repair` places the design without electrical repair.
- **`cts`** finds every clock net and chooses its buffers, then stops before building the tree.
  `--ideal-clock` carries on with the clock ideal.

Without the flags the flow stops at the first such stage, which is the honest default. With them,
the result line says which stages were skipped, so a routed design produced this way is never
mistaken for one that had repair and a clock tree.

### On a fabricated block

`edge-sensor-demo.sh --through place|route` takes an edge-sensor block past the floorplan. Past the
floorplan it reads the block's `<name>.nl.v`, the netlist an open flow hands to placement, and
takes the clock, IO layers, routing layers and global-routing adjustment from the same
`resolved.json` as the floorplan values.

```sh
./flows/edge-sensor-demo.sh --repo vyges-edge-sensor-soc --design rv_plic_lite \
                            --through place --skip-repair --ideal-clock
```

`rv_plic_lite` places in about 13 seconds: 211 IO pins, 5,484 instances, every cell on a legal site
and `check-placement` clean across every rule family it can run on the design.

Routing it is not yet practical. Global routing completes in about a minute (3,167 nets), but with
heavy overflow — initial-only placement packs the cells together — and detailed routing on that
congested result had not finished after more than an hour, so `route.sh` has not yet been run end
to end on this block. It is exercised on placed designs that come from a full placer.

### Logging

Every engine logs through one path: `VYGES_LOG` (`trace|debug|info|warn|error`) sets the level and
`VYGES_LOG_FORMAT` (`text|json`) the rendering. `VYGES_LOG=debug` adds each stage's own counters.

## License

These scripts are Apache-2.0 — see [LICENSE](../LICENSE) and [NOTICE](../NOTICE).
© 2026 <https://vyges.com.> All Rights Reserved.

The engines they invoke and the PDK they resolve are separate: each carries its own terms, from
its own repository or its own supplier. Nothing here relicenses them, and the PDK in particular
may well be one you cannot redistribute at all.

## [`io-ring.sh`](./io-ring.sh) — the ring, and the RDL across the face of the die

`floorplan.sh` builds what is inside the core. This builds what is around it:

```text
make-io-sites → place-pad → global-connect → place-corners → place-io-fill
              → connect-by-abutment → make-io-bump-array → assign-io-bump → rdl-route
```

Nine steps, three static binaries — `pad` does seven of them, `pdn` the supply nets, `opendb` the
file I/O.

Three of the steps are **per-design data**, and the script reads them from files rather than
inventing them:

| flag | one line per | fields |
| --- | --- | --- |
| `--pads` | pad | `ROW  LOCATION  MASTER  INST  [mirror]` |
| `--assign` | bump | `BUMP  NET  [TERMINAL_INST/PIN \| -]  [dont_route]` |
| `--connect` | rule (repeatable) | `NET:PINPAT:INSTPAT:power\|ground\|signal` |

```sh
./flows/io-ring.sh --def my_flipchip.def --lef tech.lef --lef io_cells.lef \
  --h-site IOSITE --v-site IOSITE --corner-site IOSITE --corner-master PAD_CORNER \
  --pads pads.txt --connect 'VDD:VDD:.*:power' --connect 'VSS:VSS:.*:ground' \
  --bump DUMMY_BUMP --bump-origin '210.0 215.0' --bump-pitch '160 160' \
  --bump-rows 17 --bump-columns 17 --assign bumps.txt --rdl-layer metal10
```

On a 238-pad flip-chip that is 934 fill cells, 289 bumps, 279 assignments and **273 of 273 nets
routed** in one iteration — 1499 components and 3454 routed wire statements out.

**The exit status is the router's.** If nets are left unrouted the script says so, still writes the
partial DEF so you can see *where* it ran out of room, and exits non-zero. Squeeze the same design
to `--rdl-width 40 --rdl-spacing 40` and it places 4 of 273 and exits 1. A floorplan you cannot
finish routing is not a pass, and this script does not round it up to one.
