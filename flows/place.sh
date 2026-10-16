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
#     io pins  ->  gpl  ->  rsz repair_design  ->  dpl legalize  ->  dpl check  ->  cts
#             ->  dpl legalize (the clock buffers)  ->  dpl check
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
#   --skip-repair         do not run rsz repair_design
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
MACRO_LEFS=() MACRO_LIBS=()
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
    --skip-repair)  SKIP_REPAIR=1; shift ;;
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
ODB=$(eng opendb); PPL=$(eng ppl); GPL=$(eng gpl); RSZ=$(eng rsz); DPL=$(eng dpl); CTS=$(eng cts)
pdk_resolve
dont_use_resolve
mkdir -p "$OUT"
DESIGN=$(awk '/^DESIGN /{print $2; exit}' "$DEF")
step "$DESIGN — placement, from $DEF"
echo "pdk:     $PDK · $LIB · $CORNER"
echo "engines: $(dirname "$GPL")"

# The constraints. Generated from the clock unless given: the same shape an open flow writes by
# default, and only commands every stage here reads.
if [ -z "$SDC" ]; then
  SDC=$OUT/p0.design.sdc
  IOD=$("$PY" -c 'import sys; print(float(sys.argv[1]) * float(sys.argv[2]) / 100)' "$CLOCK_PERIOD" "$IO_DELAY")
  cat > "$SDC" <<EOF
create_clock -name $CLOCK_PORT -period $CLOCK_PERIOD [get_ports {$CLOCK_PORT}]
set_input_delay $IOD -clock $CLOCK_PORT [all_inputs]
set_output_delay $IOD -clock $CLOCK_PORT [all_outputs]
set_max_fanout 10 [current_design]
EOF
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
  "clock tree" "$([ "$rc" -eq 0 ] && jget "$OUT/p6.cts.json" status || echo 'ideal (not built)')"
