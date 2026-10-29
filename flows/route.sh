#!/usr/bin/env bash
#
# SPDX-License-Identifier: Apache-2.0
# © 2026 https://vyges.com. All Rights Reserved.
#
# This script is licensed under the Apache License, Version 2.0; see LICENSE and NOTICE.
# http://www.apache.org/licenses/LICENSE-2.0
#
# Route a placed design with the Vyges Loom engines, repairing antennas on the way, then check it.
#
#     [rsz repair_design (on the global routes)  ->  dpl legalize  ->  dpl check]
#         ->  grt (route, then repair antennas)  ->  dpl check  ->  [rsz repair_timing (on the global routes)
#         ->  dpl legalize  ->  dpl check  ->  grt (route again)]  ->  drt  ->  write DEF  ->  ant
#         ->  disconnected pins  ->  wire length  ->  fill
#
# The design repair on the global routes is OFF by default, as an open flow ships it, and runs with
# --grt-design-repair: slews, capacitances and fanout repaired on parasitics estimated from a global
# route (no wire-length buffering unless --grt-design-max-wire-length), the cells legalized, then the
# routing and antenna repair below — the open flow's order.
# The timing repair on the global routes is OFF by default, as an open flow ships it, and runs with
# --grt-timing-repair: the design routed again inside it and timed on those routes, setup paths
# first, then hold, each with a slack margin and a cap on the buffers it may add; the cells it moved
# or added legalized, and the whole design routed again for the detailed router. A design the repair
# declines goes on as the antenna repair left it.
#
# Antenna repair runs inside the global router, on its routes: jumpers first, then a diode beside
# each gate still in violation, the diodes legalized onto the rows, and the nets they touched
# rerouted, repeated up to --antenna-iterations times. The defaults are the open flow's. Every step
# that adds cells (diodes, buffers, fillers) ends by connecting their supply pins to the supply nets.
#
# The input is a placed design: the database ./place.sh writes, or any placed DEF. The output is
# a routed database and DEF, and the same with every empty site filled — decap cells first, then
# filler cells, as an open flow fills a routed block before streaming it out.
#
#   ./flows/route.sh --odb build/placed.odb
#   ./flows/route.sh --def my_placed_block.def
#
# OPTIONS
#   --odb FILE / --def FILE   the placed design (one is required)
#   --min-layer L         lowest routing layer            (default met1)
#   --max-layer L         highest routing layer           (default met4)
#   --adjustment F        global routing capacity reduction, 0..1 (default 0.3)
#   --no-congestion       stop if global routing cannot route without overflow
#   --diode-cell CELL     the diode antenna repair inserts (default: the library's first
#                         antenna cell with diffusion area)
#   --antenna-iterations N  repair passes at most          (default 3)
#   --antenna-margin PCT  repair to this margin under each antenna limit (default 10)
#   --no-antenna-repair   route without repairing; the ant check still reports
#   --sdc FILE            the constraints the timing repair reads (default: p0.design.sdc in --out,
#                         as ./place.sh writes it; with none the repair is skipped and says so)
#   --macro-lib FILE      a hard macro's Liberty (repeatable), for the timing repair
#   --signal-rc-layer L / --clock-rc-layer L    as in ./place.sh (default met2 / met5)
#   --power NET / --ground NET      supply net names, for the cells this script adds (default VPWR / VGND)
#   --pin-power RE / --pin-ground RE   repeatable cell-pin patterns, as ./floorplan.sh's
#                         (default ^VPWR$ and ^VPB$ / ^VGND$ and ^VNB$)
#   --ignore-disconnected-module M   a cell or macro the disconnected-pin check skips (repeatable;
#                         default on sky130: sky130_fd_sc_hd__conb_1, as an open flow's)
#   --warn-disconnected-pins   report critical disconnected pins and go on (default: stop the flow)
#   --wire-length-threshold UM   the longest routed wire allowed, in microns; above it the run fails
#                         at the end, after filling (default: none — the length is reported and the
#                         check skipped, as an open flow does when its PDK sets no threshold)
#   --warn-long-wire      report a wire above the threshold without failing the run
#   --grt-setup-margin NS / --grt-hold-margin NS    the repair's slack margins (default 0.025 / 0.05)
#   --grt-max-buffer-percent P   its cap on added buffers, percent of the instances (default 50)
#   --grt-timing-repair   run rsz repair_timing after global routing (default: off)
#   --grt-design-repair   run rsz repair_design on the global routes before the antenna repair (default: off)
#   --grt-design-max-wire-length UM / --grt-design-slew-margin PCT / --grt-design-cap-margin PCT
#                         its settings (default 0 = no wire-length buffering / 10 / 10)
#   --fill-cells 'PATTERNS'  masters to fill empty sites with, tried in order (names or globs;
#                         default sky130 hd's decaps then fills)
#   --no-fill             leave the empty sites empty
#   --threads N           detailed-routing worker threads (default: a balanced count from the
#                         machine's physical cores; VYGES_THREADS sets it for every engine); the
#                         routes are the same at any count
#   --macro-lef FILE      a hard macro's LEF (repeatable), when the input is a DEF
#   --dont-use FILE       cells the routed design must not contain (default: the PDK store's
#                         `dont_use` for the library); any found is reported and exits 1
#   --pdk / --library / --pdk-root    as in ./floorplan.sh
#   --out DIR             where to write (default ./build)
#   --bin DIR             engine binaries, instead of PATH
#
# EXIT STATUS: 0 routed clean · 1 routed, with design-rule markers or antenna violations standing ·
# 2 error · 3 a stage declined the design (its reason is printed).
#
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

POWER=VPWR GROUND=VGND PIN_POWER=() PIN_GROUND=() DISC_IGNORE=() DISC_ERROR=true
WL_THRESHOLD='' WL_ERROR=true
IN_ODB= IN_DEF= MINL=met1 MAXL=met4 ADJ=0.3 CONGEST=true
ANT_REPAIR=true DIODE= ANT_ITERS=3 ANT_MARGIN=10 DONT_USE_FILE= THREADS= FILL=true
SDC= MACRO_LIBS=() SIG_RC=met2 CLK_RC=met5 GRT_SETUP_MARGIN=0.025 GRT_HOLD_MARGIN=0.05 GRT_MAX_BUF_PCT=50 TIMING_REPAIR=false
DESIGN_REPAIR=false GRD_MAX_WIRE=0 GRD_SLEW_MARGIN=10 GRD_CAP_MARGIN=10
FILL_CELLS='sky130_ef_sc_hd__decap_12 sky130_fd_sc_hd__decap_8 sky130_fd_sc_hd__decap_6 sky130_fd_sc_hd__decap_4 sky130_fd_sc_hd__decap_3 sky130_fd_sc_hd__fill*'
MACRO_LEFS=()
PDK=${VYGES_PDK:-sky130a} LIB=sky130_fd_sc_hd CORNER=tt_025C_1v80 OUT=build BIN=${VYGES_BIN:-}

while [ $# -gt 0 ]; do
  case $1 in
    --odb)        IN_ODB=$2; shift 2 ;;
    --def)        IN_DEF=$2; shift 2 ;;
    --min-layer)  MINL=$2; shift 2 ;;
    --max-layer)  MAXL=$2; shift 2 ;;
    --adjustment) ADJ=$2; shift 2 ;;
    --no-congestion) CONGEST=false; shift ;;
    --diode-cell) DIODE=$2; shift 2 ;;
    --antenna-iterations) ANT_ITERS=$2; shift 2 ;;
    --antenna-margin) ANT_MARGIN=$2; shift 2 ;;
    --no-antenna-repair) ANT_REPAIR=false; shift ;;
    --dont-use)   DONT_USE_FILE=$2; shift 2 ;;
    --macro-lef)  MACRO_LEFS+=("$2"); shift 2 ;;
    --threads)    THREADS=$2; shift 2 ;;
    --fill-cells) FILL_CELLS=$2; shift 2 ;;
    --sdc)        SDC=$2; shift 2 ;;
    --macro-lib)  MACRO_LIBS+=("$2"); shift 2 ;;
    --signal-rc-layer) SIG_RC=$2; shift 2 ;;
    --clock-rc-layer)  CLK_RC=$2; shift 2 ;;
    --corner)     CORNER=$2; shift 2 ;;
    --grt-setup-margin) GRT_SETUP_MARGIN=$2; shift 2 ;;
    --grt-hold-margin)  GRT_HOLD_MARGIN=$2; shift 2 ;;
    --grt-max-buffer-percent) GRT_MAX_BUF_PCT=$2; shift 2 ;;
    --grt-timing-repair) TIMING_REPAIR=true; shift ;;
    --grt-design-repair) DESIGN_REPAIR=true; shift ;;
    --grt-design-max-wire-length) GRD_MAX_WIRE=$2; shift 2 ;;
    --grt-design-slew-margin) GRD_SLEW_MARGIN=$2; shift 2 ;;
    --grt-design-cap-margin) GRD_CAP_MARGIN=$2; shift 2 ;;
    # the default since the repair went opt-in; kept so an older command line still runs
    --skip-timing-repair) TIMING_REPAIR=false; shift ;;
    --no-fill)    FILL=false; shift ;;
    --power)      POWER=$2; shift 2 ;;
    --ground)     GROUND=$2; shift 2 ;;
    --pin-power)  PIN_POWER+=("$2"); shift 2 ;;
    --pin-ground) PIN_GROUND+=("$2"); shift 2 ;;
    --ignore-disconnected-module) DISC_IGNORE+=("$2"); shift 2 ;;
    --warn-disconnected-pins) DISC_ERROR=false; shift ;;
    --wire-length-threshold) WL_THRESHOLD=$2; shift 2 ;;
    --warn-long-wire) WL_ERROR=false; shift ;;
    --pdk)        PDK=$2; shift 2 ;;
    --library)    LIB=$2; shift 2 ;;
    --pdk-root)   export PDK_ROOT=$2; shift 2 ;;
    --out)        OUT=$2; shift 2 ;;
    --bin)        BIN=$2; shift 2 ;;
    -h|--help)    . "$HERE/_common.sh"; usage "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
. "$HERE/_common.sh"

ODB=$(eng opendb); GRT=$(eng grt); DRT=$(eng drt); ANT=$(eng ant); DPL=$(eng dpl); RSZ=$(eng rsz); PDN=$(eng pdn)
supply_rules
mkdir -p "$OUT"
OUT=$(abspath "$OUT"); [ -n "$SDC" ] && SDC=$(abspath "$SDC")
if [ -n "$IN_DEF" ]; then
  [ -f "$IN_DEF" ] || { echo "error: no such DEF: $IN_DEF" >&2; exit 2; }
  pdk_resolve
  def_to_odb "$IN_DEF" "$OUT/r0.placed.odb"; IN_ODB=$OUT/r0.placed.odb
fi
[ -n "$IN_ODB" ] && [ -f "$IN_ODB" ] || { echo "error: --odb <placed.odb> or --def <placed.def> is required." >&2; exit 2; }
step "routing $IN_ODB — layers $MINL..$MAXL"
echo "engines: $(dirname "$GRT")"

# 1a ── design repair on the global routes ──────────────────────────────────────────────────────
# As the open flow's post-route design repair: routed, parasitics estimated from the routes,
# repair_design, the cells legalized; the routing below starts from the legalized design.
[ -z "$SDC" ] && [ -f "$OUT/p0.design.sdc" ] && SDC=$OUT/p0.design.sdc
GRDRC=off
if [ "$DESIGN_REPAIR" = true ] && [ -z "$SDC" ]; then
  step "1a · rsz repair_design — skipped: no constraints (--sdc)"
  GRDRC=skipped
elif [ "$DESIGN_REPAIR" = true ]; then
  step "1a · rsz repair_design — slew, capacitance and fanout on the global routes"
  pdk_resolve
  dont_use_resolve
  cat > "$OUT/r1a.rd.job.json" <<EOF
{"steps": [
  {"cmd": "read_liberty", "args": ["$LIBERTY"]}, $(macro_lib_steps)$(dont_use_step)
  {"cmd": "read_db", "args": ["$IN_ODB"]}, {"cmd": "read_sdc", "args": ["$SDC"]},
  {"cmd": "set_wire_rc", "args": ["-signal", "-layer", "$SIG_RC"]},
  {"cmd": "set_wire_rc", "args": ["-clock", "-layer", "$CLK_RC"]},
  {"cmd": "set_propagated_clock", "args": []},
  {"cmd": "set_routing_layers", "args": ["-signal", "$MINL-$MAXL", "-clock", "$MINL-$MAXL"]},
  {"cmd": "set_global_routing_layer_adjustment", "args": ["*", "$ADJ"]},
  {"cmd": "global_route", "args": []},
  {"cmd": "estimate_parasitics", "args": ["-global_routing"]},
  {"cmd": "repair_design", "args": ["-verbose", "-max_wire_length", "$GRD_MAX_WIRE", "-slew_margin", "$GRD_SLEW_MARGIN", "-cap_margin", "$GRD_CAP_MARGIN"]}],
 "write_db": "$OUT/r1a.rd.odb"}
EOF
  drc=0; runq "$RSZ" repair_design "$OUT/r1a.rd.job.json" -o "$OUT/r1a.rd.json" || drc=$?
  GRDRC=$(jget "$OUT/r1a.rd.json" status)
  echo "  rsz: $GRDRC $(jget "$OUT/r1a.rd.json" reason)"
  if [ "$drc" -ne 0 ]; then
    echo "  the design repair did not run to the end (exit $drc); the design continues unrepaired (leave out --grt-design-repair to skip the attempt)." >&2
    GRDRC="$GRDRC (not applied)"
  else
    supply_connect "$OUT/r1a.rd.odb"
    step "1a · dpl — the repaired cells onto legal sites"
    "$DPL" detailed-placement "$OUT/r1a.rd.odb" --out-odb "$OUT/r1a.legal.odb" \
           > "$OUT/r1a.dpl.json" 2> >(sed 's/^/  /' >&2)
    echo "  $(jget "$OUT/r1a.dpl.json" status): $(jget "$OUT/r1a.dpl.json" moved) of $(jget "$OUT/r1a.dpl.json" cells) cells moved"
    rc=0; runq "$DPL" check-placement "$OUT/r1a.legal.odb" -o "$OUT/r1a.check.json" || rc=$?
    echo "  $(jget "$OUT/r1a.check.json" status): $(jget "$OUT/r1a.check.json" violations) violations over $(jget "$OUT/r1a.check.json" cells_checked) cells"
    [ "$rc" -eq 0 ] || exit "$rc"
    IN_ODB=$OUT/r1a.legal.odb
  fi
fi

# 1 ── global routing ────────────────────────────────────────────────────────────────────────
step "1 · grt — route guides for every net$([ "$ANT_REPAIR" = true ] && echo ", then antenna repair")"
REPAIR=
if [ "$ANT_REPAIR" = true ]; then
  REPAIR="{\"cmd\": \"repair_antennas\",${DIODE:+ \"diode_cell\": \"$DIODE\",} \"iterations\": $ANT_ITERS, \"ratio_margin\": $ANT_MARGIN, \"allow_congestion\": $CONGEST},"
fi
cat > "$OUT/r1.grt.job.json" <<EOF
{"db": "$IN_ODB",
 "steps": [{"cmd": "set_routing_layers", "signal": ["$MINL", "$MAXL"], "clock": ["$MINL", "$MAXL"]},
           {"cmd": "global_adjustment", "value": $ADJ},
           {"cmd": "global_route", "allow_congestion": $CONGEST},
           $REPAIR
           {"cmd": "write_guides", "path": "$OUT/r1.guides"},
           {"cmd": "write_db", "path": "$OUT/r1.grt.odb"}]}
EOF
rc=0; runq "$GRT" route "$OUT/r1.grt.job.json" -o "$OUT/r1.grt.json" || rc=$?
"$PY" - "$OUT/r1.grt.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
for g in r.get("global_route", []):
    print(f"  {r['status']}: {g['nets']} nets, overflow {g['total_overflow']}"
          f"{' (congested)' if g.get('congested') else ''}")
for l in r.get("log", []):
    if l.startswith(("GRT-0012", "GRT-0015", "GRT-0302", "GRT-0246")): print(f"  {l}")
if r.get("reason"): print(f"  {r['reason']}")
PY
[ "$rc" -eq 0 ] || exit "$rc"
[ "$ANT_REPAIR" = true ] && supply_connect "$OUT/r1.grt.odb"

# The diodes were legalized inside the repair; check every cell is still on a legal site.
if [ "$ANT_REPAIR" = true ]; then
  step "1b · dpl check-placement — with the antenna diodes"
  rc=0; runq "$DPL" check-placement "$OUT/r1.grt.odb" -o "$OUT/r1b.check.json" || rc=$?
  echo "  $(jget "$OUT/r1b.check.json" status): $(jget "$OUT/r1b.check.json" violations) violations over $(jget "$OUT/r1b.check.json" cells_checked) cells"
  [ "$rc" -eq 0 ] || exit "$rc"
fi

# 1c ── timing repair on the global routes ─────────────────────────────────────────────────────
DRT_IN=$OUT/r1.grt.odb GTRC=skipped
if [ "$TIMING_REPAIR" != true ]; then
  step "1c · rsz repair_timing — off (the open flow's default; --grt-timing-repair runs it)"
  GTRC="off"
elif [ -z "$SDC" ]; then
  step "1c · rsz repair_timing — skipped: no constraints (--sdc)"
else
  step "1c · rsz repair_timing — setup, then hold, on the global routes"
  pdk_resolve
  dont_use_resolve
  cat > "$OUT/r1c.rt.job.json" <<EOF
{"steps": [
  {"cmd": "read_liberty", "args": ["$LIBERTY"]}, $(macro_lib_steps)$(dont_use_step)
  {"cmd": "read_db", "args": ["$OUT/r1.grt.odb"]}, {"cmd": "read_sdc", "args": ["$SDC"]},
  {"cmd": "set_wire_rc", "args": ["-signal", "-layer", "$SIG_RC"]},
  {"cmd": "set_wire_rc", "args": ["-clock", "-layer", "$CLK_RC"]},
  {"cmd": "set_propagated_clock", "args": []},
  {"cmd": "set_routing_layers", "args": ["-signal", "$MINL-$MAXL", "-clock", "$MINL-$MAXL"]},
  {"cmd": "set_global_routing_layer_adjustment", "args": ["*", "$ADJ"]},
  {"cmd": "global_route", "args": []},
  {"cmd": "estimate_parasitics", "args": ["-global_routing"]},
  {"cmd": "repair_timing", "args": ["-verbose", "-setup", "-setup_margin", "$GRT_SETUP_MARGIN", "-max_buffer_percent", "$GRT_MAX_BUF_PCT"]},
  {"cmd": "repair_timing", "args": ["-verbose", "-hold", "-setup_margin", "$GRT_SETUP_MARGIN", "-hold_margin", "$GRT_HOLD_MARGIN", "-max_buffer_percent", "$GRT_MAX_BUF_PCT"]}],
 "write_db": "$OUT/r1c.rt.odb"}
EOF
  trc=0; runq "$RSZ" repair_design "$OUT/r1c.rt.job.json" -o "$OUT/r1c.rt.json" || trc=$?
  GTRC=$(jget "$OUT/r1c.rt.json" status)
  echo "  rsz: $GTRC $(jget "$OUT/r1c.rt.json" reason)"
  if [ "$trc" -ne 0 ]; then
    # declined (a refusal, or a route or estimate it does not model): the design goes on as
    # the antenna repair left it, and the result says so
    echo "  the timing repair did not run to the end (exit $trc); the design continues unrepaired (leave out --grt-timing-repair to skip the attempt)." >&2
    GTRC="$GTRC (not applied)"
  else
    supply_connect "$OUT/r1c.rt.odb"
    step "1d · dpl — the repaired cells onto legal sites"
    "$DPL" detailed-placement "$OUT/r1c.rt.odb" --out-odb "$OUT/r1d.legal.odb" \
           > "$OUT/r1d.dpl.json" 2> >(sed 's/^/  /' >&2)
    echo "  $(jget "$OUT/r1d.dpl.json" status): $(jget "$OUT/r1d.dpl.json" moved) of $(jget "$OUT/r1d.dpl.json" cells) cells moved ($(jget "$OUT/r1d.dpl.json" legalizer) legalizer)"
    step "1e · dpl check-placement — after the timing repair"
    rc=0; runq "$DPL" check-placement "$OUT/r1d.legal.odb" -o "$OUT/r1e.check.json" || rc=$?
    echo "  $(jget "$OUT/r1e.check.json" status): $(jget "$OUT/r1e.check.json" violations) violations over $(jget "$OUT/r1e.check.json" cells_checked) cells"
    [ "$rc" -eq 0 ] || exit "$rc"
    step "1f · grt — the repaired design routed again"
    cat > "$OUT/r1f.grt.job.json" <<EOF
{"db": "$OUT/r1d.legal.odb",
 "steps": [{"cmd": "set_routing_layers", "signal": ["$MINL", "$MAXL"], "clock": ["$MINL", "$MAXL"]},
           {"cmd": "global_adjustment", "value": $ADJ},
           {"cmd": "global_route", "allow_congestion": $CONGEST},
           {"cmd": "write_guides", "path": "$OUT/r1f.guides"},
           {"cmd": "write_db", "path": "$OUT/r1f.grt.odb"}]}
EOF
    rc=0; runq "$GRT" route "$OUT/r1f.grt.job.json" -o "$OUT/r1f.grt.json" || rc=$?
    echo "  grt: $(jget "$OUT/r1f.grt.json" status) $(jget "$OUT/r1f.grt.json" reason)"
    [ "$rc" -eq 0 ] || exit "$rc"
    DRT_IN=$OUT/r1f.grt.odb
  fi
fi

# 2 ── detailed routing ──────────────────────────────────────────────────────────────────────
step "2 · drt — wires and vias, repaired until no design-rule marker stands"
printf '{"db": "%s"}\n' "$DRT_IN" > "$OUT/r2.drt.args.json"
# Each search-and-repair batch's workers in parallel, written back in batch order: the same routes
# at any thread count.
# Unset, the engine picks a balanced count from the machine (VYGES_THREADS overrides it) and says so.
TFLAG=(); [ -n "$THREADS" ] && TFLAG=(--threads "$THREADS")
rc=0; runq "$DRT" detailed_route --db "$DRT_IN" --out "$OUT/routed.odb" -o "$OUT/r2.drt.json" "${TFLAG[@]+"${TFLAG[@]}"}" || rc=$?
echo "  drt: $(jget "$OUT/r2.drt.json" status) $(jget "$OUT/r2.drt.json" reason)"
# markers (1) is a finding: the design is routed and written, so the rest still runs.
[ "$rc" -le 1 ] || exit "$rc"
DRT_RC=$rc

# 3 ── the routed design as DEF ─────────────────────────────────────────────────────────────
step "3 · write the routed design"
runq "$ODB" write-def --input "$OUT/routed.odb" --output "$OUT/routed.def"
dont_use_resolve
dont_use_check "$OUT/routed.def"

# 4 ── antenna ───────────────────────────────────────────────────────────────────────────────
step "4 · ant — antenna ratios on the routed metal"
ANT_RC=0; "$ANT" check "$OUT/routed.odb" -o "$OUT/r4.ant.json" 2>/dev/null || ANT_RC=$?
echo "  ant: $(jget "$OUT/r4.ant.json" status)"
[ "$ANT_RC" -le 1 ] || exit "$ANT_RC"

# 4b ── disconnected pins ─────────────────────────────────────────────────────────────────────
# As an open flow checks the routed design before filling it: per instance, a supply pin, every
# output or an input left on no net is critical, and a critical pin stops the flow.
step "4b · opendb report-disconnected-pins — supply, output and input pins on no net"
[ ${#DISC_IGNORE[@]} -gt 0 ] || case $PDK in sky130*) DISC_IGNORE=(sky130_fd_sc_hd__conb_1) ;; esac
IGN=(); for m in "${DISC_IGNORE[@]+"${DISC_IGNORE[@]}"}"; do IGN+=(--ignore-module "$m"); done
DISC_RC=0; "$ODB" report-disconnected-pins --input "$OUT/routed.odb" "${IGN[@]+"${IGN[@]}"}" \
  > "$OUT/r4b.disconnected.json" 2> "$OUT/r4b.disconnected.log" || DISC_RC=$?
DISC_CRIT=$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["critical_disconnected_pin_count"])' "$OUT/r4b.disconnected.json" 2>/dev/null || echo "?")
echo "  $(jget "$OUT/r4b.disconnected.json" disconnected_pin_count) disconnected, $DISC_CRIT critical"
if [ "$DISC_RC" -ne 0 ]; then
  sed -n '1,20s/^/  /p' "$OUT/r4b.disconnected.log" >&2
  [ "$DISC_RC" -eq 1 ] && [ "$DISC_ERROR" = false ] || exit "$DISC_RC"
fi

# 4c ── wire length ───────────────────────────────────────────────────────────────────────────
# Every routed net's length, longest first (r4c.wire-length.csv), and the longest against
# --wire-length-threshold. As an open flow's checker, a long wire does not stop the flow: the run
# goes on to fill and fails at the end.
step "4c · opendb report-wire-length — the longest routed wire$([ -n "$WL_THRESHOLD" ] && echo " against $WL_THRESHOLD µm")"
WL_ARGS=(); [ -z "$WL_THRESHOLD" ] || WL_ARGS=(--threshold "$WL_THRESHOLD")
WL_RC=0; "$ODB" report-wire-length --input "$OUT/routed.odb" --report-out "$OUT/r4c.wire-length.csv" \
  "${WL_ARGS[@]+"${WL_ARGS[@]}"}" > "$OUT/r4c.wire-length.json" 2> "$OUT/r4c.wire-length.log" || WL_RC=$?
WL_CHECK=$(jget "$OUT/r4c.wire-length.json" check 2>/dev/null || echo "?")
# a report that did not run (an engine too old for these flags, a database it cannot read) is
# not a long wire: anything but pass / fail / skipped stops the flow
case "$WL_CHECK" in pass|fail|skipped) ;; *)
  sed 's/^/  /' "$OUT/r4c.wire-length.log" >&2; echo "  wire-length report failed (exit $WL_RC)" >&2
  exit $(( WL_RC > 1 ? WL_RC : 2 )) ;;
esac
echo "  longest $(jget "$OUT/r4c.wire-length.json" max_length_um) µm over $(jget "$OUT/r4c.wire-length.json" nets_with_wire) nets: $WL_CHECK"
[ "$WL_RC" -eq 0 ] || [ "$WL_ERROR" = true ] || { WL_RC=0; WL_CHECK="$WL_CHECK (warning only)"; }

# 5 ── fill ──────────────────────────────────────────────────────────────────────────────────
if [ "$FILL" = true ]; then
  step "5 · dpl filler-placement — every empty site, decaps then fillers"
  printf '{"cells": "%s"}\n' "$FILL_CELLS" > "$OUT/r5.fill.args.json"
  # shellcheck disable=SC2086  # each pattern its own argument, globs left to the engine
  set -f; frc=0; "$DPL" filler-placement "$OUT/routed.odb" $FILL_CELLS --out-odb "$OUT/filled.odb" \
    > "$OUT/r5.fill.json" 2> >(sed 's/^/  /' >&2) || frc=$?; set +f
  [ "$frc" -eq 0 ] || exit "$frc"
  supply_connect "$OUT/filled.odb"
  runq "$ODB" write-def --input "$OUT/filled.odb" --output "$OUT/filled.def"
fi

step "result — $OUT/routed.odb (and routed.def$([ "$FILL" = true ] && echo "; filled.odb, filled.def"))"
printf '  %-10s %s\n' \
  routing "$(jget "$OUT/r2.drt.json" status)" \
  "design repair" "$GRDRC" \
  "timing repair" "$GTRC" \
  antenna "$(jget "$OUT/r4.ant.json" status)" \
  "disconnected pins" "$DISC_CRIT critical" \
  "wire length" "$WL_CHECK" \
  dont_use "$([ "$DONT_USE_FOUND" -eq 0 ] && echo clean || echo "$DONT_USE_FOUND excluded")"
[ "$DRT_RC" -eq 0 ] && [ "$ANT_RC" -eq 0 ] && [ "$DISC_RC" -eq 0 ] && [ "$WL_RC" -eq 0 ] && [ "$DONT_USE_FOUND" -eq 0 ] || exit 1
