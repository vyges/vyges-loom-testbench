#!/usr/bin/env bash
#
# SPDX-License-Identifier: Apache-2.0
# © 2026 https://vyges.com. All Rights Reserved.
#
# This script is licensed under the Apache License, Version 2.0; see LICENSE and NOTICE.
# http://www.apache.org/licenses/LICENSE-2.0
#
# Stream a routed design out for tapeout: colour the multi-patterned layers, write the layout,
# check the layout written.
#
#     routed DEF  ->  import  ->  color-masks --require-coloured  ->  write-gds  ->  check-gds-layers
#
# On a multi-patterned layer (a routing layer the tech LEF gives MASK 2 or more) the masks are
# written only through each shape's colour, so the colour step is part of the stream-out, not an
# option, and a shape it cannot colour stops the run (REFUSED, exit 3). On a technology without
# such a layer the colour step has nothing to do and the layout is written from the DEF.
#
# With --allowed-pairs (the foundry's allowed layer/datatype pairs, an input file, one `L D` per
# line), write-gds drops every layer map target outside the list, and the layout written is
# checked against it: a pair off the list is REFUSED. On a multi-patterned technology the layout is
# also checked for shapes on the pairs the map sends UNCOLOURED shapes of those layers to (cell
# metal included, which the colour step does not see).
#
#   ./flows/stream-out.sh --lef tech.lef --lef cells.lef --def build/routed.def \
#                         --map pdk.map --gds cells.gds --output build/top.gds [--allowed-pairs pairs.txt]
#
# OPTIONS
#   --lef FILE            a LEF, the tech LEF first (repeatable; required)
#   --def FILE            the routed (or filled) DEF (required)
#   --map FILE            the LEF/DEF layer map (required)
#   --gds FILE            cell library GDS or OASIS (repeatable; required)
#   --output FILE         the layout to write, .gds or .oas (required)
#   --allowed-pairs FILE  the allowed layer/datatype pairs (see above)
#   --bin DIR             where the engines are (default: PATH)
#
# Next to --output it writes <name>.routed.odb, <name>.coloured.odb (when anything was coloured),
# <name>.color-masks.json and <name>.layers.json.
#
# EXIT STATUS: 0 written and every check clean · 1 written, with colour findings standing (same-mask
# spacing, off-track or wrong-way shapes, odd cycles: see <name>.color-masks.json) · 2 bad input or
# a missing tool · 3 REFUSED by a tapeout check (an uncoloured shape on a multi-patterned layer, a
# pair off the allowed list); the layout is then not fit to tape out · anything else, the failing
# step's own status.
#
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

LEFS=() DEF= MAP= CELLS=() OUTPUT= ALLOWED= BIN=${VYGES_BIN:-}
while [ $# -gt 0 ]; do
  case $1 in
    --lef)           LEFS+=("$2"); shift 2 ;;
    --def)           DEF=$2; shift 2 ;;
    --map)           MAP=$2; shift 2 ;;
    --gds)           CELLS+=("$2"); shift 2 ;;
    --output)        OUTPUT=$2; shift 2 ;;
    --allowed-pairs) ALLOWED=$2; shift 2 ;;
    --bin)           BIN=$2; shift 2 ;;
    -h|--help)
      awk '!/^#/ && NR>1 {exit} /SPDX|©|licensed under the Apache|apache[.]org/ {next} NR>1 {sub(/^# ?/, ""); print}' "${BASH_SOURCE[0]}" | sed '/./,$!d'; exit 0 ;;
    *) echo "error: unknown option $1" >&2; exit 2 ;;
  esac
done
[ ${#LEFS[@]} -gt 0 ]  || { echo "error: --lef FILE is required (the tech LEF first)" >&2; exit 2; }
[ -n "$DEF" ]          || { echo "error: --def FILE is required" >&2; exit 2; }
[ -n "$MAP" ]          || { echo "error: --map FILE is required" >&2; exit 2; }
[ ${#CELLS[@]} -gt 0 ] || { echo "error: --gds FILE is required (the cell library layout)" >&2; exit 2; }
[ -n "$OUTPUT" ]       || { echo "error: --output FILE is required" >&2; exit 2; }
for f in "${LEFS[@]}" "$DEF" "$MAP" "${CELLS[@]}" ${ALLOWED:+"$ALLOWED"}; do
  [ -f "$f" ] || { echo "error: no such file: $f" >&2; exit 2; }
done

# shellcheck source=_common.sh
. "$HERE/_common.sh"
ODB=$(eng opendb)

# The reports are named after the layout, its format kept apart: a GDS and an OASIS run of one
# design never write over each other.
BASE=${OUTPUT%.*}; case $OUTPUT in *.oas|*.oasis|*.OAS|*.OASIS) BASE=$BASE.oas ;; esac
LEF_ARGS=(); for f in "${LEFS[@]}"; do LEF_ARGS+=(--lef "$f"); done
GDS_ARGS=(); for f in "${CELLS[@]}"; do GDS_ARGS+=(--gds "$f"); done
PAIRS=(); [ -n "$ALLOWED" ] && PAIRS=(--allowed-pairs "$ALLOWED")

step "color-masks — mask colours on the multi-patterned routing layers"
runq "$ODB" import "${LEF_ARGS[@]}" --def "$DEF" --output "$BASE.routed.odb"
# The colour step refuses (exit 3) a shape it leaves uncoloured; that ends the run here.
rc=0
"$ODB" color-masks --input "$BASE.routed.odb" --output "$BASE.coloured.odb" --lef "${LEFS[0]}" \
  --require-coloured --report "$BASE.color-masks.json" > /dev/null 2> >(sed 's/^/  /' >&2) || rc=$?
if [ "$rc" = 3 ]; then
  echo "REFUSED: a shape on a multi-patterned layer has no mask colour; see $BASE.color-masks.json" >&2
  exit 3
fi
[ "$rc" = 0 ] || { echo "error: color-masks failed (exit $rc)" >&2; exit "$rc"; }
STATUS=$(jget "$BASE.color-masks.json" status)
FINDINGS=$("$PY" -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["findings"]))' "$BASE.color-masks.json")
case $STATUS in
  no_multi_mask_layers)
    MULTI=0; SRC=(${LEF_ARGS[@]+"${LEF_ARGS[@]}"} --def "$DEF")
    echo "  no multi-patterned routing layer: nothing to colour" ;;
  applied|up_to_date)
    MULTI=1
    # `up_to_date` writes nothing: the routed database already carries every colour.
    if [ "$STATUS" = applied ]; then SRC=(--input "$BASE.coloured.odb"); else SRC=(--input "$BASE.routed.odb"); fi
    echo "  $STATUS: $(jget "$BASE.color-masks.json" coloured) of $(jget "$BASE.color-masks.json" shapes) shapes coloured, $FINDINGS finding(s)" ;;
  *) echo "error: color-masks: unexpected status '$STATUS'" >&2; exit 2 ;;
esac

step "write-gds — $OUTPUT"
runq "$ODB" write-gds "${SRC[@]}" --map "$MAP" "${PAIRS[@]+"${PAIRS[@]}"}" "${GDS_ARGS[@]}" --output "$OUTPUT"

# The layout written, read back by a reader that shares no code with the writer.
CHECK=()
[ -n "$ALLOWED" ] && CHECK+=(--allowed-pairs "$ALLOWED")
[ "$MULTI" = 1 ] && CHECK+=(--map "$MAP" --lef "${LEFS[0]}")
if [ ${#CHECK[@]} -gt 0 ]; then
  step "check-gds-layers — the layout's layer/datatype pairs"
  rc=0
  "$ODB" check-gds-layers --gds "$OUTPUT" "${CHECK[@]}" --report "$BASE.layers.json" > /dev/null \
    2> >(sed 's/^/  /' >&2) || rc=$?
  if [ "$rc" = 3 ]; then
    echo "REFUSED: $OUTPUT is not fit to tape out; see $BASE.layers.json" >&2
    exit 3
  fi
  [ "$rc" = 0 ] || { echo "error: check-gds-layers failed (exit $rc)" >&2; exit "$rc"; }
  echo "  clean: $(jget "$BASE.layers.json" elements) elements on $("$PY" -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["pairs"]))' "$BASE.layers.json") pairs"
fi
if [ "$FINDINGS" -gt 0 ]; then
  echo "  $FINDINGS colour finding(s) standing (written, not clean): $BASE.color-masks.json"
  exit 1
fi
exit 0
