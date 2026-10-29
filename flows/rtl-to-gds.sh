#!/usr/bin/env bash
#
# SPDX-License-Identifier: Apache-2.0
# © 2026 https://vyges.com. All Rights Reserved.
#
# This script is licensed under the Apache License, Version 2.0; see LICENSE and NOTICE.
# http://www.apache.org/licenses/LICENSE-2.0
#
# RTL to GDS with the Vyges Loom engines, the stream-out checked by a second writer.
#
#     synthesize  ->  implement.sh (timing, floorplan, place, route)  ->  write-gds
#                                                                     ->  KLayout stream-out  ->  XOR
#
# Synthesis is `vyges physical syn`, every stage after it a Loom engine, and the GDS is written by
# `vyges opendb write-gds`. Then the routed DEF is streamed out a second time the way an open flow
# streams it out, with KLayout, and the two GDS files are compared layer by layer: the run exits 1
# unless they are identical. Two writers that share no code drawing the same mask is the check.
#
#   ./flows/rtl-to-gds.sh --rtl rtl/pkg.sv --rtl rtl/top.sv --top my_block \
#                         --die-area '0 0 400 400' --clock-port clk_i --clock-period 20
#
# See ./ascon-rtl-to-gds-demo.sh for a worked example on a public design.
#
# OPTIONS
#   --rtl FILE            SystemVerilog source, in compile order (repeatable; required)
#   --top NAME            the top module (required)
#   --dont-use FILE       cells no engine may insert (default: the PDK's drc_exclude.cells)
#   --synth-dont-use FILE cells synthesis may not map onto, besides --dont-use's (default: the PDK's
#                         no_synth.cells) — the split an open flow makes
#   --map FILE            the PDK's KLayout LEF/DEF layer map (default: libs.tech/klayout/tech/*.map)
#   --lyt FILE            the PDK's KLayout technology (default: libs.tech/klayout/tech/*.lyt)
#   --no-xor              skip the KLayout stream-out and the XOR
#   --out DIR             where to write (default ./build)
#   --pdk / --library / --corner / --pdk-root / --bin    as in ./floorplan.sh
#   ...every other option goes to ./implement.sh (--die-area, --clock-port, --clock-period, ...)
#
# EXIT STATUS: 0 written, routed clean and identical to the KLayout stream-out · 1 the two GDS
# files differ, or the design routed with findings standing (it is still streamed out and compared)
# · 2 bad input or a missing tool · anything else, the failing stage's own status.
#
# The XOR needs the KLayout Python module: pip install klayout. Without it the run stops after
# write-gds and says so, unless --no-xor was given.
#
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PDK=${VYGES_PDK:-sky130a} LIB=sky130_fd_sc_hd CORNER=tt_025C_1v80 OUT=build BIN=${VYGES_BIN:-}
RTL=() TOP= DONT_USE_FILE= SYNTH_DONT_USE_FILE= MAP= LYT= XOR=1 IMPL=()
while [ $# -gt 0 ]; do
  case $1 in
    --rtl)            RTL+=("$2"); shift 2 ;;
    --top)            TOP=$2; shift 2 ;;
    --dont-use)       DONT_USE_FILE=$2; shift 2 ;;
    --synth-dont-use) SYNTH_DONT_USE_FILE=$2; shift 2 ;;
    --map)            MAP=$2; shift 2 ;;
    --lyt)            LYT=$2; shift 2 ;;
    --no-xor)         XOR=0; shift ;;
    --out)            OUT=$2; shift 2 ;;
    --pdk)            PDK=$2; IMPL+=("$1" "$2"); shift 2 ;;
    --library)        LIB=$2; IMPL+=("$1" "$2"); shift 2 ;;
    --corner)         CORNER=$2; IMPL+=("$1" "$2"); shift 2 ;;
    --pdk-root)       export PDK_ROOT=$2; IMPL+=("$1" "$2"); shift 2 ;;
    --bin)            BIN=$2; IMPL+=("$1" "$2"); shift 2 ;;
    -h|--help)
      awk '!/^#/ && NR>1 {exit} /SPDX|©|licensed under the Apache|apache[.]org/ {next} NR>1 {sub(/^# ?/, ""); print}' "${BASH_SOURCE[0]}" | sed '/./,$!d'; exit 0 ;;
    *)                IMPL+=("$1"); shift ;;
  esac
done
[ ${#RTL[@]} -gt 0 ] || { echo "error: --rtl FILE is required (repeatable)" >&2; exit 2; }
[ -n "$TOP" ] || { echo "error: --top NAME is required" >&2; exit 2; }

# shellcheck source=_common.sh
. "$HERE/_common.sh"
SYN=$(eng syn) ODB=$(eng opendb)
pdk_resolve
STORE=${BIN:+$BIN/}vyges-pdk-store; [ -n "$BIN" ] || STORE=$(command -v vyges-pdk-store)
CELL_GDS=$("$STORE" resolve "$PDK" gds --library "$LIB" 2>/dev/null | head -1) || true
[ -f "${CELL_GDS:-}" ] || { echo "error: could not resolve the cell GDS for '$PDK' library $LIB: vyges pdk-store show $PDK" >&2; exit 2; }
# The PDK directory the store resolved into: the open-flow and KLayout collateral live under it.
PDKDIR=${TLEF%/libs.ref/*}
first() { local f; for f in "$@"; do [ -f "$f" ] && { echo "$f"; return; }; done; }
DONT_USE_FILE=${DONT_USE_FILE:-$(first "$PDKDIR/libs.tech/openlane/$LIB/drc_exclude.cells")}
SYNTH_DONT_USE_FILE=${SYNTH_DONT_USE_FILE:-$(first "$PDKDIR/libs.tech/openlane/$LIB/no_synth.cells")}
MAP=${MAP:-$(first "$PDKDIR"/libs.tech/klayout/tech/*.map)}
LYT=${LYT:-$(first "$PDKDIR"/libs.tech/klayout/tech/*.lyt)}
[ -f "${MAP:-}" ] || { echo "error: no KLayout layer map under $PDKDIR/libs.tech/klayout/tech; pass --map FILE" >&2; exit 2; }
names() { [ -n "${1:-}" ] && sed 's/#.*//' "$1" | tr -s ' \t\n' ' ' | sed 's/^ //; s/ $//'; return 0; }

mkdir -p "$OUT"
banner() { printf '\n\033[1;7m %s \033[0m\n' "$*"; }
T0=$(date +%s)
echo "pdk:     $PDK · $LIB · $CORNER"
echo "engines: $(dirname "$SYN")"

banner "synthesize — RTL to a $LIB netlist"
NETLIST=$OUT/$TOP.v
SDU="$(names "$SYNTH_DONT_USE_FILE") $(names "$DONT_USE_FILE")"
SYN_DU=(); [ -n "${SDU// /}" ] && SYN_DU=(--dont-use "$SDU")
runq "$SYN" synthesize --liberty "$LIBERTY" --lef "$TLEF" --lef "$CLEF" "${SYN_DU[@]+"${SYN_DU[@]}"}" \
  -o "$NETLIST" "${RTL[@]}" --top "$TOP"
echo "  $(grep -c "^ *$LIB" "$NETLIST" || true) cells -> $NETLIST"

banner "implement — netlist to a routed design"
DU=(); [ -n "$DONT_USE_FILE" ] && DU=(--dont-use "$DONT_USE_FILE")
# Exit 1 is a design that routed with findings standing (antenna violations, markers): it is still
# a layout, so it is streamed out, and the run's own exit says so at the end. Anything above 1 stops.
IMPL_RC=0
"$HERE/implement.sh" --netlist "$NETLIST" --out "$OUT" "${DU[@]+"${DU[@]}"}" "${IMPL[@]+"${IMPL[@]}"}" || IMPL_RC=$?
[ "$IMPL_RC" -le 1 ] || exit "$IMPL_RC"
DEF=$OUT/filled.def; [ -f "$DEF" ] || DEF=$OUT/routed.def
ROUTE_NOTE=; [ "$IMPL_RC" = 0 ] || ROUTE_NOTE="; routed with findings standing, see the route result above"

banner "write-gds — the routed design as GDSII"
GDS=$OUT/$TOP.gds
runq "$ODB" write-gds --lef "$TLEF" --lef "$CLEF" --def "$DEF" --map "$MAP" --gds "$CELL_GDS" --output "$GDS"

if [ "$XOR" = 1 ]; then
  if ! "$PY" -c 'import klayout.db' 2>/dev/null; then
    echo "error: the XOR needs the KLayout Python module: $PY -m pip install klayout (or pass --no-xor)" >&2
    exit 2
  fi
  [ -f "${LYT:-}" ] || { echo "error: no KLayout technology under $PDKDIR/libs.tech/klayout/tech; pass --lyt FILE" >&2; exit 2; }
  banner "KLayout stream-out — the same DEF, the other writer"
  REF=$OUT/$TOP.klayout.gds
  runq "$PY" "$HERE/klayout-stream-out.py" --def "$DEF" --lef "$TLEF" --lef "$CLEF" --gds "$CELL_GDS" \
    --lyt "$LYT" --map "$MAP" --top "$TOP" -o "$REF"
  banner "XOR — $GDS against $REF"
  rc=0; runq "$PY" "$HERE/gds-xor.py" "$GDS" "$REF" || rc=$?
  banner "done in $(( $(date +%s) - T0 )) s — $GDS ($([ $rc = 0 ] && echo "identical to the KLayout stream-out" || echo "DIFFERS from the KLayout stream-out")$ROUTE_NOTE)"
  [ "$rc" != 0 ] && exit "$rc"
  exit "$IMPL_RC"
fi
banner "done in $(( $(date +%s) - T0 )) s — $GDS$ROUTE_NOTE"
exit "$IMPL_RC"
