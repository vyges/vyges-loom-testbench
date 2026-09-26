#!/usr/bin/env bash
#
# SPDX-License-Identifier: Apache-2.0
# © 2026 https://vyges.com. All Rights Reserved.
#
# This script is licensed under the Apache License, Version 2.0; see LICENSE and NOTICE.
# http://www.apache.org/licenses/LICENSE-2.0
#
# Build a floorplan for any gate-level design with the Vyges Loom engines.
#
#     import  ->  ifp  ->  make-tracks  ->  tap  ->  global-connect  ->  pdn
#
# Six steps, four static binaries, no OpenROAD. Nothing here starts a container, sources a Tcl
# script, or installs anything from PyPI. Run it on your own block as often as you like — it is
# fast enough to sit in a dev loop rather than at the end of one.
#
#   ./flows/floorplan.sh --netlist build/my_block.v --die-area '0 0 400 400'
#
# The PDK comes from the Vyges PDK store, so paths are resolved rather than guessed:
#
#   vyges pdk-store list                     # what is registered
#   vyges pdk-store fetch sky130a            # materialize it, if it is not local yet
#   export PDK_ROOT=/where/sky130A/lives     # the directory CONTAINING sky130A
#
# Install the engines with:  vyges install physical && vyges install loom
# then put ~/.vyges/bin on PATH, or pass --bin <dir>.
#
# For a worked example on a taped-out SoC, see ./edge-sensor-demo.sh, which is a thin wrapper
# over this script.
#
# OPTIONS
#   --netlist FILE        structural gate-level Verilog (required)
#   --die-area 'x1 y1 x2 y2'   in microns (required)
#   --core-area 'x1 y1 x2 y2'  in microns (default: the die inset by --margins)
#   --margins 'X Y'       core inset in microns when --core-area is not given (default '5.52 10.88')
#   --site NAME           the site whose height sets the row pitch (default unithd)
#   --pdk NAME            a name from `vyges pdk-store list` (default sky130a)
#   --library NAME        the standard-cell library (default sky130_fd_sc_hd)
#   --pdk-root DIR        sets PDK_ROOT for this run
#   --power NET / --ground NET      supply net names (default VPWR / VGND)
#   --pin-power RE / --pin-ground RE   repeatable cell-pin patterns
#                         (default ^VPWR$ and ^VPB$ / ^VGND$ and ^VNB$)
#   --tapcell MASTER      well-tap cell            (default sky130_fd_sc_hd__tapvpwrvgnd_1)
#   --endcap MASTER       row end cap              (default sky130_fd_sc_hd__decap_3)
#   --tap-distance UM     spacing between taps     (default 13)
#   --rail   L:W          followpin rail, layer and width       (default met1:0.48)
#   --vstripe L:W:P:O     vertical strap: layer, width, pitch, offset   (default met4:1.6:153.6:16.32)
#   --hstripe L:W:P:O     horizontal strap, same shape                  (default met5:1.6:153.18:16.65)
#   --strip-physical      drop fillers, decaps, taps and diodes from a POST-PnR netlist first
#   --check-def FILE      compare the rows and tracks produced against a reference DEF; exit 1 if they differ
#   --out DIR             where to write (default ./build)
#   --bin DIR             engine binaries, instead of PATH
#
set -euo pipefail

# One logging path for every engine: VYGES_LOG (trace|debug|info|warn|error) sets the level,
# VYGES_LOG_FORMAT (text|json) the rendering. The engines emit JSON when stderr is not a terminal,
# which it is not here, so ask for text and let the caller override either knob.
#   VYGES_LOG=debug ./flows/floorplan.sh ...     # each stage's own counters as well
export VYGES_LOG_FORMAT=${VYGES_LOG_FORMAT:-text}
export VYGES_LOG=${VYGES_LOG:-info}

NETLIST= DIE= CORE= MARGINS='5.52 10.88' SITE=unithd
PDK=${VYGES_PDK:-sky130a} LIB=sky130_fd_sc_hd
POWER=VPWR GROUND=VGND
TAPCELL=sky130_fd_sc_hd__tapvpwrvgnd_1 ENDCAP=sky130_fd_sc_hd__decap_3 TAPDIST=13
RAIL=met1:0.48 VSTRIPE=met4:1.6:153.6:16.32 HSTRIPE=met5:1.6:153.18:16.65
STRIP=0 CHECKDEF= OUT=build BIN=${VYGES_BIN:-}
PIN_POWER=() PIN_GROUND=()

while [ $# -gt 0 ]; do
  case $1 in
    --netlist)     NETLIST=$2; shift 2 ;;
    --die-area)    DIE=$2; shift 2 ;;
    --core-area)   CORE=$2; shift 2 ;;
    --margins)     MARGINS=$2; shift 2 ;;
    --site)        SITE=$2; shift 2 ;;
    --pdk)         PDK=$2; shift 2 ;;
    --library)     LIB=$2; shift 2 ;;
    --pdk-root)    export PDK_ROOT=$2; shift 2 ;;
    --power)       POWER=$2; shift 2 ;;
    --ground)      GROUND=$2; shift 2 ;;
    --pin-power)   PIN_POWER+=("$2"); shift 2 ;;
    --pin-ground)  PIN_GROUND+=("$2"); shift 2 ;;
    --tapcell)     TAPCELL=$2; shift 2 ;;
    --endcap)      ENDCAP=$2; shift 2 ;;
    --tap-distance) TAPDIST=$2; shift 2 ;;
    --rail)        RAIL=$2; shift 2 ;;
    --vstripe)     VSTRIPE=$2; shift 2 ;;
    --hstripe)     HSTRIPE=$2; shift 2 ;;
    --strip-physical) STRIP=1; shift ;;
    --check-def)   CHECKDEF=$2; shift 2 ;;
    --out)         OUT=$2; shift 2 ;;
    --bin)         BIN=$2; shift 2 ;;
    -h|--help) awk '!/^#/ && NR>1 {exit} /SPDX|©|licensed under the Apache|apache[.]org/ {next} NR>1 {sub(/^# ?/, ""); print}' "${BASH_SOURCE[0]}" | sed '/./,$!d'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ ${#PIN_POWER[@]}  -gt 0 ] || PIN_POWER=('^VPWR$' '^VPB$')
[ ${#PIN_GROUND[@]} -gt 0 ] || PIN_GROUND=('^VGND$' '^VNB$')

# ── the tools this needs, resolved once and named ────────────────────────────────────────────
# Two small steps below are Python. Find an interpreter before doing any work, so a missing one is
# a clear message at the start rather than a stack trace five minutes in.
PY=
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' 2>/dev/null; then
    PY=$(command -v "$c"); break
  fi
done
[ -n "$PY" ] || { echo "error: no python3 (>= 3.8) on PATH; the engines do not need it, two steps of this script do." >&2; exit 2; }

# A flow that silently picks up a different build than the reader expects is the hardest kind of
# difference to chase, so resolve every engine once and say where they came from.
eng() {
  local n=vyges-$1 p
  if [ -n "$BIN" ]; then p=$BIN/$n; else p=$(command -v "$n" 2>/dev/null || true); fi
  if [ ! -x "${p:-}" ]; then
    echo "error: $n not found." >&2
    echo "       install:  vyges install physical && vyges install loom" >&2
    echo "       then add ~/.vyges/bin to PATH, or pass --bin <dir>." >&2
    exit 1
  fi
  echo "$p"
}
IFP=$(eng ifp); TAP=$(eng tap); PDN=$(eng pdn); ODB=$(eng opendb)
# The store comes from the same place as the engines: with --bin, from that directory. It was
# looked up on PATH alone, so a machine that keeps ~/.vyges/bin off PATH and passes --bin found
# every engine and then stopped here.
if [ -n "$BIN" ]; then STORE=$BIN/vyges-pdk-store; else STORE=$(command -v vyges-pdk-store 2>/dev/null || true); fi
[ -x "$STORE" ] || { echo "error: vyges-pdk-store not found; install it with 'vyges install loom', or pass --bin <dir>." >&2; exit 1; }

[ -n "$NETLIST" ] || { echo "error: --netlist <gate-level.v> is required." >&2; exit 2; }
[ -f "$NETLIST" ] || { echo "error: no such netlist: $NETLIST" >&2; exit 2; }
[ -n "$DIE" ]     || { echo "error: --die-area 'x1 y1 x2 y2' is required (microns)." >&2; exit 2; }

# ── the PDK, resolved by the store rather than assembled by hand ─────────────────────────────
# The store knows where each piece of collateral lives for a given PDK and library, so this script
# never hard-codes a vendor's directory layout. `resolve` expands $PDK_ROOT.
resolve() {
  "$STORE" resolve "$PDK" "$1" "${@:2}" 2>/dev/null | head -1
}
TLEF=$(resolve tech_lef) || true
CLEF=$(resolve lef --library "$LIB") || true
if [ -z "${TLEF:-}" ] || [ -z "${CLEF:-}" ] || [ ! -f "${TLEF:-/nonexistent}" ] || [ ! -f "${CLEF:-/nonexistent}" ]; then
  echo "error: could not resolve the tech LEF and $LIB LEF for PDK '$PDK'." >&2
  echo "       registered PDKs:   vyges pdk-store list" >&2
  echo "       fetch the data:    vyges pdk-store fetch $PDK" >&2
  echo "       point at the data: export PDK_ROOT=/dir/containing/the/pdk   (or --pdk-root)" >&2
  [ -n "${TLEF:-}" ] && echo "       resolved tech LEF: $TLEF" >&2
  [ -n "${CLEF:-}" ] && echo "       resolved cell LEF: $CLEF" >&2
  exit 2
fi

# The core is the die inset by the margins, unless the caller states it outright.
if [ -z "$CORE" ]; then
  CORE=$("$PY" - "$DIE" "$MARGINS" <<'PY'
import sys
d = [float(v) for v in sys.argv[1].split()]
mx, my = (float(v) for v in sys.argv[2].split())
def um(v):
    # Fixed decimals, not %g: %g counts SIGNIFICANT digits, so 1294.48 would render as "1294".
    return f"{v:.4f}".rstrip("0").rstrip(".") or "0"
print(" ".join(um(v) for v in (d[0]+mx, d[1]+my, d[2]-mx, d[3]-my)))
PY
)
fi

DESIGN=$(basename "$NETLIST"); DESIGN=${DESIGN%.v}
mkdir -p "$OUT"
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }
step "$DESIGN — die [$DIE], core [$CORE], site $SITE"
echo "pdk:     $PDK · $LIB · $(dirname "$(dirname "$TLEF")")"
echo "engines: $(dirname "$IFP")"

# 0 ── the netlist ────────────────────────────────────────────────────────────────────────────
# A POST-PnR netlist already contains the fillers, decaps, taps and diodes that this flow inserts;
# asking `tap` to insert taps into a design that has thousands of them tests nothing. Every master
# dropped here has power-only connectivity, so dropping it cannot change logic.
SRC=$NETLIST
if [ "$STRIP" = 1 ]; then
  step "0 · strip the physical-only cells the netlist already carries"
  SRC=$OUT/$DESIGN.stripped.v
  "$PY" - "$NETLIST" "$SRC" <<'PY'
import re, sys
PHYS  = re.compile(r"^\S*__(decap|fill|tapvpwrvgnd|tap|diode)")
START = re.compile(r"^\s*([A-Za-z_]\S*)\s+(\S+)\s*\(")
out, buf, master, kept, dropped = [], None, None, 0, 0
for line in open(sys.argv[1]):
    if buf is None:
        m = START.match(line)
        if not m or m.group(1) in ("module", "input", "output", "inout", "wire", "assign"):
            out.append(line)
            continue
        buf, master = [line], m.group(1)
    else:
        buf.append(line)
    if line.rstrip().endswith(");"):
        if PHYS.match(master):
            dropped += 1
        else:
            kept += 1
            out.extend(buf)
        buf = master = None
open(sys.argv[2], "w").writelines(out)
print(f"  kept {kept} cells, dropped {dropped} physical-only")
PY
fi

# 1 ── a design database, from LEF + Verilog ─────────────────────────────────────────────────
# The FIRST --lef creates the technology; the tech LEF therefore goes first.
step "1 · import — LEF + Verilog into a database"
"$ODB" import --lef "$TLEF" --lef "$CLEF" --verilog "$SRC" \
              --output "$OUT/1.handoff.odb" 2>&1 | sed 's/^/  /'

# 2 ── the floorplan ─────────────────────────────────────────────────────────────────────────
step "2 · ifp — die, core and rows"
"$IFP" run "$OUT/1.handoff.odb" --die-area "$DIE" --core-area "$CORE" --site "$SITE" \
       --out-odb "$OUT/2.floorplan.odb" 2>&1 | sed 's/^/  /'

step "3 · ifp make-tracks — routing tracks from the technology's own pitches"
"$IFP" make-tracks "$OUT/2.floorplan.odb" --out-odb "$OUT/3.tracks.odb" 2>&1 | sed 's/^/  /'

# 4 ── taps and endcaps ──────────────────────────────────────────────────────────────────────
step "4 · tap — cut the rows, place endcaps and well taps"
"$TAP" tapcell "$OUT/3.tracks.odb" --tapcell-master "$TAPCELL" --endcap-master "$ENDCAP" \
       --distance "$TAPDIST" --out-odb "$OUT/4.tap.odb" 2>&1 | sed 's/^/  /'

# 5 ── the supply nets ───────────────────────────────────────────────────────────────────────
# Without this there are no supply nets to build a grid on, and step 6 has nothing to do.
step "5 · pdn global-connect — create $POWER/$GROUND and connect every cell's supply pins"
CONNECT=()
for re in "${PIN_POWER[@]}";  do CONNECT+=(--connect "$POWER:$re:.*:power");   done
for re in "${PIN_GROUND[@]}"; do CONNECT+=(--connect "$GROUND:$re:.*:ground"); done
"$PDN" global-connect "$OUT/4.tap.odb" "${CONNECT[@]}" \
       --out-odb "$OUT/5.connected.odb" 2>&1 | sed 's/^/  /'

# 6 ── the power grid ────────────────────────────────────────────────────────────────────────
step "6 · pdn generate — rails, straps and the vias between them"
IFS=: read -r RL RW <<<"$RAIL"
IFS=: read -r VL VW VP VO <<<"$VSTRIPE"
IFS=: read -r HL HW HP HO <<<"$HSTRIPE"
"$PDN" generate "$OUT/5.connected.odb" --out-def "$OUT/6.floorplan.def" \
       --power "$POWER" --ground "$GROUND" --voltage-domains CORE --grid stdcell:core \
       --followpins "$RL:core:$RW" \
       --stripe "$VL:$VW:$VP:$VO:core:0:::::" \
       --stripe "$HL:$HW:$HP:$HO:core:0:::::" \
       --connect "$RL,$VL::::::::" --connect "$VL,$HL::::::::" --trim 1 \
       > "$OUT/6.pdn.json" 2> "$OUT/6.pdn.log"
sed 's/^/  /' "$OUT/6.pdn.log" "$OUT/6.pdn.json"

# ── what came out ───────────────────────────────────────────────────────────────────────────
DEF=$OUT/6.floorplan.def
step "result — $DEF"
# Straps and vias are the ENGINE's own counts: a via is written with the same SHAPE keyword as a
# strap, so counting DEF lines would conflate the two.
printf '  %-12s %s\n' \
  rows       "$(grep -c '^ROW '   "$DEF")" \
  tracks     "$(grep -c '^TRACKS' "$DEF")" \
  components "$(awk '/^COMPONENTS/,/^END COMPONENTS/' "$DEF" | grep -c '^ *- ')" \
  "pdn straps" "$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))["shapes"])' "$OUT/6.pdn.json")" \
  "pdn vias"   "$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))["vias"])'   "$OUT/6.pdn.json")"

# The whole toolchain this flow needed, on disk. There is nothing else to install.
printf '\n  built by %s engines totalling %s\n' \
  "$(printf '%s\n' "$IFP" "$TAP" "$PDN" "$ODB" | sort -u | wc -l | tr -d ' ')" \
  "$(du -Lch "$IFP" "$TAP" "$PDN" "$ODB" 2>/dev/null | tail -1 | cut -f1)"

# ── against a reference ─────────────────────────────────────────────────────────────────────
# Rows and tracks are settled at floorplan and never move afterwards, so they can be compared
# against even a fully routed DEF. Components and power shapes cannot: placement, CTS and routing
# all change them.
if [ -n "$CHECKDEF" ]; then
  [ -f "$CHECKDEF" ] || { echo "error: no such reference DEF: $CHECKDEF" >&2; exit 2; }
  step "against $CHECKDEF"
  for what in ROW TRACKS; do
    a=$(grep "^$what " "$CHECKDEF" | sed 's/ *;.*//' | sort)
    b=$(grep "^$what " "$DEF"      | sed 's/ *;.*//' | sort)
    if [ "$a" = "$b" ]; then
      printf '  MATCH  %-7s %s identical\n' "$what" "$(printf '%s\n' "$a" | grep -c .)"
    else
      printf '  DIFFER %-7s reference %s, ours %s\n' "$what" \
        "$(printf '%s\n' "$a" | grep -c .)" "$(printf '%s\n' "$b" | grep -c .)"
      exit 1
    fi
  done
fi
