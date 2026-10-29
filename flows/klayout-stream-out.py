#!/usr/bin/env python3
#
# SPDX-License-Identifier: Apache-2.0
# © 2026 https://vyges.com. All Rights Reserved.
#
# This script is licensed under the Apache License, Version 2.0; see LICENSE and NOTICE.
# http://www.apache.org/licenses/LICENSE-2.0
#
"""A routed DEF to GDS with KLayout: the second, independent writer of rtl-to-gds.sh.

The open-flow recipe, step for step: load the PDK's KLayout technology; read the DEF with the
LEFs and the LEF/DEF layer map (no net, instance or pin properties); clear every cell but the
top and the via cells; read the standard-cell GDS into the cleared cells; copy the top cell's
tree into a fresh layout; refuse when a cell is left with no GDS; write it.

    klayout-stream-out.py --def routed.def --lef tech.lef --lef cells.lef --gds cells.gds \
                          --lyt sky130A.lyt --map sky130A.map --top my_block -o my_block.gds

Needs the KLayout Python module (`pip install klayout`). Exit 0 on success, 1 on a missing cell
GDS or any read/write failure.
"""
import argparse
import sys

import klayout.db as kdb


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--def", dest="def_file", required=True)
    ap.add_argument("--lef", action="append", default=[], help="LEF, the technology LEF first (repeatable)")
    ap.add_argument("--gds", action="append", default=[], help="cell GDS (repeatable)")
    ap.add_argument("--lyt", required=True, help="the PDK's KLayout technology (.lyt)")
    ap.add_argument("--map", required=True, help="the PDK's LEF/DEF layer map (.map)")
    ap.add_argument("--top", required=True, help="the design's top cell")
    ap.add_argument("-o", "--output", required=True)
    a = ap.parse_args()

    tech = kdb.Technology()
    tech.load(a.lyt)
    opts = tech.load_layout_options
    cfg = opts.lefdef_config
    cfg.read_lef_with_def = False
    cfg.lef_files = a.lef
    cfg.map_file = a.map
    cfg.net_property_name = None
    cfg.instance_property_name = None
    cfg.pin_property_name = None
    opts.lefdef_config = cfg
    opts.cell_conflict_resolution = kdb.LoadLayoutOptions.CellConflictResolution.RenameCell

    layout = kdb.Layout()
    layout.read(a.def_file, opts)
    top = layout.cell(a.top)
    if top is None:
        print(f"error: the DEF has no cell '{a.top}'", file=sys.stderr)
        return 1
    # The LEF macros become empty cells for the cell GDS to fill; the via cells keep their shapes.
    for c in layout.each_cell():
        if c.cell_index() != top.cell_index() and not c.name.startswith("VIA"):
            c.clear()
    for g in a.gds:
        layout.read(g, opts)

    out = kdb.Layout()
    out.dbu = layout.dbu
    out.create_cell(a.top).copy_tree(layout.cell(a.top))
    ghosts = [c.name for c in out.each_cell() if c.is_ghost_cell()]
    for g in ghosts:
        print(f"error: cell '{g}' has no GDS", file=sys.stderr)
    if ghosts:
        return 1
    out.write(a.output)
    print(f"klayout-stream-out: {a.output}: {out.cells()} cells")
    return 0


if __name__ == "__main__":
    sys.exit(main())
