#!/usr/bin/env bash
#
# SPDX-License-Identifier: Apache-2.0
# © 2026 https://vyges.com. All Rights Reserved.
#
# This script is licensed under the Apache License, Version 2.0; see LICENSE and NOTICE.
# http://www.apache.org/licenses/LICENSE-2.0
#
# Netlist to routed design with the Vyges Loom engines: the flow scripts, one after another, each
# reading what the last one wrote — the netlist timed first, as an open flow times it before
# placement.
#
#     timing.sh  ->  floorplan.sh  ->  place.sh  ->  route.sh
#
#   ./flows/implement.sh --netlist build/my_block.v --die-area '0 0 400 400' \
#                        --clock-port clk_i --clock-period 50
#
# Every option belongs to one of the scripts and is handed to it; see each script's --help.
# Two more are this script's own:
#
#   --through floorplan|place|route   stop after that segment (default route)
#   --out DIR                         one directory for all three (default ./build)
#
# Each segment keeps its own exit status, and the run stops at the first that does not succeed:
# 3 means an engine declined the design and says why, which on today's engines is usually a pointer
# to --skip-repair or --ideal-clock.
#
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Which script owns which option, and whether it takes a value. Shared options go to all of them.
PLACE_VAL=" --macro-lib --clock-port --clock-period --io-delay --sdc --density --io-hlayer --io-vlayer --signal-rc-layer \
--clock-rc-layer --slew-margin --cap-margin --clock-buffers --root-buffer --corner --clock-max-wire-length \
--setup-margin --hold-margin --max-buffer-percent "
PLACE_FLAG=" --skip-repair --ideal-clock --skip-timing-repair "
ROUTE_VAL=" --min-layer --max-layer --adjustment --diode-cell --antenna-iterations --antenna-margin --threads --fill-cells \
--grt-setup-margin --grt-hold-margin --grt-max-buffer-percent "
ROUTE_FLAG=" --no-congestion --no-antenna-repair --no-fill --grt-timing-repair "
SHARED_VAL=" --pdk --library --pdk-root --bin --macro-lef --power --ground --pin-power --pin-ground "
# Place and route both take these (floorplan inserts no cells).
PR_VAL=" --dont-use "
# timing.sh takes these of place.sh's, the shared ones, and the netlist.
# route.sh takes these of place.sh's too (its timing repair).
ROUTE_TOO=" --sdc --macro-lib --signal-rc-layer --clock-rc-layer --corner "
TIMING_VAL=" --clock-port --clock-period --io-delay --sdc --macro-lib --corner --pdk --library --pdk-root --bin --macro-lef "

THROUGH=route OUT=build FP=() PL=() RT=() TM=()
while [ $# -gt 0 ]; do
  case " $1 " in
    " --through ") THROUGH=$2; shift 2 ;;
    " --out ")     OUT=$2; shift 2 ;;
    " -h "|" --help ")
      awk '!/^#/ && NR>1 {exit} /SPDX|©|licensed under the Apache|apache[.]org/ {next} NR>1 {sub(/^# ?/, ""); print}' "${BASH_SOURCE[0]}" | sed '/./,$!d'; exit 0 ;;
    " --netlist ") FP+=("$1" "$2"); TM+=("$1" "$2"); shift 2 ;;
    *)
      [[ $TIMING_VAL == *" $1 "* ]] && TM+=("$1" "$2")
      [[ $ROUTE_TOO == *" $1 "* ]] && RT+=("$1" "$2")
      if   [[ $SHARED_VAL == *" $1 "* ]]; then FP+=("$1" "$2"); PL+=("$1" "$2"); RT+=("$1" "$2"); shift 2
      elif [[ $PR_VAL     == *" $1 "* ]]; then PL+=("$1" "$2"); RT+=("$1" "$2"); shift 2
      elif [[ $PLACE_VAL  == *" $1 "* ]]; then PL+=("$1" "$2"); shift 2
      elif [[ $PLACE_FLAG == *" $1 "* ]]; then PL+=("$1"); shift
      elif [[ $ROUTE_VAL  == *" $1 "* ]]; then RT+=("$1" "$2"); shift 2
      elif [[ $ROUTE_FLAG == *" $1 "* ]]; then RT+=("$1"); shift
      else FP+=("$1"); shift       # floorplan.sh rejects anything it does not know, with its name
      fi ;;
  esac
done
case $THROUGH in floorplan|place|route) ;; *) echo "error: --through floorplan|place|route" >&2; exit 2 ;; esac

banner() { printf '\n\033[1;7m %s \033[0m\n' "$*"; }
T0=$(date +%s)
banner "timing (before placement)"
"$HERE/timing.sh" --out "$OUT" "${TM[@]+"${TM[@]}"}"

banner "floorplan"
"$HERE/floorplan.sh" --out "$OUT" "${FP[@]+"${FP[@]}"}"
[ "$THROUGH" = floorplan ] && exit 0

banner "place"
"$HERE/place.sh" --def "$OUT/6.floorplan.def" --out "$OUT" "${PL[@]+"${PL[@]}"}"
[ "$THROUGH" = place ] && exit 0

banner "route"
rc=0; "$HERE/route.sh" --odb "$OUT/placed.odb" --out "$OUT" "${RT[@]+"${RT[@]}"}" || rc=$?
banner "done in $(( $(date +%s) - T0 )) s — $OUT/routed.def"
exit "$rc"
