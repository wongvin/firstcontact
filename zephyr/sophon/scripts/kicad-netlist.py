#!/usr/bin/env python3
"""Resolve nets and component values from a KiCad `.kicad_sch`.

Written for #268, where the battery divider had to be established from the
design source rather than from a schematic PDF. Reading the PDF meant matching
component values to symbols by their position on the page, and that produced two
wrong conclusions: `P0.17` was taken for a charge-status readback because its net
is named `~{CHG}`, when it lands on the charger's `PRETERM` input; and `R17` was
read as 510k from an archive that turned out to hold the *previous* board
revision. See ../HARDWARE.md.

Usage:
    kicad-netlist.py <file.kicad_sch> [filter ...]
    kicad-netlist.py <file.kicad_sch> --values [filter ...]

With no filter, prints everything. Filters are case-insensitive substrings,
matched against a net's labels and its "REF pin N" members:

    kicad-netlist.py board.kicad_sch P0.17 P0.13
    kicad-netlist.py board.kicad_sch --values R16 R17 U2

WHAT THIS DOES NOT DO. It is deliberately small, and complete only for a
single-sheet schematic like the XIAO's:

  * no hierarchical sheets -- sheet pins and sub-sheet files are ignored, so a
    multi-sheet design will silently under-report connectivity;
  * no buses or bus entries;
  * no no-connect flags, so an intentionally unconnected pin looks like any
    other single-pin net;
  * power symbols appear as ordinary components (`#PWR`/`#G` references), which
    is why GND shows up as many separate one-pin nets rather than one rail.

Nets are formed by union-find over wire endpoints, then merged across same-named
labels. Pin positions come from the `lib_symbols` block embedded in the
schematic, transformed by each instance's `at`/`mirror`.

Note the coordinate quirk: library pin Y is up while sheet Y is down, so a pin's
absolute position is `origin + rotate((px, -py), rot)`.

Validate any change against a net whose answer is already known -- for this
board, `VBAT - R16 - AIN7 - R17 - P0.14` from HARDWARE.md.

The schematics this parses may be licensed; Seeed's XIAO designs are CC BY-SA
4.0. This script is ours, but its output is a derivative of whatever it is run
on, which is why no generated netlist is committed alongside it.
"""

import math
import re
import sys
from collections import defaultdict


# --- S-expression reader -------------------------------------------------


def tokenize(text):
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if c in "()":
            out.append(c)
            i += 1
        elif c == '"':
            j, buf = i + 1, []
            while j < n:
                if text[j] == "\\":
                    buf.append(text[j + 1])
                    j += 2
                elif text[j] == '"':
                    break
                else:
                    buf.append(text[j])
                    j += 1
            out.append(("str", "".join(buf)))
            i = j + 1
        elif c.isspace():
            i += 1
        else:
            j = i
            while j < n and not text[j].isspace() and text[j] not in '()"':
                j += 1
            out.append(("atom", text[i:j]))
            i = j
    return out


def parse(tokens):
    def build(idx):
        node = []
        while idx < len(tokens):
            tok = tokens[idx]
            if tok == "(":
                sub, idx = build(idx + 1)
                node.append(sub)
            elif tok == ")":
                return node, idx + 1
            else:
                node.append(tok)
                idx += 1
        return node, idx

    out, i = [], 0
    while i < len(tokens):
        if tokens[i] == "(":
            sub, i = build(i + 1)
            out.append(sub)
        else:
            i += 1
    return out


def head(node):
    return node[0][1] if node and isinstance(node[0], tuple) else None


def kids(node, key):
    return [c for c in node if isinstance(c, list) and head(c) == key]


def val(node, index=1):
    return node[index][1] if len(node) > index and isinstance(node[index], tuple) else None


def nums(node, start=1, count=3):
    out = []
    for c in node[start : start + count]:
        if isinstance(c, tuple):
            try:
                out.append(float(c[1]))
            except ValueError:
                pass
    return out


# --- schematic model -----------------------------------------------------


def properties(symbol):
    return {val(p): val(p, 2) for p in kids(symbol, "property") if val(p)}


def placed_symbols(root):
    """Every symbol instance that carries a Reference."""
    for sym in kids(root, "symbol"):
        lib = kids(sym, "lib_id")
        if not lib:
            continue
        props = properties(sym)
        if props.get("Reference"):
            yield sym, val(lib[0]), props


def transform(px, py, ox, oy, rot, mirror):
    x, y = px, -py  # library Y is up; sheet Y is down
    if mirror == "x":
        y = -y
    if mirror == "y":
        x = -x
    r = math.radians(rot)
    return (
        round(ox + x * math.cos(r) - y * math.sin(r), 3),
        round(oy + x * math.sin(r) + y * math.cos(r), 3),
    )


def build_nets(root):
    """Returns {representative_coord: {'pins': [(ref, num, name)], 'labels': [str]}}."""
    lib_pins = defaultdict(list)
    for block in kids(root, "lib_symbols"):
        for sym in kids(block, "symbol"):
            for unit in kids(sym, "symbol"):
                for pin in kids(unit, "pin"):
                    at = kids(pin, "at")
                    if not at:
                        continue
                    x, y = nums(at[0])[:2]
                    nm, nu = kids(pin, "name"), kids(pin, "number")
                    lib_pins[val(sym)].append(
                        (x, y, val(nm[0]) if nm else "?", val(nu[0]) if nu else "?")
                    )

    pins_at = defaultdict(list)
    for sym, lib_id, props in placed_symbols(root):
        at = kids(sym, "at")
        if not at:
            continue
        a = nums(at[0], 1, 3)
        ox, oy = a[0], a[1]
        rot = a[2] if len(a) > 2 else 0
        mir = kids(sym, "mirror")
        for px, py, pname, pnum in lib_pins.get(lib_id, []):
            coord = transform(px, py, ox, oy, rot, val(mir[0]) if mir else None)
            pins_at[coord].append((props["Reference"], pnum, pname))

    edges = []
    for wire in kids(root, "wire"):
        for pts in kids(wire, "pts"):
            xs = [tuple(round(v, 3) for v in nums(p, 1, 2)) for p in kids(pts, "xy")]
            edges += list(zip(xs, xs[1:]))

    labels = defaultdict(list)
    for kind in ("label", "global_label", "hierarchical_label"):
        for lab in kids(root, kind):
            at = kids(lab, "at")
            if at:
                labels[tuple(round(v, 3) for v in nums(at[0], 1, 2))].append(val(lab))

    parent = {}

    def find(a):
        parent.setdefault(a, a)
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    def union(a, b):
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[ra] = rb

    for a, b in edges:
        union(a, b)
    for coord in list(pins_at) + list(labels):
        find(coord)

    # A label name is a net name: two wires carrying it are one net even when
    # they are drawn nowhere near each other.
    by_name = {}
    for coord, names in labels.items():
        for nm in names:
            if nm in by_name:
                union(by_name[nm], coord)
            else:
                by_name[nm] = coord

    nets = defaultdict(lambda: {"pins": [], "labels": []})
    for coord, pins in pins_at.items():
        nets[find(coord)]["pins"] += pins
    for coord, names in labels.items():
        nets[find(coord)]["labels"] += names
    return nets


# --- output --------------------------------------------------------------


def matches(text, filters):
    return not filters or any(f.lower() in text.lower() for f in filters)


def print_nets(root, filters):
    shown = 0
    for data in build_nets(root).values():
        if not data["pins"] and not data["labels"]:
            continue
        members = sorted(f"{r} pin {n} [{pn}]" for r, n, pn in data["pins"])
        haystack = " ".join(data["labels"] + members)
        if not matches(haystack, filters):
            continue
        print(", ".join(sorted(set(data["labels"]))) or "(unnamed net)")
        print("     " + (", ".join(members) or "(no pins)"))
        print()
        shown += 1
    print(f"{shown} net(s)")


def print_values(root, filters):
    rows = []
    for _, _, props in placed_symbols(root):
        ref = props["Reference"]
        if matches(ref, filters):
            rows.append((ref, props.get("Value", ""), props.get("Footprint", "")))
    for ref, value, footprint in sorted(set(rows)):
        print(f"{ref:>6}  {value:<24} {footprint}")
    print(f"{len(set(rows))} component(s)")


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: kicad-netlist.py <file.kicad_sch> [--values] [filter ...]")

    want_values = "--values" in sys.argv
    filters = [a for a in sys.argv[2:] if a != "--values"]
    text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
    root = parse(tokenize(text))[0]

    if want_values:
        print_values(root, filters)
    else:
        print_nets(root, filters)


if __name__ == "__main__":
    main()
