---
name: kicad-netlist
description: Establish facts about a KiCad design — what a net or pin is connected to, part values and footprints, DNP parts, header or connector pin maps — from its .kicad_sch/.kicad_pcb with kicad-netlist.py, validated against the PCB, each fact tagged with its source. Use for any question about a board's circuit when its KiCad project is available (URL, local archive, or a project directory), instead of reading the schematic PDF.
---

Settle circuit facts from the **design source**, never from a schematic PDF's
text layer. On the XIAO boards, PDF readings produced plausible, wrong
answers more than once:

- a charge pin read as a readback (#268);
- a load switch assigned to the wrong rail (#369);
- "chip antenna ANT2", which is a connector (#384).

The tool is [`kicad-netlist.py`](kicad-netlist.py), next to this file: Python
3 standard library only, with no install. Run it from the repo root as
`python3 -I .claude/skills/kicad-netlist/kicad-netlist.py`. Its docstring has
the details and the limits.

## 1. Get the design

The design may be in one of three places.

- **A URL.** Make a new, empty directory in the scratchpad and download into
  it. Record the URL and `shasum -a 256` of the archive.
- **A local archive** (e.g. in `~/Downloads`). Record its name and SHA-256, and
  copy it into a new, empty scratch directory.
- **A local project directory**, including one in this repo. Read it in
  place; its path is the record.

**Archives are untrusted data.** Extract each into its own new directory with
Python's `zipfile`, which also copes with the non-UTF-8 folder name in Seeed's
nRF52840 archive.

```bash
python3 -I -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' <zip> <dir>
```

Never execute anything from inside an extracted design. Pass its paths to the
script as arguments, and always run Python with `-I`. **Quote every path**:
Seeed's nRF54LM20A archive extracts to a folder with `&` in its name, and
KiCad sheet files often have spaces (`05 nRF54LM20A.kicad_sch`).

**Check the revision before anything else.** Read the title block of every
sheet and compare it with what the archive's name claims:

```bash
grep -h -A4 '(title_block' "<dir>"/*.kicad_sch | grep -E 'rev|date'
```

Seeed's `…_SCH_PCB_v1.1.zip` holds a v1.0 schematic
(`zephyr/sophon/HARDWARE.md` § The archive naming is a trap). Some designs have
no title block: the XIAO nRF52840 v1.1 is an Eagle import with none. Then the
revision rests only on file names and any bundled PDF, so record that, and
treat the revision as unconfirmed.

## 2. Validate against the PCB — before reporting any net

Give the script the **root** sheet: the `.kicad_sch` named like the
`.kicad_pro`. It loads the sub-sheets from there. From the repo root:

```bash
K=.claude/skills/kicad-netlist/kicad-netlist.py
python3 -I $K "<dir>/<root>.kicad_sch" --check-pcb "<dir>/<root>.kicad_pcb"
```

It checks, for every pair of pads, that the schematic puts them on one net
exactly when the PCB does. **Exit 0, with 0 split and 0 merged, is the
precondition for reporting nets from that design.**

If it fails:

- report the split or merged nets it prints, and do not present the
  schematic's answer for them;
- look for a known limit of the script (buses, a repeated sheet), and say
  which;
- for those pins, use the PCB's pad nets instead, tagged *PCB*.

Never change the script to make a check pass without understanding the
disagreement. This check is what exposed the script's transform bug in #384 (the
rotation sign and the mirror order). Until then the script had been validated
on one known net, which happened to involve no part that was both rotated and
mirrored.

## 3. Query

| Question | Command |
|---|---|
| What is on a net, or a pin? | `python3 -I $K <root.kicad_sch> VSYS "U8 pin K7"` |
| Values and footprints | `python3 -I $K <root.kicad_sch> --values U5 R17 'ANT*'` |
| Everything | `python3 -I $K <root.kicad_sch>` |

Filters ignore case. **The last character picks the mode:**

| Ends in | Mode | Searches |
|---|---|---|
| anything else | **exact** | net labels, references, and `REF pin N` |
| `*` | **contains** | anywhere in the net's printed text (net queries), or in the reference (`--values`) |
| `=` | **pin name** | pin names only, the part printed in `[…]` |

| Filter | Net query matches | `--values` matches |
|---|---|---|
| `R1` | a net labelled `R1`, or any net that part R1 is on | R1 only |
| `"R1 pin 2"` | the net on that one pin | (nothing: not a reference) |
| `'R1*'` | any net with "R1" anywhere in its labels or members: R1, R10, VR1 | R1, R10–R19, VR1, … |
| `'U3 pin *'` | every net U3 is on: all of its pins. Same as `U3`; U30's pins don't match | (nothing: not a reference) |
| `'U8 pin K*'` | the nets on U8's pins K1, K2 … K10: one ball row | (nothing) |
| `'(DNP)*'` | nets with a not-fitted part on them | (nothing) |
| `'[VBUS]='` | nets with a pin named exactly VBUS | (nothing: a part has no pin name) |

Quote a filter with `*`. Unquoted, the shell may expand it against file names
in the current directory before the script sees it. A trailing `=` is safe in
bash and zsh; a leading one is not, since zsh expands `=word` to a command path.

**The `*` means "search, don't compare"**, not "any characters here". A
starred filter is found anywhere in the text it searches, so text before it
counts too (`'R1*'` matches VR1). Like `=`, it has that meaning only as the
last character. Anywhere else it is a literal character, so `'[R*]'` or
`'U8*K7'` is an exact filter that matches nothing.

### Pin names: a trailing `=`

The output prints each pin's name in brackets: `U8 pin K7 [VBUS]`, and `[]`
for a passive's unnamed pin. A filter ending in `=` searches those names and
nothing else, and its brackets mark the ends of the name, as printed:

| Filter | Pin name… | XIAO nRF54LM20A: pins matched | Result |
|---|---|---|---|
| `'[VBUS]='` | **is** VBUS | U2 B1/B2 and U7 pin 14 (the `VBUS` net), U8 K7 | 2 nets |
| `'[VBUS='` | **starts with** VBUS | adds U2 C3 `[VBUSOUT]` | 3 nets |
| `'VBUS]='` | **ends with** VBUS | adds the USB-C's `[A4/B9/VBUS]`, `[B4/A9/VBUS]` | 3 nets |
| `'VBUS='` | **contains** VBUS | all of the above | 4 nets |
| `'[R='` | starts with R | `LED1 pin 2 [R-]` | 1 net |
| `'RESET]='` | ends with RESET | `U8 pin F2 [nRESET]` | 1 net |
| `'[]='` | is empty | every pin with no name: the passives | 60 nets |

For contrast, on the same design:

| Filter | Mode | Why | Result |
|---|---|---|---|
| `'VBUS*'` | contains, all text | also matches the `VBUS` net's label | 4 nets |
| `'[VBUS]'` | exact | compared with labels, references and `REF pin N`, never pin names | 0 nets |
| `'[R*]'` | exact | the `*` isn't last, so this is the literal text `[R*]` | 0 nets |

A pin-name filter can anchor the start, the end or both, but it can't put a
gap inside the name: "starts with R and ends with T" can't be written. Pin
names print as the symbol stores them, including KiCad's `~{…}` overbar
markup. The NOR flash's active-low chip select on both XIAO boards is
`[~{CS}]`. `'CS]='` misses it, because the name ends in `}`; on the
nRF54LM20A it finds only the IMU's plain `[CS]`. Use `'[~{CS}]='` or `'CS}]='`.

`--values` prints one row per placed part, then a count:

```
$ python3 -I $K board.kicad_sch --values 'R1*' U3 J1
         J1  USB_C_Receptacle         Connector_USB:USB_C_Receptacle_GCT_USB4105
         R1  10k                      Resistor_SMD:R_0402_1005Metric
        R10  100k                     Resistor_SMD:R_0402_1005Metric
   R11(DNP)  0R                       Resistor_SMD:R_0402_1005Metric
         U3  STM32G031K8T6            Package_QFP:LQFP-32_7x7mm_P0.8mm
5 component(s)
```

- **Columns:** reference (with `(DNP)` if not fitted), the `Value` field, and
  the footprint as `library:name`.
- **Order:** rows sort as text, so R10 comes before R2.
- **Omitted:** power symbols and flags. A multi-unit part prints once.
- **The `Value` field is whatever the designer typed.** Trust the footprint
  over it when naming a part's role.

Reading the output:

- **Power nets are named by their symbol's `Value`** (`VSYS_3V3`, `GND`).
- **`(DNP)`** follows each pin of a Do Not Populate part, and in `--values` it
  follows the reference. **Check what every DNP part disconnects.** On the
  XIAO nRF54LM20A, a DNP 0 Ω (R23) is all that links the nRF54's USB VBUS pin.
  Test points are DNP as a matter of course: bare pads. The mark is KiCad's DNP
  attribute, or a Value of `DNP` / `DNF`: Seeed's XIAO nRF52840 v1.1 marks its
  not-fitted parts only by Value, with every DNP attribute left at `no`.
- **A single-pin net means the pin is unconnected.** The script ignores
  no-connect flags. Confirm in the `.kicad_pcb`: an unconnected pad's net is
  named `unconnected-(…)`.
- **A reference designator is not a function.** Read the footprint in
  `--values` before naming a part's role: `ANT2` is an IPEX connector footprint.
  The `Value` field can be unhelpful too (U4's is `英联`, "Union"; the
  nRF52840's LDO is just `3.3V`). The symbol's library name sometimes carries
  the part number instead: `grep -o '(lib_id "[^"]*"' <dir>/*.kicad_sch | sort -u`.
- **Ball names on multi-unit parts** come from the library symbol. For a BGA or
  WLCSP part, check them against the datasheet's ball map once.

### Copper on a net: `--copper`

```bash
python3 -I $K --copper <root.kicad_pcb> 'Net-(ANT*' '*RF*'
```

For each PCB net matching the filters (exact / `*`, on the PCB's net name),
this lists:

- its pads, as `REF.pad`;
- its track count and length;
- its vias;
- its copper zones.

It ends with the board's copper that carries no net: board graphics on copper
layers, copper graphics inside footprints, and keepout areas. A **copper
antenna** shows up as a footprint's or the board's copper graphics, or a zone,
on the RF net. A chip antenna shows up as a footprint pad. A bare connector
shows up as neither. On the XIAO nRF54LM20A, the RF net reaches only
`ANT2.1`, with no zones and no copper graphics anywhere on the board. On the
XIAO nRF52840, `Net-(ANT1-S)` reaches the chip antenna's pad `ANT1.1`.

PCB net names are not schematic labels. Unlabelled nets are named after a pin
(`Net-(ANT2-D)`), so when a filter finds nothing, list everything and search
for the part: `python3 -I $K --copper <pcb> | grep -B1 -A1 'ANT1\.'`.

### Drawing the board: `--draw`

```bash
python3 -I $K --draw "<root.kicad_pcb>" "<dir>" 'TP*' 'J*' --credit "<credit text>" --name probe
qlmanage -t -s 2400 -o "<dir>" "<dir>"/*.svg    # PNGs, for the Read tool
```

This writes `<board>[-<name>]-front.svg` and `-back.svg`; `--name` keeps several drawings apart in one folder. Each shows:

- the board outline;
- every pad in its true shape, coloured by side;
- the silkscreen text at its real size, angle and position;
- on each pad whose reference matches the filters, its `REF.pad` and net.

The back is drawn **as seen from the back**, the way the board is held to
probe it.

This is how a printed label is tied to a pad. **The pad's identity on the
drawing is exact**, from the PCB, and pad positions match the Gerbers'
plotted pads exactly. Which pad a label belongs to is read by eye,
with the whole layout in view, as on the real board. Labels usually follow a
pattern that settles it: on both XIAO boards, every SWD label sits beside its
pad on the same side, reading upward. A distance can't show that, and can
mislead. A text's position is its anchor, usually a corner, and labels often
sit between pads. On the XIAO nRF52840 the pad nearest `CLK` is TP1 (GND) and
nearest `DIO` is TP2 (RESET), but the labels belong to TP3 (SWDCLK) and TP5
(SWDIO), each sitting to the right of its pad.

Rotated and mirrored text matches the strokes KiCad plotted in the XIAO
nRF52840's `B_Silkscreen` Gerber. KiCad mirrors in the text's own frame, so a
mirrored text also reads the other way along its angle. The drawing derives
from the design. Every SVG carries a change note in a footer and in its
metadata, and `--credit` adds the creator, source and licence (§ 6). Without
`--credit` it stays in the scratchpad. Show it to the user, and read the PNG
yourself.

Small parts with close pads (an 0201's are 0.47 mm apart) get one ringed label
listing each pad's net, with a leader line. Test pads and widely spaced pads
get a label each.

## 4. Tag every fact with its source

| Tag | Meaning |
|---|---|
| *netlist* | from this script, on a design that passed `--check-pcb` |
| *PCB* | from the `.kicad_pcb`: a pad's net, a footprint, silkscreen near a pad |
| *datasheet* | from the part's datasheet, with page or table |
| *PDF text* | from the schematic PDF's text layer: weakest, never a conclusion on its own |

Record the design source (URL or archive name, plus SHA-256, or the repo path)
in the document the facts go into. The model is
`zephyr/sophon/hw/nrf54lm20a/HARDWARE.md` § Where the authoritative data is.

## 5. Datasheets

- **Store** each in the gitignored `datasheets/` folder of the subproject the
  design belongs to: `zephyr/sophon/datasheets/` for Sophon's boards, otherwise
  `<subproject>/datasheets/`, created when first needed. `.gitignore`'s
  `**/datasheets/` covers any of them.
- **Record** the URL and SHA-256 of each in the sources table.
- **Report only URLs that were actually fetched.** A URL built from a vendor's
  naming pattern is a guess. A 403 or 404 on one says nothing about whether the
  document exists.
- **When a vendor blocks scripted downloads** (Nordic's documentation sites
  returned 403 to curl in #387), ask the user for the
  file or the real link, or use a reputable third-party copy (a distributor or a
  dev-board maker). Record it as a mirror ("Arduino's copy of Nordic's PS
  v1.1"), with its document revision and hash.
- **Check that a download is a PDF** before hashing or citing it: `file <f>`, or
  its first bytes are `%PDF`. A bot-protection page ("Just a moment…") or a
  distributor's HTML comes back with HTTP 200. When only an HTML version can be
  had, the datasheet is not held: say so under § Not established, rather than
  citing pages read through a web fetch.
- **Read** with poppler: `pdftotext -layout <pdf> -` for tables, or the Read
  tool's `pages` for figures and ball maps.
- **A part with no datasheet of its own:** use a same-package proxy only after
  checking its package size and full pinout against the footprint and the
  netlist. Mark it as a proxy wherever it is cited. The MSM261DGT003 stands in
  for the DGT006 in `hw/nrf54lm20a/HARDWARE.md`; the DHT006, the closer name,
  was rejected for its pinout.

## 6. Licence

**The rule:** commit no generated netlist and no third-party design file.
Re-run the script rather than saving its output. For a third-party design, the
URL or archive name and its hash are the record. A design that already lives
in the repo is cited by its path. **Figures**, i.e. `--draw` drawings and
schematic snippets, may be committed with credits, as described at the end of
this section.

**Why.** Seeed's XIAO designs are CC BY-SA 4.0 (the boards carry
`LOGO_CC_BY-SA_4.0` footprints). The script's output and the drawings are
adaptations of the design, and the licence (§ 3) attaches obligations to an
adaptation only when it is **shared**, i.e. distributed or made publicly
available. Making and using one privately, in the scratchpad, triggers
nothing. Once shared, an adaptation must carry:

- **Attribution:**
  - credit to the creator, keeping any copyright notice;
  - a link to the licence;
  - a statement that it was changed, keeping any earlier such statements;
  - the creator's disclaimer, if any.
- **ShareAlike:** it must be licensed under CC BY-SA 4.0 or later, or a licence
  CC lists as compatible (GPLv3, one way).
- **No added restrictions:** no extra terms or DRM that stop others using it
  under the licence.

**What the licence doesn't reach.**

- **Facts.** "R23 is DNP on the nRF54's VBUS" is a fact about the board, not
  the design's expression. So HARDWARE.md can state every finding, with its
  *netlist* tag, and carry no obligation.
- **The rest of the repo.** ShareAlike covers the adapted material itself, so
  a BY-SA file doesn't put anything else in the repo under BY-SA.
- **Patents and trademarks**, e.g. Seeed's name and logo.

**So keeping netlist output out is a choice, not a requirement.** A raw dump
has no reason to be in a doc, and re-running costs nothing.

**Figures in a document carry credits at two levels.**

1. **In the document**, a note at the top: *Credits and licence for figures*.
   It names the source (creator, design and revision, URL), links CC BY-SA 4.0,
   says how the figures were changed, and marks which figures it covers (†). It
   also says that only those figures are licensed CC BY-SA 4.0, and that the
   rest of the document isn't covered. CC BY-SA 4.0 allows attribution "in any
   reasonable manner", and a document's own text stays outside ShareAlike,
   since including a figure doesn't make the document an adaptation.
2. **On every figure file**, because a file in the repo can be opened, copied
   or linked on its own. `--draw --credit "<text>"` stamps the credit into each
   SVG, in the footer and the metadata, alongside its change note. Use the
   same source and licence wording as the document's note, ending "This figure
   is licensed CC BY-SA 4.0."

A schematic snippet cropped from the published PDF (`pdftoppm -f N -l N -x … -y
… -W … -H … -r 300 -png`) needs the same two levels, but a raw PNG has no
footer. Until a tool adds one, cite schematic facts in text and use layout
drawings as figures.

This is a reading of the licence, not legal advice.

## Changing the script

1. Run `ruff check` and `ruff format --check` on it. Its E741 ignore is in
   `ruff.toml`.
2. Run `--check-pcb` on both reference designs, which must stay at 0 split and
   0 merged:

   | Design | Source | SHA-256 of archive | Pads / PCB nets |
   |---|---|---|---|
   | XIAO nRF54LM20A V1.0 | [Seeed](https://files.seeedstudio.com/wiki/XIAO_nRF54LM20A/getting_start/RES/XIAO_nRF54LM20A_V1.0_SCH&PCB_260508.zip) | `ca7f509f…f60ada` | 466 / 117 |
   | XIAO nRF52840 Plus v1.1 | [Seeed](https://files.seeedstudio.com/wiki/XIAO-BLE/Seeed_Studio_XIAO_nRF52840_Plus.zip) | `f5e4e0e9…a99bdd9` | 266 / 74 |
3. Check a net whose answer is known: on the nRF52840 v1.1,
   `'AIN7_BAT*' 'READ_BAT*'` gives `VBAT – R16 – P0.31/AIN7 – R17 – P0.14`, with
   R16 1M and R17 499k.
4. For a change to the pad transform (`pcb_pads`, used by `--draw` and
   `--copper`): on the XIAO nRF52840 v1.1, every pad must land on a pad flash
   (`D03`) in its archive's `F_Cu` / `B_Cu` Gerber. Currently all 250 pads do,
   to within 0.000 mm.
5. For a change to `--draw`: draw the XIAO nRF52840 v1.1 and overlay the
   `B_Silkscreen` Gerber from its archive. The archive was plotted in board
   coordinates with Y negated; mirror X as the back view does. Every label's
   text must lie on the plotted strokes.
6. For a change to `--copper`: on the nRF54LM20A, `'Net-(U8B-ANT)'` gives pads
   `L5.1, U8.E1` and `'Net-(ANT2-D)'` gives `ANT2.1, R25.2`, with no zones and
   no copper graphics on the board. On the nRF52840, `Net-(ANT1-S)` reaches
   `ANT1.1`.
