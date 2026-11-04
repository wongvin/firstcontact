#!/usr/bin/env python3
"""Resolve nets and component values from a KiCad `.kicad_sch`.

Written for #268, where the battery divider had to be established from the
design source rather than from a schematic PDF. Reading the PDF meant matching
component values to symbols by their position on the page, and that produced two
wrong conclusions: `P0.17` was taken for a charge-status readback because its net
is named `~{CHG}`, when it lands on the charger's `PRETERM` input; and `R17` was
read as 510k from an archive that turned out to hold the *previous* board
revision. See zephyr/sophon/hw/nrf52840/HARDWARE.md.

Usage:
    kicad-netlist.py <file.kicad_sch> [filter ...]
    kicad-netlist.py <file.kicad_sch> --values [filter ...]
    kicad-netlist.py <file.kicad_sch> --check-pcb <file.kicad_pcb>

With no filter, prints everything. Filters ignore case, and are EXACT unless
they end in `*` or `=`:

  * `R1` matches only what is named exactly that: in a net query, a net label,
    a reference (every net that part is on), or one pin written "R1 pin 2"; in
    --values, the reference;
  * `R1*` matches anything containing "R1" -- R1, R10, VR1 -- anywhere in a
    net's labels and its "REF pin N [name]" members, or in a reference.

    `U3 pin *` lists every net U3 is on (the same as `U3`). The `*` works
    only at the end: `U8*K7` is an exact filter that matches nothing.

  * `VBUS=` searches PIN NAMES only (the part in brackets in the output), and
    `[` / `]` anchor the start / end of the name, as they are printed:

        [VBUS]=   the pin name is exactly VBUS
        [VBUS=    starts with VBUS (also VBUSOUT)
        VBUS]=    ends with VBUS (also A4/B9/VBUS)
        VBUS=     contains VBUS

    In --values an `=` filter matches nothing: a part has no pin name. See
    SKILL.md for results on a real design.

Quote a filter with `*`, or the shell may expand it against file names:

    kicad-netlist.py board.kicad_sch P0.17 'AIN7*' "U2 pin 5"
    kicad-netlist.py board.kicad_sch --values R16 R17 'U*'

--values prints one row per placed part -- reference, `Value` field, footprint
(`library:name`) -- then a count. Its filters match the REFERENCE only: `R1` is
R1 alone, `'R1*'` adds R10-R19 and VR1. Rows sort as text (R10 before R2). A
multi-unit part prints once, and power symbols and flags (`#PWR`, `#FLG`) are
left out. For example:

    $ kicad-netlist.py board.kicad_sch --values 'R1*' U3 J1
             J1  USB_C_Receptacle         Connector_USB:USB_C_Receptacle_GCT_USB4105
             R1  10k                      Resistor_SMD:R_0402_1005Metric
            R10  100k                     Resistor_SMD:R_0402_1005Metric
       R11(DNP)  0R                       Resistor_SMD:R_0402_1005Metric
             U3  STM32G031K8T6            Package_QFP:LQFP-32_7x7mm_P0.8mm
    5 component(s)

The `Value` field is whatever the designer typed: a part number, a resistance,
or nothing useful. Read the footprint before naming a part's role.

Give it the ROOT sheet of a multi-sheet design and it loads every sub-sheet
(#384, for the XIAO nRF54LM20A). Connectivity follows KiCad's scoping:

  * local labels join nets within their own sheet only;
  * global labels, and global power symbols, join nets across all sheets;
  * a hierarchical label joins the matching sheet pin on its parent sheet.

Power symbols name their net by `Value` (`VSYS_3V3`, `GND`, ...) rather than
appearing as `#PWRnn` parts; `#FLG` power flags are ignored. Multi-unit symbols
(the nRF54LM20A, U8, is six units) attach each pin to its own unit's placement.
A part marked Do Not Populate is flagged `(DNP)` -- after each of its pins in a
net, after its reference in --values: it is drawn, and on the PCB, but not
fitted. The flag is not part of any name a filter is compared with.

--check-pcb compares the result with the nets the PCB assigns to every pad: for
each pair of pads, does the schematic put them on one net exactly when the PCB
does? It is the independent check this script is validated against.

WHAT THIS DOES NOT DO. It is deliberately small:

  * no buses or bus entries;
  * no no-connect flags, so an intentionally unconnected pin looks like any
    other single-pin net;
  * a sheet used more than once (a repeated instance) is read once, with the
    references its symbols carry.

Nets are formed by union-find over wire endpoints, then merged across
same-named labels. A label, pin, wire end or junction lying anywhere on a wire
segment joins that wire, as in KiCad. Pin positions come from the `lib_symbols`
block embedded in each sheet, transformed by each instance's `at`/`mirror`.

Note the coordinate quirk: library pin Y is up while sheet Y is down, so a pin's
absolute position is `origin + rotate((px, -py), rot)`.

Validate any change against a net whose answer is already known -- for this
board, `VBAT - R16 - AIN7 - R17 - P0.14` from zephyr/sophon/hw/nrf52840/HARDWARE.md.

The schematics this parses may be licensed; Seeed's XIAO designs are CC BY-SA
4.0. This script is ours, but its output is a derivative of whatever it is run
on, which is why no generated netlist is committed alongside it.
"""

import contextlib
import itertools
import math
import os
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
            # Atoms that are not numbers are skipped: an `at` node carries a
            # rotation that may be absent, and `xy` carries only coordinates.
            with contextlib.suppress(ValueError):
                out.append(float(c[1]))
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


def is_dnp(symbol):
    flag = kids(symbol, "dnp")
    return bool(flag) and val(flag[0]) != "no"


def dnp_refs(path):
    return {
        props["Reference"]
        for _, root, _ in load_sheets(path)
        for sym, _, props in placed_symbols(root)
        if is_dnp(sym)
    }


def transform(px, py, ox, oy, rot, mirror):
    """A library pin's position on the sheet.

    Library Y is up while sheet Y is down. KiCad then ROTATES the symbol
    counter-clockwise as drawn -- the negative angle of the usual matrix in
    Y-down coordinates -- and MIRRORS it afterwards. Pinned down in #384 by
    trying all four sign/order combinations against both XIAO PCBs: only this
    one gives zero disagreements on both. The earlier version (positive angle,
    mirror first) was right only for parts that were upright, or rotated but
    not mirrored the other way, which is how it passed on the divider net.
    """
    x, y = px, -py
    r = math.radians(-rot)
    x, y = x * math.cos(r) - y * math.sin(r), x * math.sin(r) + y * math.cos(r)
    if mirror == "x":
        y = -y
    if mirror == "y":
        x = -x
    return round(ox + x, 3), round(oy + y, 3)


def xy(node):
    return tuple(round(v, 3) for v in nums(node, 1, 2))


def lib_tables(root):
    """{lib_id: {unit: [(x, y, name, number)]}} and the set of power lib_ids.

    A library symbol's pins live in sub-symbols named `<name>_<unit>_<style>`;
    unit 0 is common to every unit. Only body style 0/1 is kept (De Morgan
    alternates would double-count pins).
    """
    pins, power = defaultdict(lambda: defaultdict(list)), set()
    for block in kids(root, "lib_symbols"):
        for sym in kids(block, "symbol"):
            if kids(sym, "power"):
                power.add(val(sym))
            for sub in kids(sym, "symbol"):
                m = re.search(r"_(\d+)_(\d+)$", val(sub) or "")
                unit, style = (int(m.group(1)), int(m.group(2))) if m else (0, 1)
                if style > 1:
                    continue
                for pin in kids(sub, "pin"):
                    at = kids(pin, "at")
                    if not at:
                        continue
                    x, y = nums(at[0])[:2]
                    nm, nu = kids(pin, "name"), kids(pin, "number")
                    pins[val(sym)][unit].append(
                        (x, y, val(nm[0]) if nm else "?", val(nu[0]) if nu else "?")
                    )
    return pins, power


def load_sheets(path):
    """Yield (sheet_path, root, [(sub_sheet_path, {pin_name: coord})]) for a
    design, depth first from the root file. A design with no `sheet` entries is
    just its one file, as before #384."""
    base = os.path.dirname(os.path.abspath(path))
    seen = set()

    def walk(fname, spath):
        with open(os.path.join(base, fname), encoding="utf-8", errors="replace") as fh:
            root = parse(tokenize(fh.read()))[0]
        children = []
        for i, sh in enumerate(kids(root, "sheet")):
            props = properties(sh)
            sub = props.get("Sheetfile") or props.get("Sheet file")
            if not sub:
                continue
            child = f"{spath}/{props.get('Sheetname') or props.get('Sheet name') or i}"
            sheet_pins = {
                val(pn): xy(kids(pn, "at")[0]) for pn in kids(sh, "pin") if kids(pn, "at")
            }
            children.append((child, sheet_pins))
            if sub not in seen:
                seen.add(sub)
                yield from walk(sub, child)
        yield spath, root, children

    yield from walk(os.path.basename(path), "")


def on_segment(p, a, b, eps=1e-3):
    (px, py), (ax, ay), (bx, by) = p, a, b
    if abs((bx - ax) * (py - ay) - (by - ay) * (px - ax)) > eps * max(
        1.0, abs(bx - ax) + abs(by - ay)
    ):
        return False
    return (
        min(ax, bx) - eps <= px <= max(ax, bx) + eps
        and min(ay, by) - eps <= py <= max(ay, by) + eps
    )


def build_nets(path):
    """Returns {net_key: {'pins': [(ref, num, name)], 'labels': [str]}} for the
    whole design rooted at `path`."""
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

    pins_at = defaultdict(list)  # (sheet, coord) -> [(ref, num, name)]
    names_at = defaultdict(list)  # (sheet, coord) -> [label text]
    named = {}  # scoped name key -> first node carrying it
    sheet_pin_links = []  # (parent sheet, coord, child sheet, pin name)

    def name_node(node, key, text):
        names_at[node].append(text)
        if key in named:
            union(named[key], node)
        else:
            named[key] = node

    for spath, root, children in load_sheets(path):
        lib_pins, power = lib_tables(root)
        points = []

        for sym, lib_id, props in placed_symbols(root):
            ref = props["Reference"]
            if ref.startswith("#FLG"):
                continue
            at = kids(sym, "at")
            if not at:
                continue
            a = nums(at[0], 1, 3)
            ox, oy = a[0], a[1]
            rot = a[2] if len(a) > 2 else 0
            mir = kids(sym, "mirror")
            unit_node = kids(sym, "unit")
            unit = int(val(unit_node[0])) if unit_node else 1
            units = lib_pins.get(lib_id, {})
            for px, py, pname, pnum in units.get(0, []) + units.get(unit, []):
                coord = transform(px, py, ox, oy, rot, val(mir[0]) if mir else None)
                node = (spath, coord)
                points.append(coord)
                if lib_id in power or ref.startswith("#PWR"):
                    # A power symbol is a global net named by its Value.
                    name_node(node, ("G", props.get("Value", ref)), props.get("Value", ref))
                else:
                    pins_at[node].append((ref, pnum, pname))

        for kind, scope in (("label", "L"), ("global_label", "G"), ("hierarchical_label", "H")):
            for lab in kids(root, kind):
                at = kids(lab, "at")
                if not at:
                    continue
                coord = xy(at[0])
                points.append(coord)
                key = ("G", val(lab)) if scope == "G" else (scope, spath, val(lab))
                name_node((spath, coord), key, val(lab))

        for junc in kids(root, "junction"):
            if kids(junc, "at"):
                points.append(xy(kids(junc, "at")[0]))

        segments = []
        for wire in kids(root, "wire"):
            for pts in kids(wire, "pts"):
                ends = [xy(pt) for pt in kids(pts, "xy")]
                for a, b in itertools.pairwise(ends):
                    union((spath, a), (spath, b))
                    segments.append((a, b))
                    points += [a, b]

        # Anything touching a wire anywhere along it joins that wire.
        for pt in set(points):
            for a, b in segments:
                if pt != a and pt != b and on_segment(pt, a, b):
                    union((spath, pt), (spath, a))

        for child, sheet_pins in children:
            for pname, coord in sheet_pins.items():
                sheet_pin_links.append((spath, coord, child, pname))

    for spath, coord, child, pname in sheet_pin_links:
        key = ("H", child, pname)
        if key in named:
            union((spath, coord), named[key])

    nets = defaultdict(lambda: {"pins": [], "labels": []})
    for node, pins in pins_at.items():
        nets[find(node)]["pins"] += pins
    for node, names in names_at.items():
        nets[find(node)]["labels"] += names
    return nets


# --- PCB cross-check ------------------------------------------------------


def pcb_pad_nets(path):
    """{(ref, pad): net name} for every pad the PCB connects to a named net."""
    with open(path, encoding="utf-8", errors="replace") as fh:
        root = parse(tokenize(fh.read()))[0]
    out = {}
    for fp in kids(root, "footprint"):
        props = properties(fp)
        ref = props.get("Reference")
        if not ref:
            continue
        for pad in kids(fp, "pad"):
            net = kids(pad, "net")
            # KiCad <=9: (net 12 "NAME"); KiCad 10: (net "NAME").
            name = None
            if net:
                strs = [c[1] for c in net[0][1:] if isinstance(c, tuple) and c[0] == "str"]
                name = strs[-1] if strs else None
            if name and not name.startswith("unconnected-"):
                out[(ref, val(pad))] = name
    return out


def check_pcb(sch_path, pcb_path):
    nets = build_nets(sch_path)
    sch = {}
    for key, data in nets.items():
        for ref, num, _ in data["pins"]:
            sch[(ref, num)] = key
    pcb = pcb_pad_nets(pcb_path)
    common = sorted(set(sch) & set(pcb))
    only_pcb = sorted(set(pcb) - set(sch))

    # Group by PCB net; each must map to exactly one schematic net, and the
    # reverse. A split or a merge is a disagreement, reported by its pads.
    by_pcb, by_sch = defaultdict(set), defaultdict(set)
    for pad in common:
        by_pcb[pcb[pad]].add(sch[pad])
        by_sch[sch[pad]].add(pcb[pad])
    split = {n: s for n, s in by_pcb.items() if len(s) > 1}
    merged = {k: s for k, s in by_sch.items() if len(s) > 1}

    print(
        f"pads compared: {len(common)}  (PCB pads with a net: {len(pcb)}, "
        f"not found in schematic: {len(only_pcb)})"
    )
    print(
        f"PCB nets: {len(by_pcb)}  split across schematic nets: {len(split)}  "
        f"schematic nets spanning several PCB nets: {len(merged)}"
    )
    for n, s in sorted(split.items()):
        groups = [sorted(p for p in common if pcb[p] == n and sch[p] == k) for k in s]
        print(
            f"  SPLIT {n}: " + " | ".join(", ".join(f"{r}.{q}" for r, q in g[:6]) for g in groups)
        )
    for s in merged.values():
        print(f"  MERGED schematic net carries PCB nets: {sorted(s)}")
    for ref, pad in only_pcb[:20]:
        print(f"  not in schematic: {ref} pad {pad} ({pcb[(ref, pad)]})")
    return 0 if not split and not merged else 1


# --- output --------------------------------------------------------------


def pin_name_hit(pattern, pin_names):
    """A `=` filter, with the `=` removed, against pin names. `[` anchors the
    start of the name and `]` the end: `[VBUS]` is exactly VBUS, `[VBUS` starts
    with it, `VBUS]` ends with it, and bare `VBUS` contains it."""
    start, end = pattern.startswith("["), pattern.endswith("]")
    core = pattern[1:] if start else pattern
    core = core[:-1] if end and core.endswith("]") else core
    for name in pin_names:
        name = name.lower()
        if start and end:
            hit = name == core
        elif start:
            hit = name.startswith(core)
        elif end:
            hit = name.endswith(core)
        else:
            hit = core in name
        if hit:
            return True
    return False


def matches(names, text, filters, pin_names=()):
    """True if any filter hits; the filter's last character picks the mode. `*`:
    a substring of `text` (`R1*` hits R1, R10 and VR1). `=`: a pin name, see
    pin_name_hit(). Otherwise it must equal one of `names` exactly (`R1` hits
    R1 only). All ignore case. No filters means everything."""
    if not filters:
        return True
    names = {n.lower() for n in names}
    for f in filters:
        f = f.lower()
        if f.endswith("*"):
            if f[:-1] in text.lower():
                return True
        elif f.endswith("="):
            if pin_name_hit(f[:-1], pin_names):
                return True
        elif f in names:
            return True
    return False


def print_nets(path, filters):
    shown, dnp = 0, dnp_refs(path)
    for data in build_nets(path).values():
        if not data["pins"] and not data["labels"]:
            continue
        members = sorted(
            f"{r} pin {n} [{pn}]{' (DNP)' if r in dnp else ''}" for r, n, pn in data["pins"]
        )
        haystack = " ".join(data["labels"] + members)
        # Exact filters name a label, a reference, or one pin as "REF pin N".
        names = set(data["labels"])
        for r, n, _ in data["pins"]:
            names |= {r, f"{r} pin {n}"}
        if not matches(names, haystack, filters, [pn for _, _, pn in data["pins"]]):
            continue
        print(", ".join(sorted(set(data["labels"]))) or "(unnamed net)")
        print("     " + (", ".join(members) or "(no pins)"))
        print()
        shown += 1
    print(f"{shown} net(s)")


def print_values(path, filters):
    """One `REF  VALUE  FOOTPRINT` row per placed part, then a count; see the
    module docstring for an example. Filters match the reference only. A part
    placed as several units yields identical rows, which the set() collapses."""
    rows = []
    for _, root, _ in load_sheets(path):
        for sym, _, props in placed_symbols(root):
            ref = props["Reference"]
            if ref.startswith(("#PWR", "#FLG")):
                continue
            if matches({ref}, ref, filters):
                ref += "(DNP)" if is_dnp(sym) else ""
                rows.append((ref, props.get("Value", ""), props.get("Footprint", "")))
    for ref, value, footprint in sorted(set(rows)):
        print(f"{ref:>11}  {value:<24} {footprint}")
    print(f"{len(set(rows))} component(s)")


def main():
    args = sys.argv[1:]
    if not args:
        sys.exit(
            "usage: kicad-netlist.py <file.kicad_sch> [--values] [filter ...]\n"
            "       kicad-netlist.py <file.kicad_sch> --check-pcb <file.kicad_pcb>"
        )
    path = args.pop(0)
    if "--check-pcb" in args:
        i = args.index("--check-pcb")
        sys.exit(check_pcb(path, args[i + 1]))
    want_values = "--values" in args
    filters = [a for a in args if a != "--values"]
    if want_values:
        print_values(path, filters)
    else:
        print_nets(path, filters)


if __name__ == "__main__":
    main()
