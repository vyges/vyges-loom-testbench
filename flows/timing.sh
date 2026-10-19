#!/usr/bin/env bash
#
# SPDX-License-Identifier: Apache-2.0
# © 2026 https://vyges.com. All Rights Reserved.
#
# This script is licensed under the Apache License, Version 2.0; see LICENSE and NOTICE.
# http://www.apache.org/licenses/LICENSE-2.0
#
# Time a design with the Vyges Loom static timing engine before it is placed: the synthesized
# netlist, the cell (and hard-macro) libraries and the constraints, with no wires yet. Each path
# group's worst setup and hold path is reported, then the worst and total negative slack.
#
#   ./flows/timing.sh --netlist build/my_block.v --clock-port clk_i --clock-period 50
#
# A violation is REPORTED, not failed on: timing this early says where the design starts, and
# placement and repair are still to come. ./implement.sh runs it first.
#
# OPTIONS
#   --netlist FILE        structural gate-level Verilog (required)
#   --top NAME            its top module (default: the one module no other instantiates)
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
#
# EXIT STATUS: 0 timed (whatever the slack) · 2 error
#
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

NETLIST= TOP= CLOCK_PORT= CLOCK_PERIOD= IO_DELAY=20 SDC= DIGITS=4 LABEL=t0.pre
MACRO_LEFS=() MACRO_LIBS=()
PDK=${VYGES_PDK:-sky130a} LIB=sky130_fd_sc_hd CORNER=tt_025C_1v80 OUT=build BIN=${VYGES_BIN:-}

while [ $# -gt 0 ]; do
  case $1 in
    --netlist)      NETLIST=$2; shift 2 ;;
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

[ -n "$NETLIST" ] && [ -f "$NETLIST" ] || { echo "error: --netlist <gate-level.v> is required and must exist." >&2; exit 2; }
if [ -z "$SDC" ] && { [ -z "$CLOCK_PORT" ] || [ -z "$CLOCK_PERIOD" ]; }; then
  echo "error: give --clock-port and --clock-period, or --sdc FILE." >&2; exit 2
fi
STA=$(eng sta-si)
pdk_resolve
mkdir -p "$OUT"
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
step "$TOP — timing before placement (no wires)"
echo "pdk:     $PDK · $LIB · $CORNER"
echo "engines: $(dirname "$STA")"

# The script, as the timer runs it and as any other timer would read it.
SCRIPT=$OUT/$LABEL.tcl
{
  echo "read_liberty $LIBERTY"
  for f in "${MACRO_LIBS[@]+"${MACRO_LIBS[@]}"}"; do echo "read_liberty $f"; done
  echo "read_verilog $NETLIST"
  echo "link_design $TOP"
  echo "read_sdc $SDC"
  echo "report_checks -path_delay max -fields {slew cap} -digits $DIGITS"
  echo "report_checks -path_delay min -fields {slew cap} -digits $DIGITS"
  echo "report_wns -digits $DIGITS"
  echo "report_tns -digits $DIGITS"
  echo "report_wns -min -digits $DIGITS"
  echo "report_tns -min -digits $DIGITS"
} > "$SCRIPT"
"$PY" - "$OUT/$LABEL.args.json" "$TOP" "$TLEF" "$CLEF" "${MACRO_LEFS[@]+"${MACRO_LEFS[@]}"}" <<'PY'
import json, sys
json.dump({"top": sys.argv[2], "lefs": sys.argv[3:]}, open(sys.argv[1], "w"), indent=1)
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
