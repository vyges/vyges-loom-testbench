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
#     grt (route, then repair antennas)  ->  dpl check  ->  drt  ->  write DEF  ->  ant
#
# Antenna repair runs inside the global router, on its routes: jumpers first, then a diode beside
# each gate still in violation, the diodes legalized onto the rows, and the nets they touched
# rerouted, repeated up to --antenna-iterations times. The defaults are the open flow's.
#
# The input is a placed design: the database ./place.sh writes, or any placed DEF. The output is
# a routed database and DEF.
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
#   --threads N           detailed-routing worker threads (default: every CPU); the routes are the
#                         same at any count
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

IN_ODB= IN_DEF= MINL=met1 MAXL=met4 ADJ=0.3 CONGEST=true
ANT_REPAIR=true DIODE= ANT_ITERS=3 ANT_MARGIN=10 DONT_USE_FILE= THREADS=
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
    --threads)    THREADS=$2; shift 2 ;;
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

ODB=$(eng opendb); GRT=$(eng grt); DRT=$(eng drt); ANT=$(eng ant); DPL=$(eng dpl)
mkdir -p "$OUT"
if [ -n "$IN_DEF" ]; then
  [ -f "$IN_DEF" ] || { echo "error: no such DEF: $IN_DEF" >&2; exit 2; }
  pdk_resolve
  def_to_odb "$IN_DEF" "$OUT/r0.placed.odb"; IN_ODB=$OUT/r0.placed.odb
fi
[ -n "$IN_ODB" ] && [ -f "$IN_ODB" ] || { echo "error: --odb <placed.odb> or --def <placed.def> is required." >&2; exit 2; }
step "routing $IN_ODB — layers $MINL..$MAXL"
echo "engines: $(dirname "$GRT")"

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

# The diodes were legalized inside the repair; check every cell is still on a legal site.
if [ "$ANT_REPAIR" = true ]; then
  step "1b · dpl check-placement — with the antenna diodes"
  rc=0; runq "$DPL" check-placement "$OUT/r1.grt.odb" -o "$OUT/r1b.check.json" || rc=$?
  echo "  $(jget "$OUT/r1b.check.json" status): $(jget "$OUT/r1b.check.json" violations) violations over $(jget "$OUT/r1b.check.json" cells_checked) cells"
  [ "$rc" -eq 0 ] || exit "$rc"
fi

# 2 ── detailed routing ──────────────────────────────────────────────────────────────────────
step "2 · drt — wires and vias, repaired until no design-rule marker stands"
# Each search-and-repair batch's workers in parallel, written back in batch order: the same routes
# at any thread count.
THREADS=${THREADS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)}
echo "  drt threads: $THREADS"
rc=0; VYGES_DRT_THREADS=$THREADS runq "$DRT" detailed_route --db "$OUT/r1.grt.odb" --out "$OUT/routed.odb" -o "$OUT/r2.drt.json" || rc=$?
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

step "result — $OUT/routed.odb (and routed.def)"
printf '  %-10s %s\n' \
  routing "$(jget "$OUT/r2.drt.json" status)" \
  antenna "$(jget "$OUT/r4.ant.json" status)" \
  dont_use "$([ "$DONT_USE_FOUND" -eq 0 ] && echo clean || echo "$DONT_USE_FOUND excluded")"
[ "$DRT_RC" -eq 0 ] && [ "$ANT_RC" -eq 0 ] && [ "$DONT_USE_FOUND" -eq 0 ] || exit 1
