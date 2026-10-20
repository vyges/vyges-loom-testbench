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

# The cells no engine may insert (`dont_use`): DONT_USE_FILE if given (--dont-use), else the PDK
# store's list for the library; DONT_USE = its names or globs, whitespace-separated, '#' comments
# dropped. A sky130 probe cell, for one, is a buffer whose output pin is on met5: inserted, it
# leaves a pin above the routing layers that detailed routing cannot reach.
dont_use_resolve() {
  local store
  if [ -z "${DONT_USE_FILE:-}" ]; then
    if [ -n "${BIN:-}" ]; then store=$BIN/vyges-pdk-store; else store=$(command -v vyges-pdk-store 2>/dev/null || true); fi
    [ -x "${store:-}" ] && DONT_USE_FILE=$("$store" resolve "$PDK" dont_use --library "$LIB" 2>/dev/null | head -1) || true
  fi
  DONT_USE=
  if [ -n "${DONT_USE_FILE:-}" ]; then
    [ -f "$DONT_USE_FILE" ] || { echo "error: --dont-use $DONT_USE_FILE: no such file." >&2; exit 2; }
    DONT_USE=$(sed 's/#.*//' "$DONT_USE_FILE" | tr -s ' \t\n' ' ' | sed 's/^ //; s/ $//')
  fi
}

# The step that carries the list into an engine's job, after its liberty (nothing without a list):
# every engine that picks a cell reads it, as `set_dont_use` marks the cell for every tool.
dont_use_step() { [ -n "${DONT_USE:-}" ] && printf '{"cmd": "set_dont_use", "args": ["%s"]},' "$DONT_USE"; return 0; }

# The design's instances whose master is on the list, from its DEF COMPONENTS: printed, and the
# count returned in DONT_USE_FOUND. An engine that does not pick cells still answers for them here.
dont_use_check() {
  DONT_USE_FOUND=0
  [ -n "${DONT_USE:-}" ] || return 0
  local out
  out=$("$PY" - "$1" "$DONT_USE" <<'PYEOF'
import fnmatch, re, sys
pats = sys.argv[2].split()
hits, inside = [], False
for line in open(sys.argv[1]):
    if line.startswith("COMPONENTS"): inside = True; continue
    if line.startswith("END COMPONENTS"): break
    m = inside and re.match(r"\s*-\s+(\S+)\s+(\S+)", line)
    if m and any(fnmatch.fnmatchcase(m.group(2), p) for p in pats):
        hits.append(f"{m.group(1)} ({m.group(2)})")
print(len(hits)); print(" ".join(hits[:10]) + (" …" if len(hits) > 10 else ""))
PYEOF
)
  DONT_USE_FOUND=$(echo "$out" | head -1)
  if [ "$DONT_USE_FOUND" -gt 0 ]; then echo "  dont_use: $DONT_USE_FOUND instance(s) of excluded cells: $(echo "$out" | sed -n 2p)"
  else echo "  dont_use: no excluded cell in the design"; fi
}

# The constraints a flow generates from the clock: one clock, every input and output delayed by
# a percentage of its period, fanout limited — the shape an open flow writes by default, and only
# commands every engine here reads. place.sh and timing.sh write the same file.
#   sdc_write FILE CLOCK_PORT PERIOD_NS IO_DELAY_PCT
sdc_write() {
  local iod
  iod=$("$PY" -c 'import sys; print(float(sys.argv[1]) * float(sys.argv[2]) / 100)' "$3" "$4")
  cat > "$1" <<EOF
create_clock -name $2 -period $3 [get_ports {$2}]
set_input_delay $iod -clock $2 [all_inputs]
set_output_delay $iod -clock $2 [all_outputs]
set_max_fanout 10 [current_design]
EOF
}

step() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# Run one engine, indent its log, and keep its exit status (a pipe would otherwise report sed's).
runq() { "$@" 2>&1 | sed 's/^/  /'; return "${PIPESTATUS[0]}"; }

# Hard macros (--macro-lef / --macro-lib): their LEFs after the cell library's, their libraries
# after the cell library in every timing job.
macro_lef_args() { local f; for f in "${MACRO_LEFS[@]+"${MACRO_LEFS[@]}"}"; do printf '%s\n' --lef "$f"; done; }
macro_lef_steps() { local f; for f in "${MACRO_LEFS[@]+"${MACRO_LEFS[@]}"}"; do printf '{"cmd": "read_lef", "args": ["%s"]}, ' "$f"; done; }
macro_lib_steps() { local f; for f in "${MACRO_LIBS[@]+"${MACRO_LIBS[@]}"}"; do printf '{"cmd": "read_liberty", "args": ["%s"]}, ' "$f"; done; }

# A database from LEF + DEF. The FIRST --lef creates the technology, so the tech LEF goes first.
def_to_odb() { local m; mapfile -t m < <(macro_lef_args); runq "$ODB" import --lef "$TLEF" --lef "$CLEF" "${m[@]+"${m[@]}"}" --def "$1" --output "$2"; }

# The supply connections a step that adds cells ends with, as an open flow ends every step
# (`set_global_connections` when it writes its views: one add_global_connection per supply pin
# pattern, every instance, then global_connect). A buffer, clock buffer, diode or filler added
# after the power grid otherwise keeps its supply pins on no net. The rules are floorplan.sh's
# step 5, from the same --power/--ground/--pin-power/--pin-ground and the same defaults.
supply_rules() {
  [ ${#PIN_POWER[@]}  -gt 0 ] || PIN_POWER=('^VPWR$' '^VPB$')
  [ ${#PIN_GROUND[@]} -gt 0 ] || PIN_GROUND=('^VGND$' '^VNB$')
  CONNECT=()
  local re
  for re in "${PIN_POWER[@]}";  do CONNECT+=(--connect "$POWER:$re:.*:power");   done
  for re in "${PIN_GROUND[@]}"; do CONNECT+=(--connect "$GROUND:$re:.*:ground"); done
}
#   supply_connect DB   connect DB's unconnected supply pins, in place; report in DB's .gc.json
supply_connect() {
  local f=$1 tmp=${1%.odb}.gc.odb rep=${1%.odb}.gc.json
  "$PDN" global-connect "$f" "${CONNECT[@]}" --out-odb "$tmp" > "$rep" 2> >(sed 's/^/  /' >&2) \
    || { echo "error: global-connect on $f failed" >&2; exit 1; }
  mv "$tmp" "$f"
  echo "  supplies: $(jget "$rep" connections) pins connected"
}

# Read one top-level field of a JSON report.
jget() { "$PY" -c 'import json,sys; v=json.load(open(sys.argv[1])).get(sys.argv[2]); print("" if v is None else v)' "$1" "$2"; }

usage() { awk '!/^#/ && NR>1 {exit} /SPDX|©|licensed under the Apache|apache[.]org|shellcheck/ {next} NR>1 {sub(/^# ?/, ""); print}' "$1" | sed '/./,$!d'; }
