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
    kicad-netlist.py --copper <file.kicad_pcb> [net filter ...]
    kicad-netlist.py --draw <file.kicad_pcb> <out_dir> [ref filter ...]
                     [--credit TEXT] [--name NAME]

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
A part marked Do Not Populate is flagged `(DNP)`: after each of its pins in a
net, and after its reference in --values. It is drawn, and on the PCB, but not
fitted. The mark is KiCad's DNP attribute, or a Value of `DNP` / `DNF`, which
some designs use instead. The flag is not part of any name a filter is compared
with.

--check-pcb compares the result with the nets the PCB assigns to every pad: for
each pair of pads, does the schematic put them on one net exactly when the PCB
does? It is the independent check this script is validated against.

--copper lists, for each PCB net matching the filters (same exact / `*` rules,
against the net's name), its pads, its track count and length, its vias and
its copper zones; then the board's net-less copper: graphics on copper layers,
footprint copper graphics with no pad, and keepout areas. It answers "is
there an antenna in the copper, or only a connector?" (#387) without reading
the file by hand:

    $ kicad-netlist.py --copper board.kicad_pcb 'Net-(ANT*'

--draw writes <out_dir>/<board>-front.svg and -back.svg: the board outline,
every pad in its true shape and side, the silkscreen text at its real size and
angle, and on each pad matching the filters (on the reference, e.g. 'TP*') its
`REF.pad` and net (#387). The back is drawn as seen from the back, as the board
is held. A pad's identity on the drawing is exact; which pad a printed label
belongs to is read by eye from the layout, with the whole board in view.
Rotated and mirrored text was checked against the strokes KiCad plotted in the
XIAO nRF52840's B_Silkscreen Gerber. The drawing derives from the design: each
SVG carries a change note at its foot and in its metadata, and `--credit TEXT`
adds the creator, source and licence there too. Never commit one without it
(SKILL.md § 6). Render to PNG with `qlmanage -t -s 2400 -o <dir> <svg>`.

Why a drawing rather than a distance: a text's position is its anchor, usually
a corner, and labels often sit between pads. On the XIAO nRF52840 the pad
nearest `CLK` is TP1 (GND) and nearest `DIO` is TP2 (RESET), while the labels
belong to TP3 (SWDCLK) and TP5 (SWDIO). Each label sits to the right of its
pad, which the drawing shows at a glance.

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
import html
import itertools
import math
import os
import re
import sys
import textwrap
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
                    # KiCad escapes \n (a line break in silkscreen text) and
                    # \" / \\; anything else stands for itself.
                    buf.append({"n": "\n", "t": "\t"}.get(text[j + 1], text[j + 1]))
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


# Values that designers type to mean "not fitted" instead of setting KiCad's
# DNP attribute; Seeed's XIAO nRF52840 v1.1 marks C40, R8 and U7 only this way.
DNP_VALUES = {"dnp", "dnf"}


def is_dnp(symbol):
    """Not fitted: KiCad's DNP attribute, or a Value of DNP / DNF (#387)."""
    flag = kids(symbol, "dnp")
    if flag and val(flag[0]) != "no":
        return True
    return (properties(symbol).get("Value") or "").strip().lower() in DNP_VALUES


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


# --- drawing: --draw ------------------------------------------------------


def to_board(fx, fy, r, x, y):
    """A footprint-local point in board coordinates (see pcb_pads)."""
    return fx + x * math.cos(r) + y * math.sin(r), fy - x * math.sin(r) + y * math.cos(r)


def arc_points(a, m, b, steps=24):
    """Points along the circular arc from a through m to b."""
    (ax, ay), (mx, my), (bx, by) = a, m, b
    d = 2 * (ax * (my - by) + mx * (by - ay) + bx * (ay - my))
    if abs(d) < 1e-9:
        return [a, b]
    ux = (
        (ax**2 + ay**2) * (my - by) + (mx**2 + my**2) * (by - ay) + (bx**2 + by**2) * (ay - my)
    ) / d
    uy = (
        (ax**2 + ay**2) * (bx - mx) + (mx**2 + my**2) * (ax - bx) + (bx**2 + by**2) * (mx - ax)
    ) / d
    rad = math.hypot(ax - ux, ay - uy)
    t0, tm, t1 = (math.atan2(p[1] - uy, p[0] - ux) for p in (a, m, b))

    def ccw(x, y):  # angle from x to y, counter-clockwise in these coordinates
        return (y - x) % (2 * math.pi)

    span = ccw(t0, t1) if ccw(t0, tm) < ccw(t0, t1) else ccw(t0, t1) - 2 * math.pi
    return [
        (ux + rad * math.cos(t0 + span * i / steps), uy + rad * math.sin(t0 + span * i / steps))
        for i in range(steps + 1)
    ]


def outline_paths(root):
    """The board outline (Edge.Cuts) as polylines, board-level and in footprints."""

    def on_edge(n):
        return any(
            c[1] == "Edge.Cuts" for lay in kids(n, "layer") for c in lay[1:] if isinstance(c, tuple)
        )

    def pts(n, k):
        return tuple(nums(kids(n, k)[0], 1, 2)) if kids(n, k) else None

    owners = [(root, lambda x, y: (x, y), "gr_")]
    for fp in kids(root, "footprint"):
        a = nums(kids(fp, "at")[0], 1, 3) if kids(fp, "at") else [0, 0]
        fx, fy, r = a[0], a[1], math.radians(a[2] if len(a) > 2 else 0)
        owners.append((fp, lambda x, y, fx=fx, fy=fy, r=r: to_board(fx, fy, r, x, y), "fp_"))
    paths = []
    for node, xf, pre in owners:
        for g in kids(node, pre + "line"):
            if on_edge(g):
                paths.append([xf(*pts(g, "start")), xf(*pts(g, "end"))])
        for g in kids(node, pre + "arc"):
            if on_edge(g) and pts(g, "mid"):
                paths.append(
                    [xf(*p) for p in arc_points(pts(g, "start"), pts(g, "mid"), pts(g, "end"))]
                )
        for g in kids(node, pre + "rect"):
            if on_edge(g):
                (x1, y1), (x2, y2) = pts(g, "start"), pts(g, "end")
                paths.append([xf(*p) for p in ((x1, y1), (x2, y1), (x2, y2), (x1, y2), (x1, y1))])
        for g in kids(node, pre + "circle"):
            if on_edge(g):
                (cx, cy), (ex, ey) = pts(g, "center"), pts(g, "end")
                rr = math.hypot(ex - cx, ey - cy)
                paths.append(
                    [
                        xf(
                            cx + rr * math.cos(t / 24 * 2 * math.pi),
                            cy + rr * math.sin(t / 24 * 2 * math.pi),
                        )
                        for t in range(25)
                    ]
                )
        for g in kids(node, pre + "poly"):
            if on_edge(g) and kids(g, "pts"):
                ring = [xf(*nums(p, 1, 2)) for p in kids(kids(g, "pts")[0], "xy")]
                paths.append([*ring, ring[0]])
    return paths


def svg_text(
    x,
    y,
    lines,
    size,
    angle,
    anchor="middle",
    baseline="central",
    color="#000",
    weight="normal",
    flip=False,
):
    tsp = "".join(
        f'<tspan x="0" dy="{0 if i == 0 else size * 1.15:.3f}">{html.escape(t)}</tspan>'
        for i, t in enumerate(lines)
    )
    return (
        f'<text transform="translate({x:.3f} {y:.3f}) rotate({-angle:.1f})'
        f'{" scale(-1 1)" if flip else ""}" font-size="{size:.3f}" '
        f'font-family="Helvetica, Arial, sans-serif" text-anchor="{anchor}" '
        f'dominant-baseline="{baseline}" fill="{color}" font-weight="{weight}">{tsp}</text>'
    )


def draw_board(pcb_path, out_dir, filters, credit=None, name=None):
    """Write <out_dir>/<board>-front.svg and -back.svg (see the module docstring)."""
    with open(pcb_path, encoding="utf-8", errors="replace") as fh:
        root = parse(tokenize(fh.read()))[0]
    outline = outline_paths(root)
    xs = [p[0] for path in outline for p in path] or [0]
    ys = [p[1] for path in outline for p in path] or [0]
    x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
    pads = list(pcb_pads(root))
    shapes = {}
    for fp in kids(root, "footprint"):
        ref = properties(fp).get("Reference")
        for pad in kids(fp, "pad"):
            size = nums(kids(pad, "size")[0], 1, 2) if kids(pad, "size") else [0.3, 0.3]
            at = nums(kids(pad, "at")[0], 1, 3) if kids(pad, "at") else [0, 0]
            shapes[(ref, val(pad))] = (val(pad, 3) or "rect", size, at[2] if len(at) > 2 else 0)
    stem = os.path.splitext(os.path.basename(pcb_path))[0].replace(" ", "_")
    stem += f"-{name}" if name else ""
    os.makedirs(out_dir, exist_ok=True)
    written = []
    for side, name in (("F", "front"), ("B", "back")):

        def v(x, y, side=side):  # board -> view: the back is seen from the back, mirrored
            return (x0 + x1 - x, y) if side == "B" else (x, y)

        m = 2.0
        # Every drawing carries its own credit and change note, so the file can
        # stand alone once shared (CC BY-SA 4.0 § 3; SKILL.md § 6): in a footer
        # below the board, and as metadata.
        notes = [credit] if credit else []
        notes.append(
            f"Rendered from {os.path.basename(pcb_path)} by kicad-netlist.py --draw: "
            "outline, pads and silkscreen redrawn, pads labelled with reference and net."
        )
        foot = [ln for n in notes for ln in textwrap.wrap(n, 90)]
        legend = textwrap.wrap(
            f"{name.upper()}, seen from the {name}. Purple: silkscreen. "
            "Pads: red front, blue back, gold through.",
            60,
        )
        head_h, foot_h = 0.75 * len(legend) + 0.4, 0.52 * len(foot) + 0.6
        # A square canvas: Quick Look's renderer (qlmanage) crops to a square.
        span = max(x1 - x0 + 2 * m, y1 - y0 + 2 * m + head_h + foot_h)
        left, top = (x0 + x1 - span) / 2, y0 - m - head_h
        out = [
            f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{left:.3f} {top:.3f} '
            f'{span:.3f} {span:.3f}" width="{span * 60:.0f}" height="{span * 60:.0f}">',
            f'<rect x="{left:.3f}" y="{top:.3f}" width="{span:.3f}" height="{span:.3f}" '
            f'fill="#fff"/>',
        ]
        for path in outline:
            d = " ".join(
                f"{'M' if i == 0 else 'L'}{v(*p)[0]:.3f},{v(*p)[1]:.3f}" for i, p in enumerate(path)
            )
            out.append(f'<path d="{d}" fill="none" stroke="#000" stroke-width="0.1"/>')
        labels, picked, placed = [], {}, []
        for ref, pad, x, y, layers, net in pads:
            if not any(lay in (f"{side}.Cu", "*.Cu") for lay in layers):
                continue
            kind, (w, h), ang = shapes.get((ref, pad), ("rect", (0.3, 0.3), 0))
            vx, vy = v(x, y)
            vang = -ang if side == "B" else ang
            colour = "#d4a017" if "*.Cu" in layers else ("#c0392b" if side == "F" else "#2471a3")
            rx = (
                min(w, h) / 2
                if kind in ("circle", "oval")
                else min(w, h) * 0.25
                if kind == "roundrect"
                else 0
            )
            out.append(
                f'<rect x="{-w / 2:.3f}" y="{-h / 2:.3f}" width="{w:.3f}" height="{h:.3f}" '
                f'rx="{rx:.3f}" '
                f'transform="translate({vx:.3f} {vy:.3f}) rotate({-vang:.1f})" fill="{colour}" '
                f'fill-opacity="0.55"/>'
            )
            if matches({ref}, ref, filters):
                net_txt = (net or "(no net)").lstrip("/").replace("{slash}", "/")
                picked.setdefault(ref, []).append((pad, vx, vy, max(w, h), net_txt))
        # Label the picked parts. Pads far enough apart get a label each (a test
        # pad, a header). A small part's pads are too close for that (an 0201's
        # are 0.47 mm apart), so it gets one label beside it, listing each pad's
        # net, with a leader line and a ring that makes it findable on a dense
        # board.
        rings = []  # (ref, group, cx, cy, radius) for small parts, in a first pass
        for ref, group in sorted(picked.items()):
            gap = min(
                (math.hypot(a[1] - b[1], a[2] - b[2]) for a in group for b in group if a is not b),
                default=math.inf,
            )
            if gap >= 1.5:
                for pad, vx, vy, _, net_txt in group:
                    labels.append(
                        svg_text(vx, vy, [f"{ref}.{pad}", net_txt], 0.28, 0, weight="bold")
                    )
                continue
            cx = sum(g[1] for g in group) / len(group)
            cy = sum(g[2] for g in group) / len(group)
            ring = max(math.hypot(g[1] - cx, g[2] - cy) + g[3] / 2 for g in group) + 0.25
            rings.append((ref, group, cx, cy, ring))
            placed.append((cx - ring, cy - ring, 2 * ring, 2 * ring))
        # Second pass: each label goes up and to the right of its ring, moved
        # down until it is clear of every ring and every label already placed.
        # Text boxes are estimated (0.3 mm text, ~0.6 em per character).
        for ref, group, cx, cy, ring in rings:
            lines = [ref] + [f"{pad}: {n}" for pad, _, _, _, n in sorted(group)]
            bw, bh = max(len(t) for t in lines) * 0.3 * 0.62 + 0.2, len(lines) * 0.345 + 0.1
            lx, ly = cx + ring + 1.2, cy - ring - 0.6
            while any(
                lx < ox + ow and ox < lx + bw and ly - 0.35 < oy + oh and oy < ly - 0.35 + bh
                for ox, oy, ow, oh in placed
            ):
                ly += 0.2
            placed.append((lx, ly - 0.35, bw, bh))
            labels.append(
                f'<circle cx="{cx:.3f}" cy="{cy:.3f}" r="{ring:.3f}" fill="none" '
                f'stroke="#e67e22" stroke-width="0.12"/>'
                f'<line x1="{cx + ring * 0.7:.3f}" y1="{cy - ring * 0.7:.3f}" x2="{lx:.3f}" '
                f'y2="{ly:.3f}" stroke="#e67e22" stroke-width="0.06"/>'
                + svg_text(lx + 0.1, ly, lines, 0.3, 0, "start", "text-after-edge", weight="bold")
            )
        for t in kids(root, "gr_text"):
            layer = kids(t, "layer")
            if not layer or val(layer[0]) != f"{side}.SilkS" or not kids(t, "at"):
                continue
            a = nums(kids(t, "at")[0], 1, 3)
            eff = kids(t, "effects")
            font = kids(eff[0], "font") if eff else []
            size = (
                nums(kids(font[0], "size")[0], 1, 2)[0] if font and kids(font[0], "size") else 1.0
            )
            just = [
                c[1]
                for j in (kids(eff[0], "justify") if eff else [])
                for c in j[1:]
                if isinstance(c, tuple)
            ]
            anchor = "start" if "left" in just else "end" if "right" in just else "middle"
            base = (
                "text-before-edge"
                if "top" in just
                else "text-after-edge"
                if "bottom" in just
                else "central"
            )
            vx, vy = v(a[0], a[1])
            lines = [ln for ln in (val(t) or "").split("\n") if ln.strip()]
            # KiCad applies `mirror` in the text's own frame, before rotating, so a
            # mirrored text also reads the other way along its angle. Checked
            # against the plotted strokes of the XIAO nRF52840's B_Silkscreen
            # Gerber (#387). Seen from the back, a mirrored back-side text reads
            # normally at the opposite angle; any other text is drawn flipped, as
            # it would appear from that side.
            rot = a[2] if len(a) > 2 else 0
            mirrored = "mirror" in just
            angle, flip = (-rot, not mirrored) if side == "B" else (rot, mirrored)
            out.append(
                svg_text(
                    vx, vy, lines, size * 1.35, angle, anchor, base, color="#7d3c98", flip=flip
                )
            )
        out += labels
        out.append(svg_text(left + 0.3, top + 0.9, legend, 0.6, 0, "start", "auto"))
        out.append(f"<metadata>{html.escape(' '.join(notes))}</metadata>")
        out.append(
            svg_text(left + 0.3, y1 + m + 0.45, foot, 0.45, 0, "start", "auto", color="#444")
        )
        out.append("</svg>")
        path = os.path.join(out_dir, f"{stem}-{name}.svg")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("\n".join(out))
        written.append(path)
    for path in written:
        print(path)
    if not credit:
        print("No --credit given: keep these out of the repo (licence; see SKILL.md § 6).")


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


def pcb_net_name(node, numbered):
    """A pad's or track's net name. KiCad 10 writes (net "NAME"); earlier
    versions (net 12 "NAME") on pads but a bare (net 12) on tracks, named by
    the top-level (net 12 "NAME") table passed in as `numbered`."""
    net = kids(node, "net")
    if not net:
        return None
    strs = [c[1] for c in net[0][1:] if isinstance(c, tuple) and c[0] == "str"]
    return strs[-1] if strs else numbered.get(val(net[0]))


def pcb_pads(root):
    """Yield (ref, pad, x, y, layers, net) for every pad, in board coordinates.

    A pad's `at` is relative to its footprint, rotated by the footprint's
    angle counter-clockwise as seen, in Y-down coordinates. Pinned down in #387
    against the XIAO nRF52840 v1.1's copper Gerbers, which flash every pad at
    its plotted position: all 250 pads, 213 of them on rotated parts, land on
    their flash to within 0.000 mm. Back-side footprints need no mirroring:
    KiCad stores their pads already flipped.
    """
    numbered = {val(n): val(n, 2) for n in kids(root, "net") if val(n, 2) is not None}
    for fp in kids(root, "footprint"):
        ref = properties(fp).get("Reference")
        at = kids(fp, "at")
        if not ref or not at:
            continue
        a = nums(at[0], 1, 3)
        fx, fy, r = a[0], a[1], math.radians(a[2] if len(a) > 2 else 0)
        for pad in kids(fp, "pad"):
            pat = kids(pad, "at")
            if not pat:
                continue
            px, py = nums(pat[0], 1, 2)
            x = fx + px * math.cos(r) + py * math.sin(r)
            y = fy - px * math.sin(r) + py * math.cos(r)
            layers = [c[1] for lay in kids(pad, "layers") for c in lay[1:] if isinstance(c, tuple)]
            yield ref, val(pad), x, y, layers, pcb_net_name(pad, numbered)


def on_copper(node):
    """True if a graphic item is drawn on a copper layer."""
    return any(
        c[1].endswith(".Cu") for lay in kids(node, "layer") for c in lay[1:] if isinstance(c, tuple)
    )


def print_copper(pcb_path, filters):
    with open(pcb_path, encoding="utf-8", errors="replace") as fh:
        root = parse(tokenize(fh.read()))[0]
    numbered = {val(n): val(n, 2) for n in kids(root, "net") if val(n, 2) is not None}
    nets = defaultdict(lambda: {"pads": [], "tracks": 0, "length": 0.0, "vias": 0, "zones": []})
    for ref, pad, _, _, _, net in pcb_pads(root):
        if net:
            nets[net]["pads"].append(f"{ref}.{pad}")
    for kind in ("segment", "arc"):
        for t in kids(root, kind):
            net = pcb_net_name(t, numbered)
            a, b = kids(t, "start"), kids(t, "end")
            if net and a and b:
                (x1, y1), (x2, y2) = nums(a[0], 1, 2), nums(b[0], 1, 2)
                nets[net]["tracks"] += 1
                nets[net]["length"] += math.hypot(x2 - x1, y2 - y1)  # arcs as chords
    for v in kids(root, "via"):
        net = pcb_net_name(v, numbered)
        if net:
            nets[net]["vias"] += 1
    keepouts = 0
    for z in kids(root, "zone"):
        if kids(z, "keepout"):
            keepouts += 1
            continue
        net = pcb_net_name(z, numbered)
        layers = [
            c[1]
            for k in ("layer", "layers")
            for n in kids(z, k)
            for c in n[1:]
            if isinstance(c, tuple)
        ]
        if net:
            nets[net]["zones"].append(
                f"{val(kids(z, 'name')[0]) if kids(z, 'name') else '-'} on {'/'.join(layers)}"
            )
    shown = 0
    for net in sorted(nets):
        if net.startswith("unconnected-") or not matches({net}, net, filters):
            continue
        d = nets[net]
        print(f"{net}\n     pads: {', '.join(sorted(d['pads'])) or '(none)'}")
        print(
            f"     tracks: {d['tracks']} ({d['length']:.2f} mm), vias: {d['vias']}, "
            f"zones: {'; '.join(d['zones']) or '(none)'}"
        )
        shown += 1
    graphics = [
        g
        for k in ("gr_line", "gr_arc", "gr_poly", "gr_rect", "gr_circle", "gr_curve")
        for g in kids(root, k)
        if on_copper(g)
    ]
    fp_graphics = [
        (properties(fp).get("Reference"), g)
        for fp in kids(root, "footprint")
        for k in ("fp_line", "fp_arc", "fp_poly", "fp_rect", "fp_circle", "fp_curve")
        for g in kids(fp, k)
        if on_copper(g)
    ]
    print(f"{shown} net(s)")
    print(
        f"board copper graphics with no net: {len(graphics)}; footprint copper graphics: "
        f"{len(fp_graphics)}"
        + (f" ({', '.join(sorted({r for r, _ in fp_graphics}))})" if fp_graphics else "")
        + f"; keepout areas: {keepouts}"
    )


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
            "       kicad-netlist.py <file.kicad_sch> --check-pcb <file.kicad_pcb>\n"
            "       kicad-netlist.py --copper <file.kicad_pcb> [net filter ...]\n"
            "       kicad-netlist.py --draw <file.kicad_pcb> <out_dir> [ref filter ...]"
            " [--credit TEXT] [--name NAME]"
        )
    path = args.pop(0)
    if path == "--copper":
        print_copper(args[0], args[1:])
        return
    if path == "--draw":
        opts = {}
        for flag in ("--credit", "--name"):
            if flag in args:
                i = args.index(flag)
                opts[flag[2:]] = args[i + 1]
                del args[i : i + 2]
        draw_board(args[0], args[1], args[2:], **opts)
        return
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
