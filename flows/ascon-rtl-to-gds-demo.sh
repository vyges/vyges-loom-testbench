#!/usr/bin/env bash
#
# SPDX-License-Identifier: Apache-2.0
# © 2026 https://vyges.com. All Rights Reserved.
#
# This script is licensed under the Apache License, Version 2.0; see LICENSE and NOTICE.
# http://www.apache.org/licenses/LICENSE-2.0
#
# RTL to GDS on a public design: the Ascon-AEAD128 core (NIST SP 800-232) from Vyges
# ascon-crypto-ip, on sky130A, through ./rtl-to-gds.sh.
#
#   git clone https://github.com/vyges/ascon-crypto-ip
#   git -C ascon-crypto-ip checkout 77215bc
#   ./flows/ascon-rtl-to-gds-demo.sh --repo ascon-crypto-ip
#
# About 9,400 cells and 926 signal pins on a 520 µm die: a crypto datapath with an asynchronous
# reset, IO-dominated, so pin placement works on a crowded perimeter. It ends in build/ascon_core.gds
# and, written from the same routed DEF by KLayout, build/ascon_core.klayout.gds; the run exits 0
# only when the two are identical on every layer.
#
# OPTIONS
#   --repo DIR   a clone of ascon-crypto-ip (default: $PWD)
#   ...any other option is passed to ./rtl-to-gds.sh (--out, --pdk-root, --bin, --no-xor, ...)
#
# The design repo is only read.
#
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

REPO=${VYGES_DESIGN_REPO:-$PWD} PASS=()
while [ $# -gt 0 ]; do
  case $1 in
    --repo) REPO=$2; shift 2 ;;
    -h|--help)
      awk '!/^#/ && NR>1 {exit} /SPDX|©|licensed under the Apache|apache[.]org/ {next} NR>1 {sub(/^# ?/, ""); print}' "${BASH_SOURCE[0]}" | sed '/./,$!d'; exit 0 ;;
    *) PASS+=("$1"); shift ;;
  esac
done
R=$REPO/rtl
for f in ascon_pkg.sv ascon_perm.sv ascon_core.sv; do
  [ -f "$R/$f" ] || { echo "error: $R/$f not found; pass --repo <a clone of vyges/ascon-crypto-ip>" >&2; exit 2; }
done

# Floorplan, power grid, clock and routing settings for this block; ~0.45 utilization.
exec "$HERE/rtl-to-gds.sh" \
  --rtl "$R/ascon_pkg.sv" --rtl "$R/ascon_perm.sv" --rtl "$R/ascon_core.sv" --top ascon_core \
  --die-area '0 0 520 520' --margins '5.52 10.88' --site unithd \
  --rail met1:0.48 --vstripe met4:1.6:153.6:16.32 --hstripe met5:1.6:153.18:16.65 \
  --clock-port clk_i --clock-period 20 --density 0.55 --io-hlayer met3 --io-vlayer met2 \
  --min-layer met1 --max-layer met4 --adjustment 0.3 --clock-max-wire-length 0 \
  --diode-cell sky130_fd_sc_hd__diode_2 --antenna-iterations 3 --antenna-margin 10 \
  "${PASS[@]+"${PASS[@]}"}"
