#!/usr/bin/env bash
#
# SPDX-License-Identifier: Apache-2.0
# © 2026 https://vyges.com. All Rights Reserved.
#
# This script is licensed under the Apache License, Version 2.0; see LICENSE and NOTICE.
# http://www.apache.org/licenses/LICENSE-2.0
#
# Route a placed design with the Vyges Loom engines, then check it for antenna damage.
#
#     grt  ->  drt  ->  write DEF  ->  ant
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
PDK=${VYGES_PDK:-sky130a} LIB=sky130_fd_sc_hd CORNER=tt_025C_1v80 OUT=build BIN=${VYGES_BIN:-}

while [ $# -gt 0 ]; do
  case $1 in
    --odb)        IN_ODB=$2; shift 2 ;;
    --def)        IN_DEF=$2; shift 2 ;;
    --min-layer)  MINL=$2; shift 2 ;;
    --max-layer)  MAXL=$2; shift 2 ;;
    --adjustment) ADJ=$2; shift 2 ;;
    --no-congestion) CONGEST=false; shift ;;
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

ODB=$(eng opendb); GRT=$(eng grt); DRT=$(eng drt); ANT=$(eng ant)
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
step "1 · grt — route guides for every net"
cat > "$OUT/r1.grt.job.json" <<EOF
{"db": "$IN_ODB",
 "steps": [{"cmd": "set_routing_layers", "signal": ["$MINL", "$MAXL"], "clock": ["$MINL", "$MAXL"]},
           {"cmd": "global_adjustment", "value": $ADJ},
           {"cmd": "global_route", "allow_congestion": $CONGEST},
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
if r.get("reason"): print(f"  {r['reason']}")
PY
[ "$rc" -eq 0 ] || exit "$rc"

# 2 ── detailed routing ──────────────────────────────────────────────────────────────────────
step "2 · drt — wires and vias, repaired until no design-rule marker stands"
rc=0; runq "$DRT" detailed_route --db "$OUT/r1.grt.odb" --out "$OUT/routed.odb" -o "$OUT/r2.drt.json" || rc=$?
echo "  drt: $(jget "$OUT/r2.drt.json" status) $(jget "$OUT/r2.drt.json" reason)"
# markers (1) is a finding: the design is routed and written, so the rest still runs.
[ "$rc" -le 1 ] || exit "$rc"
DRT_RC=$rc

# 3 ── the routed design as DEF ─────────────────────────────────────────────────────────────
step "3 · write the routed design"
runq "$ODB" write-def --input "$OUT/routed.odb" --output "$OUT/routed.def"

# 4 ── antenna ───────────────────────────────────────────────────────────────────────────────
step "4 · ant — antenna ratios on the routed metal"
ANT_RC=0; "$ANT" check "$OUT/routed.odb" -o "$OUT/r4.ant.json" 2>/dev/null || ANT_RC=$?
echo "  ant: $(jget "$OUT/r4.ant.json" status)"
[ "$ANT_RC" -le 1 ] || exit "$ANT_RC"

step "result — $OUT/routed.odb (and routed.def)"
printf '  %-10s %s\n' \
  routing "$(jget "$OUT/r2.drt.json" status)" \
  antenna "$(jget "$OUT/r4.ant.json" status)"
[ "$DRT_RC" -eq 0 ] && [ "$ANT_RC" -eq 0 ] || exit 1
