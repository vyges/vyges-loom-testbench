#!/usr/bin/env bash
#
# SPDX-License-Identifier: Apache-2.0
# © 2026 https://vyges.com. All Rights Reserved.
#
# This script is licensed under the Apache License, Version 2.0; see LICENSE and NOTICE.
# http://www.apache.org/licenses/LICENSE-2.0
#
# Time a design with the Vyges Loom static timing engine, as an open flow times it between its
# steps: each path group's worst setup and hold path, then the worst and total negative slack.
#
#   before placement — the synthesized netlist, the libraries and the constraints, no wires:
#     ./flows/timing.sh --netlist build/my_block.v --clock-port clk_i --clock-period 50
#   during placement — a placed database: its netlist written out, every net's wire estimated
#   from the placement (as SPEF), then timed; --propagated once a clock tree is built:
#     ./flows/timing.sh --odb build/p2.gpl.odb --sdc build/p0.design.sdc --label m1.gpl
#
# A violation is REPORTED, not failed on: timing mid-flow says where the design stands, and
# repair is still to come. ./implement.sh runs it first; ./place.sh after global placement and
# after the clock tree.
#
# OPTIONS
#   --netlist FILE        structural gate-level Verilog (one of --netlist / --odb is required)
#   --odb FILE            a placed database (opendb): timed with its wires estimated
#   --top NAME            the top module of --netlist (default: the one module no other instantiates)
#   --signal-rc-layer L   with --odb: layer whose RC estimates signal wires (default met2)
#   --clock-rc-layer L    with --odb: layer whose RC estimates clock wires  (default met5)
#   --propagated          every clock propagated through its network (after a clock tree)
#   --clock-port NAME     the clock input                       (required unless --sdc is given)
#   --clock-period NS     its period, nanoseconds               (required unless --sdc is given)
#   --io-delay PCT        input/output delay, percent of the period, for the generated SDC (default 20)
#   --sdc FILE            use these constraints instead of generating them
#   --macro-lef FILE      a hard macro's LEF (repeatable), recorded for whoever replays the run
#   --macro-lib FILE      a hard macro's Liberty (repeatable)
#   --digits N            decimals in the report (default 4)
#   --label NAME          prefix of the files written (default t0.pre)
#   --pdk / --library / --corner / --pdk-root    as in ./place.sh
#   --out DIR             where to write (default ./build)
#   --bin DIR             engine binaries, instead of PATH
#
# OUTPUT  <label>.tcl  the script the timer ran (libraries, netlist, constraints, reports)
#         <label>.rpt  its report
#         <label>.args.json  the LEFs and top module, so another tool can replay the same script
#         with --odb also <label>.v (the netlist) and <label>.spef (the estimated wires)
#
# EXIT STATUS: 0 timed (whatever the slack) · 2 error
#
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

NETLIST= IN_ODB= SIG_RC=met2 CLK_RC=met5 PROPAGATED=0 TOP= CLOCK_PORT= CLOCK_PERIOD= IO_DELAY=20 SDC= DIGITS=4 LABEL=t0.pre
MACRO_LEFS=() MACRO_LIBS=()
PDK=${VYGES_PDK:-sky130a} LIB=sky130_fd_sc_hd CORNER=tt_025C_1v80 OUT=build BIN=${VYGES_BIN:-}

while [ $# -gt 0 ]; do
  case $1 in
    --netlist)      NETLIST=$2; shift 2 ;;
    --odb)          IN_ODB=$2; shift 2 ;;
    --signal-rc-layer) SIG_RC=$2; shift 2 ;;
    --clock-rc-layer)  CLK_RC=$2; shift 2 ;;
    --propagated)   PROPAGATED=1; shift ;;
    --top)          TOP=$2; shift 2 ;;
    --clock-port)   CLOCK_PORT=$2; shift 2 ;;
    --clock-period) CLOCK_PERIOD=$2; shift 2 ;;
    --io-delay)     IO_DELAY=$2; shift 2 ;;
    --sdc)          SDC=$2; shift 2 ;;
    --macro-lef)    MACRO_LEFS+=("$2"); shift 2 ;;
    --macro-lib)    MACRO_LIBS+=("$2"); shift 2 ;;
    --digits)       DIGITS=$2; shift 2 ;;
    --label)        LABEL=$2; shift 2 ;;
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

if [ -n "$IN_ODB" ]; then
  [ -f "$IN_ODB" ] || { echo "error: no such database: $IN_ODB" >&2; exit 2; }
else
  [ -n "$NETLIST" ] && [ -f "$NETLIST" ] || { echo "error: --netlist <gate-level.v> or --odb <placed.odb> is required." >&2; exit 2; }
fi
if [ -z "$SDC" ] && { [ -z "$CLOCK_PORT" ] || [ -z "$CLOCK_PERIOD" ]; }; then
  echo "error: give --clock-port and --clock-period, or --sdc FILE." >&2; exit 2
fi
STA=$(eng sta-si)
pdk_resolve
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
if [ -n "$IN_ODB" ]; then
  # the placed database's netlist, as the timer reads a netlist
  IN_ODB=$(cd "$(dirname "$IN_ODB")" && pwd)/$(basename "$IN_ODB")
  NETLIST=$OUT/$LABEL.v
  runq "$(eng opendb)" write-verilog --input "$IN_ODB" --output "$NETLIST"
fi
NETLIST=$(cd "$(dirname "$NETLIST")" && pwd)/$(basename "$NETLIST")

# The top module: named, or the one no other module instantiates.
if [ -z "$TOP" ]; then
  TOP=$("$PY" - "$NETLIST" <<'PY'
import re, sys
text = open(sys.argv[1], errors="replace").read()
mods = re.findall(r"^\s*module\s+(\S+?)\s*[(;#]", text, re.M)
used = set(re.findall(r"^\s*(\S+)\s+\S+\s*\(", text, re.M))
tops = [m for m in mods if m not in used]
print(tops[0] if len(tops) == 1 else "")
PY
)
  [ -n "$TOP" ] || { echo "error: cannot tell the top module of $NETLIST; give --top." >&2; exit 2; }
fi

if [ -z "$SDC" ]; then
  SDC=$OUT/$LABEL.sdc
  sdc_write "$SDC" "$CLOCK_PORT" "$CLOCK_PERIOD" "$IO_DELAY"
fi
if [ -n "$IN_ODB" ]; then
  step "$TOP — timing of $(basename "$IN_ODB"), wires estimated from the placement"
else
  step "$TOP — timing before placement (no wires)"
fi
echo "pdk:     $PDK · $LIB · $CORNER"
echo "engines: $(dirname "$STA")"

# Every net's wire, estimated from the placement as the reference estimates it, written as SPEF.
# The clock sources (from the constraints) take the clock layer's RC.
SPEF=
if [ -n "$IN_ODB" ]; then
  SPEF=$OUT/$LABEL.spef
  CLKS=$("$PY" - "$SDC" <<'PY'
import json, re, sys
srcs = []
for m in re.finditer(r"create_clock\b[^\n]*\[get_ports\s+\{?([^\]\}]+)\}?\]", open(sys.argv[1]).read()):
    srcs += m.group(1).split()
print(", ".join(json.dumps(s) for s in srcs))
PY
)
  {
    printf '{"steps": [{"cmd": "read_db", "args": ["%s"]}, {"cmd": "read_liberty", "args": ["%s"]},' "$IN_ODB" "$LIBERTY"
    for f in "${MACRO_LIBS[@]+"${MACRO_LIBS[@]}"}"; do printf ' {"cmd": "read_liberty", "args": ["%s"]},' "$f"; done
    [ -n "$CLKS" ] && printf ' {"cmd": "create_clock", "args": [%s]},' "$CLKS"
    [ "$PROPAGATED" = 1 ] && printf ' {"cmd": "set_propagated_clock", "args": []},'
    printf ' {"cmd": "set_wire_rc", "args": ["-signal", "-layer", "%s"]}, {"cmd": "set_wire_rc", "args": ["-clock", "-layer", "%s"]},' "$SIG_RC" "$CLK_RC"
    printf ' {"cmd": "estimate_parasitics", "args": ["-placement", "-spef_file", "%s"]}]}\n' "$SPEF"
  } > "$OUT/$LABEL.est.json"
  rc=0; runq "$(eng est)" estimate "$OUT/$LABEL.est.json" -o "$OUT/$LABEL.est.out" || rc=$?
  [ "$rc" -eq 0 ] || { echo "error: the wire estimate stopped (exit $rc); see $OUT/$LABEL.est.out" >&2; exit 2; }
  echo "  $(jget "$OUT/$LABEL.est.out" nets) nets estimated"
fi

# The script, as the timer runs it and as any other timer would read it.
SCRIPT=$OUT/$LABEL.tcl
{
  echo "read_liberty $LIBERTY"
  for f in "${MACRO_LIBS[@]+"${MACRO_LIBS[@]}"}"; do echo "read_liberty $f"; done
  echo "read_verilog $NETLIST"
  echo "link_design $TOP"
  echo "read_sdc $SDC"
  [ "$PROPAGATED" = 1 ] && echo "set_propagated_clock [all_clocks]"
  [ -n "$SPEF" ] && echo "read_spef $SPEF"
  echo "report_checks -path_delay max -fields {slew cap} -digits $DIGITS"
  echo "report_checks -path_delay min -fields {slew cap} -digits $DIGITS"
  echo "report_wns -digits $DIGITS"
  echo "report_tns -digits $DIGITS"
  echo "report_wns -min -digits $DIGITS"
  echo "report_tns -min -digits $DIGITS"
} > "$SCRIPT"
"$PY" - "$OUT/$LABEL.args.json" "$TOP" "$IN_ODB" "$SIG_RC" "$CLK_RC" "$PROPAGATED" "$TLEF" "$CLEF" "${MACRO_LEFS[@]+"${MACRO_LEFS[@]}"}" <<'PY'
import json, sys
a = sys.argv
json.dump({"top": a[2], "odb": a[3], "signal_rc_layer": a[4], "clock_rc_layer": a[5],
           "propagated": a[6] == "1", "lefs": a[7:]}, open(a[1], "w"), indent=1)
PY

RPT=$OUT/$LABEL.rpt
rc=0; "$STA" tcl "$SCRIPT" -o "$RPT" 2> "$OUT/$LABEL.log" || rc=$?
if [ "$rc" -ne 0 ]; then
  sed 's/^/  /' "$OUT/$LABEL.log" >&2
  echo "error: the timer stopped (exit $rc); see $OUT/$LABEL.log" >&2
  exit 2
fi
# the summary lines the report ends with
grep -E '^(wns|tns) ' "$RPT" | sed 's/^/  /'
step "result — $RPT"
