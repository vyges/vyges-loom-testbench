#!/usr/bin/env bash
#
# SPDX-License-Identifier: Apache-2.0
# © 2026 https://vyges.com. All Rights Reserved.
#
# This script is licensed under the Apache License, Version 2.0; see LICENSE and NOTICE.
# http://www.apache.org/licenses/LICENSE-2.0
#
# Build an IO ring and route the RDL for a flip-chip design with one Vyges Loom engine.
#
#     make-io-sites -> place-pad -> global-connect -> place-corners -> place-io-fill
#                   -> connect-by-abutment -> make-io-bump-array -> assign-io-bump -> rdl-route
#
# Nine steps, three static binaries -- `pad` does seven of them, `pdn` the supply nets and `opendb`
# the file I/O. Nothing here starts a container or sources a Tcl script.
#
#   ./flows/io-ring.sh --def my_flipchip.def --lef tech.lef --lef cells.lef \
#                      --h-site IOSITE --v-site IOSITE --corner-site IOSITE \
#                      --corner-master PADCELL_CORNER --pads pads.txt --assign bumps.txt \
#                      --bump DUMMY_BUMP --rdl-layer metal10
#
# TWO STEPS ARE PER-DESIGN DATA, and they are read from files rather than invented here.
#
#   --pads FILE    one pad per line:  ROW  LOCATION  MASTER  INST  [mirror]
#   --assign FILE  one bump per line: BUMP  NET  [TERMINAL_INST/PIN | -]  [dont_route]
#   --connect S    repeatable: NET:PINPAT:INSTPAT:power|ground|signal
#
# ⛔ Neither is optional in spirit. `rdl-route` routes bumps to the pads their nets reach, so a
# design with no assignments has nothing to route, and the flow would then report success having
# done nothing. The script refuses that case below rather than printing a zero.
#
# WHY THIS EXISTS, and what it is not.
#
# The floorplan flow (./floorplan.sh) chains four engines and ends by diffing rows and tracks
# against taped-out silicon. It is an interconnectivity test, and a good one — but it never runs
# `pad`, so the RDL router had no end-to-end exercise at all.
#
# ⛔ This is that exercise, and it is deliberately NOT a correctness check. It asserts only what a
# flow can honestly assert of itself: every step succeeds, the ring closes, and the router either
# routes every net or says which it could not. A script comparing a tool with itself proves
# nothing, which is the whole reason the floorplan flow diffs against silicon instead.
#
# ⚠️ `rdl-route` exits non-zero when any net is left unrouted. That is deliberate and this script
# does not paper over it: a floorplan you cannot finish routing is not a pass.
set -euo pipefail

OUT=build/io-ring BIN=${VYGES_BIN:-} DEF= LEFS=() OFFSET=35
H_SITE= V_SITE= CORNER_SITE= CORNER_MASTER= BUMP= RDL_LAYER= RDL_WIDTH=4 RDL_SPACING=4
BUMP_ORIGIN= BUMP_ROWS=0 BUMP_COLS=0 BUMP_PITCH= FILL_MASTERS= ALLOW45= PADS= ASSIGN=
CONNECT=()

while [ $# -gt 0 ]; do
  case $1 in
    --def)            DEF=$2; shift 2 ;;
    --lef)            LEFS+=("$2"); shift 2 ;;
    --out)            OUT=$2; shift 2 ;;
    --bin)            BIN=$2; shift 2 ;;
    --offset)         OFFSET=$2; shift 2 ;;
    --h-site)         H_SITE=$2; shift 2 ;;
    --v-site)         V_SITE=$2; shift 2 ;;
    --corner-site)    CORNER_SITE=$2; shift 2 ;;
    --corner-master)  CORNER_MASTER=$2; shift 2 ;;
    --fill-masters)   FILL_MASTERS=$2; shift 2 ;;
    --pads)           PADS=$2; shift 2 ;;
    --assign)         ASSIGN=$2; shift 2 ;;
    --connect)        CONNECT+=("$2"); shift 2 ;;
    --bump)           BUMP=$2; shift 2 ;;
    --bump-origin)    BUMP_ORIGIN=$2; shift 2 ;;
    --bump-rows)      BUMP_ROWS=$2; shift 2 ;;
    --bump-columns)   BUMP_COLS=$2; shift 2 ;;
    --bump-pitch)     BUMP_PITCH=$2; shift 2 ;;
    --rdl-layer)      RDL_LAYER=$2; shift 2 ;;
    --rdl-width)      RDL_WIDTH=$2; shift 2 ;;
    --rdl-spacing)    RDL_SPACING=$2; shift 2 ;;
    --allow45)        ALLOW45=--allow45; shift ;;
    -h|--help)        sed -n '9,48p' "$0"; exit 0 ;;
    *) echo "error: unknown option $1" >&2; exit 2 ;;
  esac
done

# A flow that silently picks up a different build than the reader expects is the hardest kind of
# difference to chase, so resolve the engines once and say where they came from.
eng() {
  local n=vyges-$1 p
  if [ -n "$BIN" ]; then p=$BIN/$n; else p=$(command -v "$n" 2>/dev/null || true); fi
  [ -x "${p:-}" ] || { echo "error: $n not found; install with 'vyges install physical', or pass --bin <dir>." >&2; exit 1; }
  echo "$p"
}
PAD=$(eng pad); ODB=$(eng opendb); PDN=$(eng pdn)

[ -n "$DEF" ]        || { echo "error: --def <flipchip.def> is required." >&2; exit 2; }
[ ${#LEFS[@]} -gt 0 ] || { echo "error: at least one --lef is required." >&2; exit 2; }
for v in H_SITE V_SITE CORNER_SITE RDL_LAYER; do
  [ -n "${!v}" ] || { echo "error: --${v,,} is required." >&2 ; exit 2; }
done

mkdir -p "$OUT"
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
step=0
next() { step=$((step+1)); echo "$OUT/$step.$1.odb"; }

say "engines"
echo "  pad     $PAD"
echo "  opendb  $ODB"
echo "  pdn     $PDN"

say "1 · import — LEF and the flip-chip DEF into a database"
CUR=$(next imported)
lefargs=(); for l in "${LEFS[@]}"; do lefargs+=(--lef "$l"); done
"$ODB" import "${lefargs[@]}" --def "$DEF" --output "$CUR"

say "2 · make-io-sites — the ring of IO rows around the die"
PREV=$CUR; CUR=$(next sites)
"$PAD" make-io-sites "$PREV" --horizontal-site "$H_SITE" --vertical-site "$V_SITE" \
  --corner-site "$CORNER_SITE" --offset "$OFFSET" --out-odb "$CUR"

if [ -n "$PADS" ]; then
  say "3 · place-pad — the design's own pads into those rows"
  n=0
  # One invocation per pad, which is also how the reference command is shaped: `place_pad` takes a
  # single instance. Reading the list from a file keeps design data out of the flow.
  while read -r row loc master inst mirror; do
    case "$row" in ''|'#'*) continue ;; esac
    PREV=$CUR; CUR=$(next "pad_$inst")
    "$PAD" place-pad "$PREV" --row "$row" --location "$loc" --master "$master" \
      --inst "$inst" ${mirror:+--mirror} --out-odb "$CUR"
    n=$((n+1))
  done < "$PADS"
  echo "  placed $n pads"
fi

# 🔑 UPSTREAM'S ORDER, and it is not cosmetic. `rdl_route_assignments.tcl` runs `global_connect`
# at line 256 -- after every `place_pad` and BEFORE `place_corners` -- because the supply nets have
# to exist before anything is assigned to them, and the pads have to exist before their pins can be
# matched onto those nets. Running it later gets `no net named DVSS`, which is how this was found.
if [ ${#CONNECT[@]} -gt 0 ]; then
  say "4 · global-connect — create the supply nets and tie the pads' pins to them"
  PREV=$CUR; CUR=$(next connected)
  cargs=(); for c in "${CONNECT[@]}"; do cargs+=(--connect "$c"); done
  "$PDN" global-connect "$PREV" "${cargs[@]}" --out-odb "$CUR"
fi

if [ -n "$CORNER_MASTER" ]; then
  say "5 · place-corners — the four corner cells"
  PREV=$CUR; CUR=$(next corners)
  "$PAD" place-corners "$PREV" --master "$CORNER_MASTER" --out-odb "$CUR"
fi

if [ -n "$FILL_MASTERS" ]; then
  say "6 · place-io-fill — close the gaps between pads"
  for row in IO_SOUTH IO_WEST IO_NORTH IO_EAST; do
    PREV=$CUR; CUR=$(next "fill_$row")
    "$PAD" place-io-fill "$PREV" --row "$row" --masters "$FILL_MASTERS" --out-odb "$CUR"
  done
fi

say "7 · connect-by-abutment — the ring's own supply nets"
PREV=$CUR; CUR=$(next abutted)
"$PAD" connect-by-abutment "$PREV" --out-odb "$CUR"

if [ -n "$BUMP" ] && [ "$BUMP_ROWS" -gt 0 ]; then
  say "8 · make-io-bump-array — the bump grid"
  PREV=$CUR; CUR=$(next bumps)
  "$PAD" make-io-bump-array "$PREV" --bump "$BUMP" --origin "$BUMP_ORIGIN" \
    --rows "$BUMP_ROWS" --columns "$BUMP_COLS" --pitch "$BUMP_PITCH" --out-odb "$CUR"
fi

say "9 · assign-io-bump — which bump carries which net"
if [ -n "$ASSIGN" ]; then
  n=0
  while read -r bump net terminal dont; do
    case "$bump" in ''|'#'*) continue ;; esac
    PREV=$CUR; CUR=$(next "assign_$bump")
    # ⚠️ `-` is how the file says "no terminal", because a positional field cannot be empty.
    [ "${terminal:-}" = "-" ] && terminal=
    "$PAD" assign-io-bump "$PREV" --bump "$bump" --net "$net" \
      ${terminal:+--terminal "$terminal"} ${dont:+--dont-route} --out-odb "$CUR"
    n=$((n+1))
  done < "$ASSIGN"
  echo "  assigned $n bumps"
  # ⛔ `dont_route` is DECLARED HERE AND CANNOT REACH STEP 9, and saying so is the point.
  # Upstream keeps it in `ICeWall::routing_map_`, a member of the command object, and writes
  # nothing to the database -- so our `assign-io-bump` faithfully writes nothing either, and every
  # command in this flow is a separate process with the database as its only channel. The bumps
  # below WILL be routed. Upstream has the same hole across its own `write_db`; we reported it as
  # OpenROAD issue #11305.
  d=$(grep -c 'dont_route' "$ASSIGN" || true)
  [ "$d" -gt 0 ] && cat >&2 <<EOM
  warning: $d assignments carry dont_route, which does not survive a process boundary --
           neither here nor upstream (OpenROAD #11305). Those bumps will be routed.
EOM
else
  # ⛔ No assignments means nothing to route, and `rdl-route` would exit 0 having done nothing.
  echo "error: --assign is required; without it rdl-route has no bump-to-pad work and would" >&2
  echo "       report success having routed nothing." >&2
  exit 2
fi

say "10 · rdl-route — bumps to pads across the face of the die"
PREV=$CUR; CUR=$(next routed)
# ⚠️ Not swallowed. rdl-route exits non-zero when a net is left unrouted, and a floorplan you
# cannot finish routing is not a pass.
"$PAD" rdl-route "$PREV" --layer "$RDL_LAYER" --width "$RDL_WIDTH" --spacing "$RDL_SPACING" \
  $ALLOW45 --nets '*' --out-odb "$CUR"

say "11 · write the DEF"
"$ODB" write-def --input "$CUR" --output "$OUT/io-ring.def"

say "result — $OUT/io-ring.def"
awk '/^COMPONENTS/{c=$2} /^SPECIALNETS/{s=$2} END{printf "  components %s\n  special nets %s\n", c, s}' "$OUT/io-ring.def"
# ⚠️ `grep -c` exits 1 on no matches, which under `set -o pipefail` would fail the script on its
# very last line -- reporting a routing failure as a flow crash. Count without letting it.
printf '  routed wire statements %s\n' "$(grep -c 'ROUTED\|NEW\|FIXED' "$OUT/io-ring.def" || true)"
