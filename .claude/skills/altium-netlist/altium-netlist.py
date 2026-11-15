#!/usr/bin/env python3
"""Prepare an Altium project for KiCad's importer, and check what it produced.

Written for #395. KiCad 10 imports an Altium project into a KiCad one (File >
Import Non-KiCad Project), after which kicad-netlist.py answers every net and
value question, validated by its --check-pcb. That import has to be run in the
KiCad GUI: kicad-cli imports an Altium board but not an Altium schematic. This
script does the parts around it, on Windows and macOS alike, with Python's
standard library only.

Usage:
    altium-netlist.py prepare <project.PrjPcb | design.zip | folder>
                      --out DIR [--project NAME]
    altium-netlist.py check-import <folder KiCad imported into>
    altium-netlist.py check-variants <project.PrjPcb> <root.kicad_sch>

prepare copies the design into DIR, which must be new or empty and outside
the source's folder (the session's scratchpad), and makes the copy importable.
It only reads the source: every change below is made to the copy, and KiCad
imports from the copy, so even its lock files land there.

  * a .zip is extracted first (into <out>/source);
  * the copy of the .PrjPcb has its library documents (.SchLib, .PcbLib,
    .IntLib, .LibPkg) removed and its [DocumentN] sections renumbered. A
    library the project lists but that isn't present makes KiCad show an error,
    and on cyber60-mx it left the generated schematic sheets unsaved (#395);
  * a listed document that isn't present is removed from the copy too, and
    reported. A missing .SchDoc or .PcbDoc stops it: the import would be
    incomplete;
  * a document outside the project folder (`..\\shared\\x.SchDoc`) is copied
    beside the .PrjPcb and the copy's path rewritten to match.

It prints the SHA-256 of every source file, for the record; each sheet's title,
revision, date and number, with Altium's `=Name` references resolved (KiCad
copies them unresolved, so the imported title blocks can't settle the
revision); and then the full path
of the prepared .PrjPcb and of an empty folder to import into, each on its own
line in the OS's own form, ready to paste into KiCad's file dialogs.

check-import checks the folder KiCad imported into: one .kicad_pro, the root
.kicad_sch named like it, every sub-sheet the sheets reference, and the
.kicad_pcb. KiCad writes each only when its editor is saved, so a missing file
almost always means an editor wasn't saved. Exit 1 if anything is missing.

check-variants compares the not-fitted parts of each Altium variant with what
KiCad's import made of it. Altium ties a variation to its part by the part's
unique ID; the designator written beside it can be stale. On cyber60-mx the
`Tray` variation reads `Designator=CON303` but its ID belongs to CON302, and
KiCad's import marked both parts not fitted. This reads the unique IDs from the
.SchDoc files, resolves each variation to its part, and reports every part on
which the two disagree. Exit 1 on any disagreement. Only `Kind=1` (not fitted)
variations are compared; others are listed as not checked.

An Altium .SchDoc is an OLE compound file (the format of old .doc files) whose
`FileHeader` stream holds the records as `|KEY=value|...` text. cfb_streams()
and sch_records() read just enough of it for the unique IDs and designators.
Not handled: a sheet used more than once (an Altium multi-channel design),
whose parts get designators Altium derives per channel.
"""

import contextlib
import hashlib
import importlib.util
import re
import shutil
import struct
import sys
import zipfile
from pathlib import Path, PureWindowsPath

LIBRARY_EXTS = {".schlib", ".pcblib", ".intlib", ".libpkg"}
DESIGN_EXTS = {".schdoc", ".pcbdoc"}

# --- the .PrjPcb ----------------------------------------------------------


def read_text(path):
    """A .PrjPcb's text and the encoding to write it back in. Altium writes
    UTF-8 with a BOM; older versions wrote the Windows code page."""
    raw = Path(path).read_bytes()
    try:
        return raw.decode("utf-8-sig"), "utf-8-sig" if raw.startswith(b"\xef\xbb\xbf") else "utf-8"
    except UnicodeDecodeError:
        return raw.decode("cp1252", errors="replace"), "cp1252"


def sections(text):
    """[(name, body)] for each `[Section]` of an INI-style file, in order. The
    text before the first section has the name None."""
    out = []
    for part in re.split(r"(?m)^(?=\[)", text):
        m = re.match(r"\[([^\]\r\n]+)\]", part)
        out.append((m.group(1) if m else None, part))
    return out


def ini_value(body, key):
    m = re.search(rf"(?mi)^{re.escape(key)}=(.*?)\r?$", body)
    return m.group(1) if m else None


def documents(text):
    """The DocumentPath of every [DocumentN] section, in order."""
    return [
        ini_value(body, "DocumentPath")
        for name, body in sections(text)
        if name and re.fullmatch(r"Document\d+", name) and ini_value(body, "DocumentPath")
    ]


def doc_parts(doc):
    """An Altium document path (always backslashes) as path parts."""
    return PureWindowsPath(doc).parts


def outside(doc):
    p = PureWindowsPath(doc)
    return p.is_absolute() or bool(p.drive) or ".." in p.parts


# --- prepare --------------------------------------------------------------


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def find_project(folder, name):
    found = sorted(p for p in Path(folder).rglob("*") if p.suffix.lower() == ".prjpcb")
    if name:
        found = [p for p in found if p.stem.lower() == name.lower() or p.name == name]
    if len(found) == 1:
        return found[0]
    if not found:
        sys.exit(f"no .PrjPcb{' named ' + name if name else ''} under {folder}")
    sys.exit(
        "several projects; choose one with --project NAME:\n"
        + "\n".join(f"  {p.relative_to(folder)}" for p in found)
    )


def new_dir(path):
    path = Path(path)
    if path.exists() and any(path.iterdir()):
        sys.exit(f"not empty: {path}")
    path.mkdir(parents=True, exist_ok=True)
    return path


def prepare(source, out, project=None):
    source = Path(source).resolve()
    if not source.exists():
        sys.exit(f"not found: {source}")
    # The source is only ever read. Refuse an output folder inside the
    # source's folder (or the reverse), which would write into it.
    area = source if source.is_dir() else source.parent
    out = Path(out).resolve()
    if out == area or area in out.parents or out in area.parents:
        sys.exit(f"--out must be outside the source's folder:\n  source: {area}\n  out:    {out}")
    out = new_dir(out)
    print(f"Source: {source}")
    if source.suffix.lower() == ".zip":
        print(f"  sha256 {sha256(source)}  {source.name}")
        src_dir = new_dir(out / "source")
        # extractall drops absolute paths and `..` from member names, so an
        # archive can't write outside src_dir.
        with zipfile.ZipFile(source) as zf:
            zf.extractall(src_dir)
        prj = find_project(src_dir, project)
    elif source.is_dir():
        prj = find_project(source, project)
    elif source.suffix.lower() == ".prjpcb":
        prj = source
    else:
        sys.exit(f"not a .PrjPcb, .zip or folder: {source}")

    text, enc = read_text(prj)
    base = prj.parent
    dest = new_dir(out / "altium")
    kicad = new_dir(out / "kicad")

    kept, dropped_libs, missing, moved = [], [], [], []
    parts, n = [], 0
    for name, body in sections(text):
        if name and re.fullmatch(r"Document\d+", name):
            doc = ini_value(body, "DocumentPath")
            if doc is None:
                continue
            ext = PureWindowsPath(doc).suffix.lower()
            if ext in LIBRARY_EXTS:
                dropped_libs.append(doc)
                continue
            src = base.joinpath(*doc_parts(doc))
            if not src.is_file():
                missing.append(doc)
                continue
            target_doc = doc
            if outside(doc):
                target_doc = PureWindowsPath(doc).name
                moved.append((doc, target_doc))
                body = re.sub(
                    r"(?mi)^(DocumentPath=).*?(\r?)$",
                    lambda m, t=target_doc: m.group(1) + t + m.group(2),
                    body,
                    count=1,
                )
            target = dest.joinpath(*doc_parts(target_doc))
            if target.exists():
                sys.exit(f"two documents would land on {target}")
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, target)
            kept.append((doc, src))
            n += 1
            body = re.sub(r"^\[Document\d+\]", f"[Document{n}]", body)
        parts.append(body)

    # Companions Altium keeps beside the project; harmless to KiCad, and kept
    # so the copy reads like the original.
    for comp in (".PrjPcbStructure", ".PrjPcbVariants"):
        p = prj.with_suffix(comp)
        if p.is_file() and not (dest / p.name).exists():
            shutil.copy2(p, dest / p.name)
            kept.append((p.name, p))

    new_prj = dest / prj.name
    new_prj.write_bytes("".join(parts).encode(enc, errors="replace"))

    print(f"  sha256 {sha256(prj)}  {prj.name}")
    for doc, src in kept:
        print(f"  sha256 {sha256(src)}  {doc}")
    if dropped_libs:
        print("Library documents removed from the copy (a missing one breaks the import):")
        for doc in dropped_libs:
            present = base.joinpath(*doc_parts(doc)).is_file()
            print(f"  {doc}{'' if present else '  (not present)'}")
    for doc, new in moved:
        print(f"Outside the project folder, copied beside the .PrjPcb: {doc} -> {new}")
    if missing:
        print("Listed but not present, removed from the copy:")
        for doc in missing:
            print(f"  {doc}")
    lost = [d for d in missing if PureWindowsPath(d).suffix.lower() in DESIGN_EXTS]
    if lost:
        sys.exit(
            "STOP: a schematic or board document is missing, so the import would be "
            "incomplete:\n" + "\n".join(f"  {d}" for d in lost)
        )
    if not any(PureWindowsPath(d).suffix.lower() == ".pcbdoc" for d, _ in kept):
        print(
            "Note: no .PcbDoc in the project, so --check-pcb will have no board to check against."
        )
    schdocs = [src for d, src in kept if src.suffix.lower() == ".schdoc"]
    print_title_blocks(text, schdocs)
    warn_unconverted(text, schdocs)
    print()
    print("Prepared project (select it in KiCad's import dialog):")
    print(str(new_prj))
    print()
    print("Empty folder to import into:")
    print(str(kicad))


# --- check-import ---------------------------------------------------------

SHEETFILE = re.compile(r'\(property\s+"Sheet ?file"\s+"((?:[^"\\]|\\.)*)"', re.I)


def check_import(folder):
    folder = Path(folder)
    pros = sorted(folder.glob("*.kicad_pro"))
    if len(pros) != 1:
        sys.exit(f"expected one .kicad_pro in {folder}, found {len(pros)}")
    stem = pros[0].stem
    problems = []
    print(f"project: {pros[0].name}")

    root = folder / f"{stem}.kicad_sch"
    sheets, missing, todo = [], [], [root.name]
    while todo:
        name = todo.pop(0)
        path = folder / name
        if not path.is_file():
            missing.append(name)
            continue
        sheets.append(name)
        text = path.read_text(encoding="utf-8", errors="replace")
        for sub in SHEETFILE.findall(text):
            sub = sub.replace('\\"', '"')
            if sub not in sheets and sub not in missing and sub not in todo:
                todo.append(sub)
    for name in sheets:
        print(f"  sheet  {name}")
    if missing:
        problems.append(
            "schematic sheets not saved: "
            + ", ".join(missing)
            + ". In the Schematic Editor, choose File > Save, then run this again."
        )

    pcb = folder / f"{stem}.kicad_pcb"
    if pcb.is_file():
        print(f"  board  {pcb.name}")
    else:
        others = sorted(p.name for p in folder.glob("*.kicad_pcb"))
        problems.append(
            f"board not saved: {pcb.name}"
            + (f" (found {', '.join(others)})" if others else "")
            + ". In the PCB Editor, choose File > Save, then run this again."
        )

    for p in problems:
        print("MISSING " + p)
    if problems:
        sys.exit(1)
    print("complete")


# --- reading a .SchDoc ----------------------------------------------------

FREE, END = 0xFFFFFFFF, 0xFFFFFFFE


def cfb_streams(data):
    """{name: bytes} for the streams of an OLE compound file (MS-CFB)."""
    if data[:8] != bytes.fromhex("D0CF11E0A1B11AE1"):
        raise ValueError("not an OLE compound file")
    ssz = 1 << struct.unpack_from("<H", data, 30)[0]
    mssz = 1 << struct.unpack_from("<H", data, 32)[0]
    nfat, dir0, _, mcut, mfat0, nmfat, difat0, ndifat = struct.unpack_from("<8I", data, 44)
    difat = list(struct.unpack_from("<109I", data, 76))
    s = difat0
    for _ in range(ndifat):
        vals = struct.unpack_from(f"<{ssz // 4}I", data, (s + 1) * ssz)
        difat += vals[:-1]
        s = vals[-1]
    fat = []
    for sec in difat[:nfat]:
        fat += struct.unpack_from(f"<{ssz // 4}I", data, (sec + 1) * ssz)

    def chain(start):
        out, s, seen = bytearray(), start, set()
        while s not in (FREE, END) and s < len(fat) and s not in seen:
            seen.add(s)
            out += data[(s + 1) * ssz : (s + 2) * ssz]
            s = fat[s]
        return bytes(out)

    d = chain(dir0)
    ents = []
    for i in range(len(d) // 128):
        e = d[i * 128 : (i + 1) * 128]
        nl = struct.unpack_from("<H", e, 64)[0]
        name = e[: max(nl - 2, 0)].decode("utf-16-le", errors="replace")
        start, size = struct.unpack_from("<IQ", e, 116)
        ents.append((name, e[66], start, size))
    ministream = chain(ents[0][2]) if ents else b""
    mfat = []
    if nmfat:
        mf = chain(mfat0)
        mfat = list(struct.unpack_from(f"<{len(mf) // 4}I", mf))

    def mchain(start, size):
        out, s = bytearray(), start
        while s not in (FREE, END) and s < len(mfat) and len(out) < size:
            out += ministream[s * mssz : (s + 1) * mssz]
            s = mfat[s]
        return bytes(out[:size])

    return {
        name: (mchain(start, size) if size < mcut else chain(start)[:size])
        for name, typ, start, size in ents[1:]
        if typ == 2  # a stream, not a storage
    }


def sch_records(path):
    """The records of a .SchDoc's FileHeader stream, as dicts with upper-case
    keys. Each is a 4-byte header (24-bit length, 8-bit flag) and a
    `|KEY=value|...` body. Binary records (flag != 0) are skipped. A key
    prefixed `%UTF8%` carries the UTF-8 form of the plain key's value."""
    blob = cfb_streams(Path(path).read_bytes())["FileHeader"]
    out, i = [], 0
    while i + 4 <= len(blob):
        n = struct.unpack_from("<I", blob, i)[0]
        length, flag = n & 0xFFFFFF, n >> 24
        body = blob[i + 4 : i + 4 + length]
        i += 4 + length
        if flag:
            out.append({})
            continue
        kv = {}
        for field in body.rstrip(b"\0").split(b"|"):
            if b"=" not in field:
                continue
            k, v = field.split(b"=", 1)
            k = k.decode("latin-1").upper()
            if k.startswith("%UTF8%"):
                kv[k[6:]] = v.decode("utf-8", errors="replace")
            else:
                kv.setdefault(k, v.decode("cp1252", errors="replace"))
        out.append(kv)
    return out


def sch_parts(path):
    """({component unique ID: designator}, {sheet symbol unique ID: file name})
    for one .SchDoc. Record 0 is the file header, so a record's OWNERINDEX is
    its owner's position minus one. A part of a multi-part component is its
    own component record (RECORD=1), with its own unique ID and designator."""
    recs = sch_records(path)
    parts, sheets = {}, {}
    for r in recs:
        owner = r.get("OWNERINDEX")
        if owner is None or not owner.isdigit() or int(owner) + 1 >= len(recs):
            continue
        o = recs[int(owner) + 1]
        if r.get("RECORD") == "34" and o.get("RECORD") == "1" and o.get("UNIQUEID"):
            parts[o["UNIQUEID"]] = r.get("TEXT", "")
        if r.get("RECORD") == "33" and o.get("RECORD") == "15" and o.get("UNIQUEID"):
            sheets[o["UNIQUEID"]] = r.get("TEXT", "")
    return parts, sheets


# Altium's pin electrical types; 7 is Power, the only kind KiCad joins
# implicitly when hidden (as a hidden power-input pin).
POWER_PIN = "7"


def warn_unconverted(text, schdocs):
    """Warn about Altium features whose connections KiCad's import doesn't
    keep, so --check-pcb will fail on their nets (#395). On the nRF54LM20 DK
    they split 121 of its 241 board nets:

      * harnesses: KiCad makes each a bus group with the right members, but the
        wires leaving it keep their Altium net names, and a KiCad wire joins a
        bus only through a label naming the member;
      * hidden pins that aren't power pins: Altium joins a hidden pin to the
        net of its name (X1's GND pins on the DK); KiCad joins only hidden
        power-input pins.
    """
    harness_docs = [d for d in documents(text) if PureWindowsPath(d).suffix.lower() == ".harness"]
    harness_ports, hidden = 0, []
    for path in schdocs:
        try:
            recs = sch_records(path)
        except (ValueError, KeyError, struct.error):
            continue
        des = {
            int(r["OWNERINDEX"]): r.get("TEXT", "?")
            for r in recs
            if r.get("RECORD") == "34" and r.get("OWNERINDEX", "").isdigit()
        }
        for r in recs:
            if r.get("RECORD") in ("16", "18") and r.get("HARNESSTYPE"):
                harness_ports += 1
            if (
                r.get("RECORD") == "2"
                and int(r.get("PINCONGLOMERATE", "0") or 0) & 4
                and r.get("ELECTRICAL") != POWER_PIN
                and r.get("OWNERINDEX", "").isdigit()
            ):
                hidden.append(f"{des.get(int(r['OWNERINDEX']), '?')}.{r.get('DESIGNATOR')}")
    if not (harness_docs or harness_ports or hidden):
        return
    print("WARNING: KiCad's import won't keep every connection in this design:")
    if harness_docs or harness_ports:
        print(
            f"  harnesses: {len(harness_docs)} .Harness document(s), {harness_ports} harness "
            "port(s) and sheet entries. Their signals come out split."
        )
    if hidden:
        print(
            f"  hidden pins that aren't power pins: {', '.join(sorted(hidden))}. Left unconnected."
        )
    print("  Expect --check-pcb to fail on those nets; answer from --pcb-nets (SKILL.md § 4).")


TITLE_FIELDS = ("Title", "Revision", "Date", "DocumentNumber")


def project_params(text):
    """{name: value} from a .PrjPcb's [ParameterN] sections."""
    return {
        ini_value(body, "Name"): ini_value(body, "Value") or ""
        for name, body in sections(text)
        if name and re.fullmatch(r"Parameter\d+", name) and ini_value(body, "Name")
    }


def sheet_params(path):
    """{name: value} for a .SchDoc's own parameters: the title block's fields,
    which are the parameter records (RECORD=41) that no object owns."""
    return {
        r["NAME"]: r.get("TEXT", "")
        for r in sch_records(path)
        if r.get("RECORD") == "41" and "OWNERINDEX" not in r and r.get("NAME")
    }


def resolve(expr, lookup):
    """An Altium `=` special string: a parameter name, or names and quoted
    text joined by `+` (Nordic's `=ProductName + ' - Debugger'`). None if any
    name is unknown or the expression is something else."""
    out = []
    for term in re.findall(r"""\s*('[^']*'|"[^"]*"|[^+'"]+?)\s*(?:\+|$)""", expr):
        if term[:1] in "'\"":
            out.append(term[1:-1])
        elif term.strip().lower() in lookup:
            out.append(lookup[term.strip().lower()])
        else:
            return None
    return "".join(out) if out else None


def print_title_blocks(text, schdocs):
    """Each sheet's title, revision, date and number. A value `=Name` refers to
    a parameter, the project's first, which is resolved here: KiCad's import
    copies the `=Name` text as it is, so the imported title blocks can't settle
    the revision (#395). On UWRT's 48-17V Buck, in a folder named "Rev 3", the
    sheet says 2.0 and the project's parameters 0.1. The sheet's own
    parameters are looked up when the project has no such name."""
    proj = {k.lower(): v for k, v in project_params(text).items()}
    print("Title blocks (an Altium `=Name` resolved from the parameters):")
    for path in schdocs:
        try:
            own = sheet_params(path)
        except (ValueError, KeyError, struct.error) as e:
            print(f"  {path.name}: unreadable ({e})")
            continue
        low = {k.lower(): v for k, v in own.items()}
        fields = []
        for f in TITLE_FIELDS:
            v = own.get(f, "").strip()
            if v.startswith("="):
                got = resolve(v[1:], {**low, **proj})
                v = f"{got}  [{v}]" if got is not None else f"{v}  (unresolved)"
            if v and v != "*":
                fields.append(f"{f}: {v}")
        print(f"  {path.name}: " + ("; ".join(fields) or "(empty)"))
    rev = [f"{k}={v}" for k, v in project_params(text).items() if "revision" in k.lower()]
    if rev:
        print(f"  project parameters naming a revision: {'; '.join(rev)}")


# --- check-variants -------------------------------------------------------


def load_kicad_netlist():
    path = Path(__file__).resolve().parent.parent / "kicad-netlist" / "kicad-netlist.py"
    spec = importlib.util.spec_from_file_location("kicad_netlist", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def altium_variants(text):
    """[(name, [{DESIGNATOR, UNIQUEID, KIND, ...}])] from [ProjectVariantN]."""
    out = []
    for name, body in sections(text):
        if not (name and re.fullmatch(r"ProjectVariant\d+", name)):
            continue
        vars_ = []
        for m in re.finditer(r"(?m)^Variation\d+=(.*?)\r?$", body):
            vars_.append(
                {k.upper(): v for k, _, v in (f.partition("=") for f in m.group(1).split("|"))}
            )
        out.append((ini_value(body, "Description") or name, vars_))
    return out


def check_variants(prj, kicad_root):
    prj = Path(prj)
    text, _ = read_text(prj)
    by_uid, sheet_files = {}, {}
    for doc in documents(text):
        if PureWindowsPath(doc).suffix.lower() != ".schdoc":
            continue
        path = prj.parent.joinpath(*doc_parts(doc))
        if not path.is_file():
            path = prj.parent / PureWindowsPath(doc).name  # moved by prepare
        if not path.is_file():
            print(f"not found, skipped: {doc}")
            continue
        parts, sheets = sch_parts(path)
        for uid, des in parts.items():
            by_uid.setdefault(uid, []).append((PureWindowsPath(doc).name, des))
        sheet_files.update(sheets)

    def resolve(uid_path):
        """The designator a variation's `\\SHEET\\PART` unique-ID path names."""
        ids = [s for s in uid_path.split("\\") if s]
        if not ids:
            return None
        hits = by_uid.get(ids[-1], [])
        if len(hits) > 1 and len(ids) > 1:
            file = sheet_files.get(ids[-2], "").lower()
            hits = [h for h in hits if h[0].lower() == file] or hits
        return hits[0][1] if len(hits) == 1 else None

    kn = load_kicad_netlist()
    base = kn.dnp_refs(kicad_root)
    kicad_names = kn.variant_names(kicad_root)
    print(f"KiCad variants: {', '.join(kicad_names) or '(none)'}")
    if base:
        print(f"KiCad DNP in the default (not from a variant): {', '.join(sorted(base))}")
    bad = 0
    for name, variations in altium_variants(text):
        altium, notes = set(), []
        for v in variations:
            des, uid, kind = v.get("DESIGNATOR", ""), v.get("UNIQUEID", ""), v.get("KIND", "")
            if kind != "1":
                notes.append(f"Kind={kind} on {des}: not checked")
                continue
            part = resolve(uid)
            if part is None:
                notes.append(f"{des}: unique ID {uid} not found in the .SchDoc files")
                part = des
            elif part != des:
                notes.append(f"{des}: stale designator, its unique ID {uid} is {part}")
            altium.add(part)
        print(f"\n{name}")
        if name not in kicad_names:
            kicad = set()
            if variations:
                notes.append("not among KiCad's variants")
        else:
            kicad = kn.dnp_refs(kicad_root, name) - base
        print(f"  Altium not fitted: {', '.join(sorted(altium)) or '(none)'}")
        print(f"  KiCad DNP:         {', '.join(sorted(kicad)) or '(none)'}")
        for n in notes:
            print(f"  note: {n}")
        for ref in sorted(kicad - altium):
            print(f"  DIFFERS {ref}: KiCad marks it DNP; Altium fits it")
        for ref in sorted(altium - kicad):
            print(f"  DIFFERS {ref}: Altium leaves it unfitted; KiCad fits it")
        bad += len(kicad ^ altium)
    print(f"\n{bad} disagreement(s)")
    return 1 if bad else 0


def main():
    for stream in (sys.stdout, sys.stderr):
        # A Windows console that isn't UTF-8 would otherwise raise on the
        # first non-ASCII name.
        with contextlib.suppress(AttributeError, ValueError):
            stream.reconfigure(errors="replace")
    args = sys.argv[1:]
    cmd = args.pop(0) if args else None
    opts = {}
    for flag in ("--out", "--project"):
        if flag in args:
            i = args.index(flag)
            opts[flag[2:]] = args[i + 1]
            del args[i : i + 2]
    if cmd == "prepare" and len(args) == 1 and "out" in opts:
        prepare(args[0], **opts)
    elif cmd == "check-import" and len(args) == 1:
        check_import(args[0])
    elif cmd == "check-variants" and len(args) == 2:
        sys.exit(check_variants(*args))
    else:
        usage = re.search(r"Usage:\n(.*?)\n\n", __doc__ or "", re.S)
        if cmd == "prepare" and "out" not in opts:
            print("prepare needs --out DIR: a new folder in the session's scratchpad.")
        sys.exit("usage:\n" + (usage.group(1) if usage else "see the docstring"))


if __name__ == "__main__":
    main()
