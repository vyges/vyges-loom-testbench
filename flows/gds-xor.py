#!/usr/bin/env python3
#
# SPDX-License-Identifier: Apache-2.0
# © 2026 https://vyges.com. All Rights Reserved.
#
# This script is licensed under the Apache License, Version 2.0; see LICENSE and NOTICE.
# http://www.apache.org/licenses/LICENSE-2.0
#
"""Two GDS files, compared as the mask shops compare them: per layer, flattened, XOR.

    gds-xor.py a.gds b.gds [--show N]

Every layer either file uses is compared: the shapes of each top cell flattened through its
hierarchy, XORed, and the labels (string and position) compared as sets. Hierarchy is not
compared, only what it draws: one writer may place a via as a cell and the other as boxes.

Prints one line per layer and a RESULT line. Exit 0 when every layer is identical, 1 when any
differs, 2 when the files cannot be compared (different database units). Needs the KLayout
Python module (`pip install klayout`).
"""
import argparse
import sys

import klayout.db as kdb


def load(path):
    layout = kdb.Layout()
    layout.read(path)
    return layout, layout.top_cell()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("a")
    ap.add_argument("b")
    ap.add_argument("--show", type=int, default=3, help="differences to print per layer (default 3)")
    args = ap.parse_args()

    (la, ta), (lb, tb) = load(args.a), load(args.b)
    if abs(la.dbu - lb.dbu) > 1e-12:
        print(f"RESULT cannot compare: database units {la.dbu} and {lb.dbu}")
        return 2
    layers = {}
    for layout, side in ((la, 0), (lb, 1)):
        for li in layout.layer_indexes():
            info = layout.get_info(li)
            layers.setdefault((info.layer, info.datatype), [None, None])[side] = li

    def region(top, li):
        return kdb.Region(top.begin_shapes_rec(li)) if li is not None else kdb.Region()

    def labels(top, li):
        return sorted((t.string, t.x, t.y) for t in kdb.Texts(top.begin_shapes_rec(li)).each()) if li is not None else []

    bad = 0
    for ld in sorted(layers):
        ia, ib = layers[ld]
        xor = region(ta, ia) ^ region(tb, ib)
        txa, txb = labels(ta, ia), labels(tb, ib)
        same = xor.is_empty() and txa == txb
        bad += not same
        print(f"{ld[0]}/{ld[1]}: {'identical' if same else 'DIFFERS'}  xor polygons {xor.count()}  labels {len(txa)}/{len(txb)}")
        if not same:
            for p in list(xor.each())[: args.show]:
                print(f"    xor at {p.bbox()}")
            sa, sb = set(txa), set(txb)
            for t in sorted(sa - sb)[: args.show]:
                print(f"    label only in {args.a}: {t}")
            for t in sorted(sb - sa)[: args.show]:
                print(f"    label only in {args.b}: {t}")
    print(f"RESULT {'IDENTICAL' if bad == 0 else f'{bad} of {len(layers)} layers differ'} ({len(layers)} layers)")
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
