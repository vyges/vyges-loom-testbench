# shellcheck shell=bash
#
# SPDX-License-Identifier: Apache-2.0
# © 2026 https://vyges.com. All Rights Reserved.
#
# This script is licensed under the Apache License, Version 2.0; see LICENSE and NOTICE.
# http://www.apache.org/licenses/LICENSE-2.0
#
# Shared by place.sh and route.sh: find python, find the engines, resolve the PDK through the
# store, and print a numbered step. Sourced, never run. floorplan.sh predates it and keeps its own
# copy, so the published floorplan flow does not change underneath anyone.

export VYGES_LOG_FORMAT=${VYGES_LOG_FORMAT:-text}
export VYGES_LOG=${VYGES_LOG:-info}

PY=
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' 2>/dev/null; then
    PY=$(command -v "$c"); break
  fi
done
[ -n "$PY" ] || { echo "error: no python3 (>= 3.8) on PATH; the engines do not need it, the glue steps of this script do." >&2; exit 2; }

# Resolve every engine once and say where it came from: a flow that silently picks up a different
# build than the reader expects is the hardest kind of difference to chase.
eng() {
  local n=vyges-$1 p
  if [ -n "${BIN:-}" ]; then p=$BIN/$n; else p=$(command -v "$n" 2>/dev/null || true); fi
  if [ ! -x "${p:-}" ]; then
    echo "error: $n not found." >&2
    echo "       install:  vyges install physical && vyges install loom" >&2
    echo "       then add ~/.vyges/bin to PATH, or pass --bin <dir>." >&2
    exit 1
  fi
  echo "$p"
}

# The PDK's collateral, from the store rather than a hard-coded directory layout.
pdk_resolve() {
  local store
  if [ -n "${BIN:-}" ]; then store=$BIN/vyges-pdk-store; else store=$(command -v vyges-pdk-store 2>/dev/null || true); fi
  [ -x "$store" ] || { echo "error: vyges-pdk-store not found; install it with 'vyges install loom', or pass --bin <dir>." >&2; exit 1; }
  TLEF=$("$store" resolve "$PDK" tech_lef 2>/dev/null | head -1) || true
  CLEF=$("$store" resolve "$PDK" lef --library "$LIB" 2>/dev/null | head -1) || true
  LIBERTY=$("$store" resolve "$PDK" lib --corner "$CORNER" --library "$LIB" 2>/dev/null | head -1) || true
  local f
  for f in TLEF CLEF LIBERTY; do
    if [ -z "${!f:-}" ] || [ ! -f "${!f}" ]; then
      echo "error: could not resolve $f for PDK '$PDK' (library $LIB, corner $CORNER)." >&2
      echo "       registered PDKs:   vyges pdk-store list" >&2
      echo "       fetch the data:    vyges pdk-store fetch $PDK" >&2
      echo "       point at the data: export PDK_ROOT=/dir/containing/the/pdk   (or --pdk-root)" >&2
      exit 2
    fi
  done
}

step() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# Run one engine, indent its log, and keep its exit status (a pipe would otherwise report sed's).
runq() { "$@" 2>&1 | sed 's/^/  /'; return "${PIPESTATUS[0]}"; }

# A database from LEF + DEF. The FIRST --lef creates the technology, so the tech LEF goes first.
def_to_odb() { runq "$ODB" import --lef "$TLEF" --lef "$CLEF" --def "$1" --output "$2"; }

# Read one top-level field of a JSON report.
jget() { "$PY" -c 'import json,sys; v=json.load(open(sys.argv[1])).get(sys.argv[2]); print("" if v is None else v)' "$1" "$2"; }

usage() { awk '!/^#/ && NR>1 {exit} /SPDX|©|licensed under the Apache|apache[.]org|shellcheck/ {next} NR>1 {sub(/^# ?/, ""); print}' "$1" | sed '/./,$!d'; }
