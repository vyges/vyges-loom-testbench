#!/usr/bin/env bash
#
# SPDX-License-Identifier: Apache-2.0
# © 2026 https://vyges.com. All Rights Reserved.
#
# This script is licensed under the Apache License, Version 2.0; see LICENSE and NOTICE.
# http://www.apache.org/licenses/LICENSE-2.0
#
# Place a floorplanned design with the Vyges Loom engines.
#
#     io pins  ->  gpl  ->  timing  ->  rsz repair_design  ->  dpl legalize  ->  dpl check  ->  cts
#             ->  rsz repair_clock_nets  ->  dpl legalize (the clock buffers)  ->  dpl check  ->  timing
#             ->  rsz repair_timing (setup, then hold)  ->  dpl legalize  ->  dpl check  ->  timing
#
# The timing steps (./timing.sh) report where the design stands, wires estimated from the
# placement: after global placement, after the clock tree and after the timing repair, every
# clock propagated once the tree is built. The timing repair runs as an open flow runs it after
# the clock tree: setup paths first, then hold, each with a slack margin and a cap on the buffers
# it may add, and the cells it moved or added legalized after. Every step that adds cells ends by
# connecting their supply pins to the supply nets, as an open flow ends each of its steps.
#
# The input is a floorplan: the DEF ./floorplan.sh writes, or any DEF with rows, tracks and a
# power grid. The output is a legal placement, as a database and a DEF, ready for ./route.sh.
#
#   ./flows/place.sh --def build/6.floorplan.def --clock-port clk_i --clock-period 50
#
# OPTIONS
#   --def FILE            the floorplanned design (required)
#   --clock-port NAME     the clock input                       (required unless --sdc is given)
#   --clock-period NS     its period, nanoseconds               (required unless --sdc is given)
#   --io-delay PCT        input/output delay, percent of the period, for the generated SDC (default 20)
#   --sdc FILE            use these constraints instead of generating them
#   --density D           global placement target density, 0..1  (default: the placer's, 0.7)
#   --io-hlayer L         layer for pins on the left/right edges   (default met3)
#   --io-vlayer L         layer for pins on the top/bottom edges   (default met2)
#   --signal-rc-layer L   layer whose RC estimates signal wires    (default met2)
#   --clock-rc-layer L    layer whose RC estimates clock wires     (default met5)
#   --slew-margin PCT / --cap-margin PCT   repair margins          (default 20 / 20)
#   --clock-buffers 'A B' clock buffer masters for cts            (default sky130 clkbuf_4 and _8)
#   --root-buffer M       cts root buffer                         (default sky130 clkbuf_16)
#   --macro-lef FILE      a hard macro's LEF (repeatable), to read the floorplan DEF
#   --macro-lib FILE      a hard macro's Liberty (repeatable), for every timing step
#   --dont-use FILE       cells no engine may insert (rsz, cts): names or globs, whitespace-separated, '#' comments
#                         (default: the PDK store's `dont_use` for the library, if it has one)
#   --power NET / --ground NET      supply net names, for the cells this script adds (default VPWR / VGND)
#   --pin-power RE / --pin-ground RE   repeatable cell-pin patterns, as ./floorplan.sh's
#                         (default ^VPWR$ and ^VPB$ / ^VGND$ and ^VNB$)
#   --skip-repair         do not run rsz repair_design
#   --setup-margin NS / --hold-margin NS    timing repair's slack margins (default 0.05 / 0.1)
#   --max-buffer-percent P  timing repair's cap on added buffers, percent of the instances (default 50)
#   --skip-timing-repair  do not run rsz repair_timing after the clock tree
#   --ideal-clock         carry on when cts does not build a clock tree (the clock stays ideal)
#   --pdk / --library / --corner / --pdk-root    as in ./floorplan.sh (corner default tt_025C_1v80)
#   --out DIR             where to write (default ./build)
#   --bin DIR             engine binaries, instead of PATH
#
# EXIT STATUS: 0 placed · 1 a stage reported a finding (placement violations) · 2 error ·
# 3 a stage declined the design (its reason is printed; see --skip-repair / --ideal-clock).
#
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

DEF= CLOCK_PORT= CLOCK_PERIOD= IO_DELAY=20 SDC=
IO_H=met3 IO_V=met2 SIG_RC=met2 CLK_RC=met5 SLEW=20 CAP=20
CLKBUFS='sky130_fd_sc_hd__clkbuf_4 sky130_fd_sc_hd__clkbuf_8' ROOTBUF=sky130_fd_sc_hd__clkbuf_16
SKIP_REPAIR=0 IDEAL_CLOCK=0 DENSITY= CLK_MAX_WL=0 DONT_USE_FILE=
SETUP_MARGIN=0.05 HOLD_MARGIN=0.1 MAX_BUF_PCT=50 SKIP_TIMING_REPAIR=0
MACRO_LEFS=() MACRO_LIBS=() POWER=VPWR GROUND=VGND PIN_POWER=() PIN_GROUND=()
PDK=${VYGES_PDK:-sky130a} LIB=sky130_fd_sc_hd CORNER=tt_025C_1v80 OUT=build BIN=${VYGES_BIN:-}

while [ $# -gt 0 ]; do
  case $1 in
    --def)          DEF=$2; shift 2 ;;
    --clock-port)   CLOCK_PORT=$2; shift 2 ;;
    --clock-period) CLOCK_PERIOD=$2; shift 2 ;;
    --io-delay)     IO_DELAY=$2; shift 2 ;;
    --sdc)          SDC=$2; shift 2 ;;
    --density)      DENSITY=$2; shift 2 ;;
    --io-hlayer)    IO_H=$2; shift 2 ;;
    --io-vlayer)    IO_V=$2; shift 2 ;;
    --signal-rc-layer) SIG_RC=$2; shift 2 ;;
    --clock-rc-layer)  CLK_RC=$2; shift 2 ;;
    --slew-margin)  SLEW=$2; shift 2 ;;
    --cap-margin)   CAP=$2; shift 2 ;;
    --clock-buffers) CLKBUFS=$2; shift 2 ;;
    --root-buffer)  ROOTBUF=$2; shift 2 ;;
    --clock-max-wire-length) CLK_MAX_WL=$2; shift 2 ;;
    --dont-use)     DONT_USE_FILE=$2; shift 2 ;;
    --macro-lef)    MACRO_LEFS+=("$2"); shift 2 ;;
    --macro-lib)    MACRO_LIBS+=("$2"); shift 2 ;;
    --power)        POWER=$2; shift 2 ;;
    --ground)       GROUND=$2; shift 2 ;;
    --pin-power)    PIN_POWER+=("$2"); shift 2 ;;
    --pin-ground)   PIN_GROUND+=("$2"); shift 2 ;;
    --skip-repair)  SKIP_REPAIR=1; shift ;;
    --setup-margin) SETUP_MARGIN=$2; shift 2 ;;
    --hold-margin)  HOLD_MARGIN=$2; shift 2 ;;
    --max-buffer-percent) MAX_BUF_PCT=$2; shift 2 ;;
    --skip-timing-repair) SKIP_TIMING_REPAIR=1; shift ;;
    --ideal-clock)  IDEAL_CLOCK=1; shift ;;
    --pdk)          PDK=$2; shift 2 ;;
    --library)      LIB=$2; shift 2 ;;
    --corner)       CORNER=$2; shift 2 ;;
    --pdk-root)     export PDK_ROOT=$2; shift 2 ;;
    --out)          OUT=$2; shift 2 ;;
    --bin)          BIN=$2; shift 2 ;;
    -h|--help)      . "$HERE/_common.sh"; usage "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
. "$HERE/_common.sh"

[ -n "$DEF" ] && [ -f "$DEF" ] || { echo "error: --def <floorplan.def> is required and must exist." >&2; exit 2; }
if [ -z "$SDC" ] && { [ -z "$CLOCK_PORT" ] || [ -z "$CLOCK_PERIOD" ]; }; then
  echo "error: give --clock-port and --clock-period, or --sdc FILE." >&2; exit 2
fi
ODB=$(eng opendb); PPL=$(eng ppl); GPL=$(eng gpl); RSZ=$(eng rsz); DPL=$(eng dpl); CTS=$(eng cts); PDN=$(eng pdn)
supply_rules
pdk_resolve
dont_use_resolve
mkdir -p "$OUT"
OUT=$(abspath "$OUT"); [ -n "$SDC" ] && SDC=$(abspath "$SDC")
DESIGN=$(awk '/^DESIGN /{print $2; exit}' "$DEF")
step "$DESIGN — placement, from $DEF"
echo "pdk:     $PDK · $LIB · $CORNER"
echo "engines: $(dirname "$GPL")"

# The constraints. Generated from the clock unless given: the same shape an open flow writes by
# default, and only commands every stage here reads.
if [ -z "$SDC" ]; then
  SDC=$OUT/p0.design.sdc
  sdc_write "$SDC" "$CLOCK_PORT" "$CLOCK_PERIOD" "$IO_DELAY"
fi

# 1 ── the IO pins ────────────────────────────────────────────────────────────────────────────
# ppl chooses where each pin goes and writes each port's pin into the database: one rectangle on
# its layer, sized from the layer's minimum width and area as the reference sizes it, PLACED.
step "1 · ppl — IO pins on the die boundary"
def_to_odb "$DEF" "$OUT/p1.floorplan.odb"
printf '{"hor_layers": "%s", "ver_layers": "%s"}\n' "$IO_H" "$IO_V" > "$OUT/p1.ppl.args.json"
runq "$PPL" place-pins "$OUT/p1.floorplan.odb" --hor-layers "$IO_H" --ver-layers "$IO_V" \
     --out-odb "$OUT/p1.io.odb" -o "$OUT/p1.ppl.json"
echo "  $(jget "$OUT/p1.ppl.json" pins_placed) of $(jget "$OUT/p1.ppl.json" pins_total) pins placed by ppl"

# 2 ── global placement ──────────────────────────────────────────────────────────────────────
GPL_ARGS=
[ -n "$DENSITY" ] && GPL_ARGS="\"-density\", \"$DENSITY\""
step "2 · gpl — global placement"
cat > "$OUT/p2.gpl.job.json" <<EOF
{"steps": [{"cmd": "read_db", "args": ["$OUT/p1.io.odb"]},
           {"cmd": "global_placement", "args": [$GPL_ARGS]}],
 "write_def": "$OUT/p2.gpl.def"}
EOF
runq "$GPL" global_placement "$OUT/p2.gpl.job.json" -o "$OUT/p2.gpl.json" || {
  rc=$?; echo "  gpl: $(jget "$OUT/p2.gpl.json" status) — $(jget "$OUT/p2.gpl.json" reason)"; exit "$rc"; }
echo "  $(jget "$OUT/p2.gpl.json" status): $(jget "$OUT/p2.gpl.json" insts) instances"
PLACED=$OUT/p2.gpl.def

# The arguments every timing step here shares.
timing() {
  local m=() f
  for f in "${MACRO_LEFS[@]+"${MACRO_LEFS[@]}"}"; do m+=(--macro-lef "$f"); done
  for f in "${MACRO_LIBS[@]+"${MACRO_LIBS[@]}"}"; do m+=(--macro-lib "$f"); done
  "$HERE/timing.sh" --sdc "$SDC" --signal-rc-layer "$SIG_RC" --clock-rc-layer "$CLK_RC" \
    --pdk "$PDK" --library "$LIB" --corner "$CORNER" --out "$OUT" ${BIN:+--bin "$BIN"} "${m[@]+"${m[@]}"}" "$@"
}

step "2b · timing — after global placement, wires estimated from it"
def_to_odb "$PLACED" "$OUT/p2.gpl.odb"
timing --odb "$OUT/p2.gpl.odb" --label m1.gpl 2>&1 | sed 's/^/  /'
[ "${PIPESTATUS[0]}" -eq 0 ] || exit 2

# 3 ── electrical repair ─────────────────────────────────────────────────────────────────────
if [ "$SKIP_REPAIR" = 1 ]; then
  step "3 · rsz — skipped (--skip-repair)"
else
  step "3 · rsz repair_design — slew, capacitance, fanout and wire length"
  cat > "$OUT/p3.rsz.job.json" <<EOF
{"steps": [
  {"cmd": "read_lef", "args": ["$TLEF"]}, {"cmd": "read_lef", "args": ["$CLEF"]}, $(macro_lef_steps)
  {"cmd": "read_def", "args": ["$PLACED"]},
  {"cmd": "read_liberty", "args": ["$LIBERTY"]}, $(macro_lib_steps)$(dont_use_step) {"cmd": "read_sdc", "args": ["$SDC"]},
  {"cmd": "set_wire_rc", "args": ["-signal", "-layer", "$SIG_RC"]},
  {"cmd": "set_wire_rc", "args": ["-clock", "-layer", "$CLK_RC"]},
  {"cmd": "estimate_parasitics", "args": ["-placement"]},
  {"cmd": "repair_design", "args": ["-slew_margin", "$SLEW", "-cap_margin", "$CAP"]}],
 "write_def": "$OUT/p3.rsz.def"}
EOF
  rc=0; runq "$RSZ" repair_design "$OUT/p3.rsz.job.json" -o "$OUT/p3.rsz.json" || rc=$?
  echo "  rsz: $(jget "$OUT/p3.rsz.json" status) $(jget "$OUT/p3.rsz.json" reason)"
  if [ "$rc" -ne 0 ]; then
    [ "$rc" -eq 3 ] && echo "  rerun with --skip-repair to place the design without electrical repair." >&2
    exit "$rc"
  fi
  PLACED=$OUT/p3.rsz.def
fi

# 4 ── legalization ──────────────────────────────────────────────────────────────────────────
step "4 · dpl — every cell onto a legal site"
def_to_odb "$PLACED" "$OUT/p4.global.odb"
[ "$SKIP_REPAIR" = 1 ] || supply_connect "$OUT/p4.global.odb"
"$DPL" detailed-placement "$OUT/p4.global.odb" --out-odb "$OUT/p4.legal.odb" \
       > "$OUT/p4.dpl.json" 2> >(sed 's/^/  /' >&2)
echo "  $(jget "$OUT/p4.dpl.json" status): $(jget "$OUT/p4.dpl.json" moved) of $(jget "$OUT/p4.dpl.json" cells) cells moved ($(jget "$OUT/p4.dpl.json" legalizer) legalizer)"

step "5 · dpl check-placement — every rule family"
rc=0; runq "$DPL" check-placement "$OUT/p4.legal.odb" -o "$OUT/p5.check.json" || rc=$?
echo "  $(jget "$OUT/p5.check.json" status): $(jget "$OUT/p5.check.json" violations) violations over $(jget "$OUT/p5.check.json" cells_checked) cells"
[ "$rc" -eq 0 ] || exit "$rc"

# 6 ── the clock tree ────────────────────────────────────────────────────────────────────────
step "6 · cts — clock tree synthesis"
cat > "$OUT/p6.cts.job.json" <<EOF
{"steps": [{"cmd": "read_db", "args": ["$OUT/p4.legal.odb"]},
           {"cmd": "read_liberty", "args": ["$LIBERTY"]}, $(macro_lib_steps)$(dont_use_step) {"cmd": "read_sdc", "args": ["$SDC"]},
           {"cmd": "set_wire_rc", "args": ["-clock", "-layer", "$CLK_RC"]},
           {"cmd": "clock_tree_synthesis", "args": ["-root_buf", "$ROOTBUF", "-buf_list", "$CLKBUFS"]}],
 "write_db": "$OUT/p6.cts.odb"}
EOF
rc=0; "$CTS" clock_tree_synthesis "$OUT/p6.cts.job.json" -o "$OUT/p6.cts.json" 2>/dev/null || rc=$?
echo "  cts: $(jget "$OUT/p6.cts.json" status) — $(jget "$OUT/p6.cts.json" clock_nets) clock nets found"
[ "$rc" -ne 0 ] || supply_connect "$OUT/p6.cts.odb"
if [ "$rc" -ne 0 ]; then
  echo "  $(jget "$OUT/p6.cts.json" reason)"
  if [ "$rc" -eq 3 ] && [ "$IDEAL_CLOCK" = 1 ]; then
    echo "  --ideal-clock: continuing with the clock ideal; the placement below has no new clock tree."
  else
    [ "$rc" -eq 3 ] && echo "  rerun with --ideal-clock to continue with the clock ideal." >&2
    exit "$rc"
  fi
fi

# 6b ── long wires on the clock nets ─────────────────────────────────────────────────────────
# As the open flow's CTS step does after the tree: every clock propagated, placement parasitics,
# then repair_clock_nets (CTS leaves a long wire from the clock port to the tree's root).
CLOCKED=$OUT/p6.cts.odb
if [ "$rc" -eq 0 ]; then
  step "6b · rsz repair_clock_nets — long wires in the clock networks"
  cat > "$OUT/p6b.rcn.job.json" <<EOF
{"steps": [
  {"cmd": "read_liberty", "args": ["$LIBERTY"]}, $(macro_lib_steps)$(dont_use_step)
  {"cmd": "read_db", "args": ["$OUT/p6.cts.odb"]}, {"cmd": "read_sdc", "args": ["$SDC"]},
  {"cmd": "set_wire_rc", "args": ["-signal", "-layer", "$SIG_RC"]},
  {"cmd": "set_wire_rc", "args": ["-clock", "-layer", "$CLK_RC"]},
  {"cmd": "set_propagated_clock", "args": []},
  {"cmd": "estimate_parasitics", "args": ["-placement"]},
  {"cmd": "clock_buffers", "args": [$(printf '"%s",' $CLKBUFS | sed 's/,$//')]},
  {"cmd": "repair_clock_nets", "args": ["-max_wire_length", "$CLK_MAX_WL"]}],
 "write_db": "$OUT/p6b.rcn.odb"}
EOF
  rrc=0; runq "$RSZ" repair_design "$OUT/p6b.rcn.job.json" -o "$OUT/p6b.rcn.json" || rrc=$?
  echo "  rsz: $(jget "$OUT/p6b.rcn.json" status) — $(jget "$OUT/p6b.rcn.json" inserted_buffers) buffers, $(jget "$OUT/p6b.rcn.json" nets_checked) clock drivers $(jget "$OUT/p6b.rcn.json" reason)"
  [ "$rrc" -eq 0 ] || exit "$rrc"
  supply_connect "$OUT/p6b.rcn.odb"
  CLOCKED=$OUT/p6b.rcn.odb
fi

# 7 ── the clock buffers onto legal sites ──────────────────────────────────────────────────────
FINAL=$OUT/p4.legal.odb
if [ "$rc" -eq 0 ]; then
  step "7 · dpl — the clock tree's buffers onto legal sites"
  "$DPL" detailed-placement "$CLOCKED" --out-odb "$OUT/p7.legal.odb" \
         > "$OUT/p7.dpl.json" 2> >(sed 's/^/  /' >&2)
  echo "  $(jget "$OUT/p7.dpl.json" status): $(jget "$OUT/p7.dpl.json" moved) of $(jget "$OUT/p7.dpl.json" cells) cells moved ($(jget "$OUT/p7.dpl.json" legalizer) legalizer)"
  step "8 · dpl check-placement — every rule family, with the clock tree"
  crc=0; runq "$DPL" check-placement "$OUT/p7.legal.odb" -o "$OUT/p8.check.json" || crc=$?
  echo "  $(jget "$OUT/p8.check.json" status): $(jget "$OUT/p8.check.json" violations) violations over $(jget "$OUT/p8.check.json" cells_checked) cells"
  [ "$crc" -eq 0 ] || exit "$crc"
  FINAL=$OUT/p7.legal.odb

  step "9 · timing — the clock tree built, every clock propagated"
  timing --odb "$FINAL" --propagated --label m2.cts 2>&1 | sed 's/^/  /'
  [ "${PIPESTATUS[0]}" -eq 0 ] || exit 2
fi

# 10 ── timing repair, the clock tree built ─────────────────────────────────────────────────
TRC=skipped trc=1
if [ "$rc" -eq 0 ] && [ "$SKIP_TIMING_REPAIR" = 0 ]; then
  step "10 · rsz repair_timing — setup, then hold, the clock tree propagated"
  cat > "$OUT/p9.rt.job.json" <<EOF
{"steps": [
  {"cmd": "read_liberty", "args": ["$LIBERTY"]}, $(macro_lib_steps)$(dont_use_step)
  {"cmd": "read_db", "args": ["$FINAL"]}, {"cmd": "read_sdc", "args": ["$SDC"]},
  {"cmd": "set_wire_rc", "args": ["-signal", "-layer", "$SIG_RC"]},
  {"cmd": "set_wire_rc", "args": ["-clock", "-layer", "$CLK_RC"]},
  {"cmd": "set_propagated_clock", "args": []},
  {"cmd": "estimate_parasitics", "args": ["-placement"]},
  {"cmd": "repair_timing", "args": ["-verbose", "-setup", "-setup_margin", "$SETUP_MARGIN", "-max_buffer_percent", "$MAX_BUF_PCT"]},
  {"cmd": "repair_timing", "args": ["-verbose", "-hold", "-setup_margin", "$SETUP_MARGIN", "-hold_margin", "$HOLD_MARGIN", "-max_buffer_percent", "$MAX_BUF_PCT"]}],
 "write_db": "$OUT/p9.rt.odb"}
EOF
  trc=0; runq "$RSZ" repair_design "$OUT/p9.rt.job.json" -o "$OUT/p9.rt.json" || trc=$?
  TRC=$(jget "$OUT/p9.rt.json" status)
  echo "  rsz: $TRC $(jget "$OUT/p9.rt.json" reason)"
  # A refusal names something the engine does not model: the design goes on as the clock tree
  # left it, and the result says so. Anything else stops the flow.
  if [ "$trc" -eq 3 ]; then
    echo "  the timing repair declined this design; it continues unrepaired (--skip-timing-repair skips the attempt)." >&2
  elif [ "$trc" -ne 0 ]; then
    exit "$trc"
  fi
fi
if [ "$rc" -eq 0 ] && [ "$SKIP_TIMING_REPAIR" = 0 ] && [ "$trc" -eq 0 ]; then
  supply_connect "$OUT/p9.rt.odb"
  step "11 · dpl — the repaired cells onto legal sites"
  "$DPL" detailed-placement "$OUT/p9.rt.odb" --out-odb "$OUT/p10.legal.odb" \
         > "$OUT/p10.dpl.json" 2> >(sed 's/^/  /' >&2)
  echo "  $(jget "$OUT/p10.dpl.json" status): $(jget "$OUT/p10.dpl.json" moved) of $(jget "$OUT/p10.dpl.json" cells) cells moved ($(jget "$OUT/p10.dpl.json" legalizer) legalizer)"
  step "12 · dpl check-placement — every rule family, after the timing repair"
  crc=0; runq "$DPL" check-placement "$OUT/p10.legal.odb" -o "$OUT/p11.check.json" || crc=$?
  echo "  $(jget "$OUT/p11.check.json" status): $(jget "$OUT/p11.check.json" violations) violations over $(jget "$OUT/p11.check.json" cells_checked) cells"
  [ "$crc" -eq 0 ] || exit "$crc"
  FINAL=$OUT/p10.legal.odb
  step "13 · timing — after the timing repair"
  timing --odb "$FINAL" --propagated --label m3.rt 2>&1 | sed 's/^/  /'
  [ "${PIPESTATUS[0]}" -eq 0 ] || exit 2
fi

# ── what came out ───────────────────────────────────────────────────────────────────────────
cp "$FINAL" "$OUT/placed.odb"
runq "$ODB" write-def --input "$OUT/placed.odb" --output "$OUT/placed.def"
dont_use_check "$OUT/placed.def"
step "result — $OUT/placed.odb (and placed.def)"
printf '  %-14s %s\n' \
  instances  "$(jget "$OUT/p2.gpl.json" insts)" \
  "io pins"  "$(jget "$OUT/p1.ppl.json" pins_placed)" \
  repair     "$([ "$SKIP_REPAIR" = 1 ] && echo skipped || jget "$OUT/p3.rsz.json" status)" \
  legal      "$(jget "$OUT/p5.check.json" status)" \
  "clock tree" "$([ "$rc" -eq 0 ] && jget "$OUT/p6.cts.json" status || echo 'ideal (not built)')" \
  "timing repair" "$TRC"
