#!/usr/bin/env bash
#
# SPDX-License-Identifier: Apache-2.0
# © 2026 https://vyges.com. All Rights Reserved.
#
# This script is licensed under the Apache License, Version 2.0; see LICENSE and NOTICE.
# http://www.apache.org/licenses/LICENSE-2.0
#
# Floorplan a block of the Vyges edge-sensor SoC — a worked example of ./floorplan.sh on a design
# that has actually been fabricated.
#
#   git clone --depth 1 https://github.com/vyges/vyges-edge-sensor-soc
#   ./flows/edge-sensor-demo.sh --repo vyges-edge-sensor-soc --design fft_ctrl_tlul
#
# Where the design repo ships that block's taped-out DEF, this finishes by comparing the rows and
# tracks it just produced against the silicon, and exits non-zero if they differ.
#
# Everything the flow uses is read from the block's own signed-off resolved.json — die area, site,
# PDN layers, widths, pitches and offsets. This script chooses nothing.
#
# The design repo is only ever READ. It is taped-out silicon; nothing here writes into it.
#
# OPTIONS
#   --repo DIR      a clone of vyges-edge-sensor-soc      (default: $PWD)
#   --design NAME   any block under its signoff/          (default: rv_plic_lite)
#   --out DIR       where to write                        (default: ./build)
#   --through STAGE floorplan (default), place or route — how far to take the block
#   ...any other option is passed through (--pdk, --pdk-root, --bin, --skip-repair, --ideal-clock, ...)
#
# --through place|route goes on through ./implement.sh. Past the floorplan the netlist is the
# block's <name>.nl.v — the one an open flow hands to placement, without the supply ports a
# powered netlist carries — and the clock, IO layers, routing layers and global-routing adjustment
# are read from the same resolved.json. Today that needs --skip-repair --ideal-clock: see
# ./place.sh.
#
set -euo pipefail

REPO=${VYGES_DESIGN_REPO:-$PWD} DESIGN=rv_plic_lite OUT=build THROUGH=floorplan PASS=()
while [ $# -gt 0 ]; do
  case $1 in
    --repo)   REPO=$2; shift 2 ;;
    --design) DESIGN=$2; shift 2 ;;
    --out)    OUT=$2; shift 2 ;;
    --through) THROUGH=$2; shift 2 ;;
    -h|--help) awk '!/^#/ && NR>1 {exit} /SPDX|©|licensed under the Apache|apache[.]org/ {next} NR>1 {sub(/^# ?/, ""); print}' "${BASH_SOURCE[0]}" | sed '/./,$!d'; exit 0 ;;
    *) PASS+=("$1"); shift ;;
  esac
done

PY=
for c in python3 python; do
  command -v "$c" >/dev/null 2>&1 && { PY=$(command -v "$c"); break; }
done
[ -n "$PY" ] || { echo "error: no python3 on PATH." >&2; exit 2; }

NETLIST=$REPO/verilog/gl/$DESIGN.v
# Placement wants the unpowered netlist: VPWR/VGND as ports are inout, and the supply nets are
# made by global-connect anyway.
[ "$THROUGH" != floorplan ] && [ -f "$REPO/verilog/gl/$DESIGN.nl.v" ] && NETLIST=$REPO/verilog/gl/$DESIGN.nl.v
CONFIG=$REPO/signoff/$DESIGN/openlane-signoff/resolved.json
for f in "$NETLIST" "$CONFIG"; do
  [ -f "$f" ] || {
    echo "error: $f not found." >&2
    echo "       --repo must point at a clone of vyges-edge-sensor-soc (it is only read):" >&2
    echo "       git clone --depth 1 https://github.com/vyges/vyges-edge-sensor-soc" >&2
    [ -d "$REPO/signoff" ] && echo "       blocks in $REPO: $(ls "$REPO/signoff" | tr '\n' ' ')" >&2
    exit 2
  }
done

# The block's own numbers. The core area is the one value not in the file: with FP_SIZING absolute
# it is the die inset by LEFT/RIGHT_MARGIN_MULT site widths and TOP/BOTTOM_MARGIN_MULT row heights.
IFS="|" read -r DIE MARGINS SITE RAIL VSTRIPE HSTRIPE < <("$PY" - "$CONFIG" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
site_w, site_h = 0.46, 2.72                        # sky130 unithd
def um(v):
    # Fixed decimals, not %g: %g counts SIGNIFICANT digits, so 1294.48 would render as "1294".
    return f"{v:.4f}".rstrip("0").rstrip(".") or "0"
# Refuse what this flow does not build, rather than quietly producing a different floorplan.
if c.get("FP_SIZING", "absolute") != "absolute":
    sys.exit(f'FP_SIZING is {c["FP_SIZING"]!r}; the margin rule here assumes "absolute"')
if c.get("FP_PDN_CORE_RING"):
    sys.exit("this block asks for a PDN core ring, which this flow does not build")
print(" ".join(str(v) for v in c["DIE_AREA"]),
      f'{um(c.get("LEFT_MARGIN_MULT", 12) * site_w)} {um(c.get("BOTTOM_MARGIN_MULT", 4) * site_h)}',
      c.get("PLACE_SITE", "unithd"),
      f'{c["FP_PDN_RAIL_LAYER"]}:{c["FP_PDN_RAIL_WIDTH"]}',
      f'{c["FP_PDN_VERTICAL_LAYER"]}:{c["FP_PDN_VWIDTH"]}:{c["FP_PDN_VPITCH"]}:{c["FP_PDN_VOFFSET"]}',
      f'{c["FP_PDN_HORIZONTAL_LAYER"]}:{c["FP_PDN_HWIDTH"]}:{c["FP_PDN_HPITCH"]}:{c["FP_PDN_HOFFSET"]}',
      sep="|")
PY
)
# A failure inside <(...) does not trip `set -e` on its own, so check the read produced something.
[ -n "$DIE" ] && [ -n "$HSTRIPE" ] || { echo "error: could not read $CONFIG (see above)" >&2; exit 2; }

# The repo ships POST-PnR netlists, so the physical cells this flow inserts are already in them.
SILICON=$REPO/def/$DESIGN.def
[ -f "$SILICON" ] && PASS+=(--check-def "$SILICON")

# "${PASS[@]}" alone is an unbound-variable error on an EMPTY array under `set -u` in bash 3.2,
# which is what macOS still ships. The +alternate form expands to nothing when the array is
# empty and to the quoted elements otherwise, so it is correct on both bash 3.2 and bash 5.
if [ "$THROUGH" != floorplan ]; then
  # The place and route settings, from the same file.
  IFS="|" read -r CLK PERIOD IOH IOV RTMIN RTMAX ADJ DENS < <("$PY" - "$CONFIG" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
print(c["CLOCK_PORT"] if isinstance(c["CLOCK_PORT"], str) else c["CLOCK_PORT"][0], c["CLOCK_PERIOD"],
      c.get("FP_IO_HLAYER", "met3"), c.get("FP_IO_VLAYER", "met2"),
      c.get("RT_MIN_LAYER", "met1"), c.get("RT_MAX_LAYER", "met4"), c.get("GRT_ADJUSTMENT", 0.3),
      c.get("PL_TARGET_DENSITY_PCT", 70) / 100, sep="|")
PY
)
  [ -n "$DENS" ] || { echo "error: could not read the place and route settings from $CONFIG" >&2; exit 2; }
  exec "$(dirname "${BASH_SOURCE[0]}")/implement.sh" --through "$THROUGH" \
    --netlist "$NETLIST" --die-area "$DIE" --margins "$MARGINS" --site "$SITE" \
    --rail "$RAIL" --vstripe "$VSTRIPE" --hstripe "$HSTRIPE" --strip-physical --out "$OUT" \
    --clock-port "$CLK" --clock-period "$PERIOD" --density "$DENS" --io-hlayer "$IOH" --io-vlayer "$IOV" \
    --min-layer "$RTMIN" --max-layer "$RTMAX" --adjustment "$ADJ" "${PASS[@]+"${PASS[@]}"}"
fi
exec "$(dirname "${BASH_SOURCE[0]}")/floorplan.sh" \
  --netlist "$NETLIST" --die-area "$DIE" --margins "$MARGINS" --site "$SITE" \
  --rail "$RAIL" --vstripe "$VSTRIPE" --hstripe "$HSTRIPE" \
  --strip-physical --out "$OUT" "${PASS[@]+"${PASS[@]}"}"
