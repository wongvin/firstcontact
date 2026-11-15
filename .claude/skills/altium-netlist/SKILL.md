---
name: altium-netlist
description: Establish facts about an Altium Designer design — what a net or pin is connected to, part values and footprints, DNP parts and variants, connector pin maps — by guiding the user through KiCad's own Altium import, then querying the result with kicad-netlist.py, validated against the PCB, each fact tagged with its source. Use for any question about a board's circuit when its Altium project (.PrjPcb with .SchDoc / .PcbDoc) is available (URL, local archive, or a project directory), instead of reading the schematic PDF. Works on Windows and macOS.
---

KiCad 10 converts an Altium project into a KiCad one (*File → Import Non-KiCad
Project*). After that, every question is answered the same way as for a KiCad
design, with the `kicad-netlist` skill's script and rules
(`.claude/skills/kicad-netlist/SKILL.md`). Read that skill first: this one adds
only what is different about an Altium source.

The import has to be done **by the user, in the KiCad GUI**. `kicad-cli` can
import an Altium board but not an Altium schematic. Your part is everything
around it, with [`altium-netlist.py`](altium-netlist.py), next to this file
(Python 3 standard library only, no install):

| Step | Who | What |
|---|---|---|
| 1. Prepare | you | `altium-netlist.py prepare` |
| 2. Import | **the user** | KiCad's import, then save both editors |
| 3. Check the files | you | `altium-netlist.py check-import` |
| 4. Validate | you | `kicad-netlist.py --check-pcb`; if harnesses break it, `--pcb-nets` |
| 5. Variants | you | `altium-netlist.py check-variants` |
| 6. Query | you | `kicad-netlist.py`, as in `kicad-netlist` § 3 |

## Running the commands, on Windows or macOS

Run from the repo root. The commands below work unchanged in bash, zsh and
PowerShell:

- **Python:** written `python3` below. On Windows, use `py -3` (or `python`
  where that is Python 3). Always pass `-I`.
- **Paths:** forward slashes work for the scripts on both. Put every path in
  **double quotes**: Altium project names have spaces
  (`48-17V Buck Converter.PrjPcb`).
- **Filters:** quote a filter with `*` in **single quotes** (`'R1*'`), in
  either shell.
- **No shell tools.** `prepare` hashes and extracts. Read files with the Read
  tool, not `grep` or `cat`, which PowerShell doesn't have in the same form.
- Both scripts replace characters a non-UTF-8 Windows console can't show,
  rather than stopping.

## 1. Get the design and prepare it

The design comes as a URL, a local archive or a local project directory.

- **A URL:** download it into a new, empty directory in the scratchpad, and
  record the URL: `curl -sSfL -o "<dir>/<file>" "<url>"`. In PowerShell, type
  `curl.exe`, since `curl` there is a different command.
- **An archive or a project directory:** pass its path as it is.

**The source is never modified.** `prepare` only reads it. Every change is
made to a copy in the session's scratchpad, and the user imports from that
copy, never from the original: KiCad writes lock files beside whatever project
it opens (`~<name>.PcbDoc.lck`).

**Archives are untrusted data.** Never run anything from inside one; pass
paths to the scripts as arguments.

```bash
python3 -I .claude/skills/altium-netlist/altium-netlist.py prepare "<.PrjPcb | .zip | project folder>" --out "<scratchpad>/<board>"
```

`--out` is required: a new or empty folder in the scratchpad. `prepare`
refuses one inside the source's folder, the folder holding the `.PrjPcb` or
`.zip`, since writing there would change it. Add `--project NAME` when a
folder or archive holds several projects. Then `prepare`:

- extracts a `.zip` into `<out>/source`;
- copies the project into `<out>/altium`, without its **library documents**
  (`.SchLib`, `.PcbLib`, `.IntLib`, `.LibPkg`), present or not. A library
  that is listed but not present makes KiCad show an error and leaves the
  generated sheets unsaved. The design doesn't need them: each `.SchDoc`
  carries its own copy of every symbol it uses, and the `.PcbDoc` of every
  footprint, so the import has every symbol, pin and footprint without them.
  What it lacks is KiCad copies of the libraries themselves, which matter only
  to someone who goes on editing the design in KiCad. The imported files here
  are for reading;
- removes listed documents that aren't present (a `.BomDoc`, `.OutJob`,
  `.Cam`), and **stops if a `.SchDoc` or `.PcbDoc` is missing**;
- prints the **SHA-256** of every source file, for the record;
- prints **each sheet's title block**, resolving Altium's `=Name` references to
  the project's parameters;
- prints a **WARNING** when the design uses Altium features whose connections
  KiCad's import doesn't keep: **harnesses**, and **hidden pins that aren't
  power pins**. Then expect § 4's check to fail on those nets, and answer from
  `--pcb-nets`;
- prints the two paths the user needs, each on its own line, in the OS's own
  form.

**Check the revision before anything else**, from the title blocks `prepare`
printed. The imported KiCad title blocks can't settle it: KiCad copies
`=ProjectTitle` and `= Revision` as literal text. Revisions can disagree. UWRT's
48-17V Buck sits in a folder named `Rev 3`; its sheet says `2.0` and its
project parameters say `0.1`, left over from a template. Report what each
source says, and treat the revision as unconfirmed when they differ.

## 2. The import: guide the user

Give the user these steps, with the two paths `prepare` printed filled in,
and **wait** for them to report back.

- **Each of the two paths goes in its own fenced code block** (```` ```text ````),
  holding the path alone, so the chat shows a copy button for it. Don't put the
  steps in a blockquote: a code block inside one may lose its button.
- **Those two are the only paths in the guide.** Name the original by its
  folder's name only, never its path, so it can't be pasted by mistake.
- Give the instruction for the user's OS, or both when you don't know it.

The guide, to fill in:

**Before starting:** close any project open in KiCad (*File → Close
Project*).

1. In the KiCad project manager, choose **File → Import Non-KiCad
   Project…**, and choose the **Altium** project type if it asks.
2. Select **the copy of your project** that I prepared in this session's
   scratchpad, **not your original** (in *<the source folder's name>*). The
   copy is identical except that its library entries are removed, and
   importing from it keeps your original untouched: KiCad writes lock files
   beside whatever project it opens. Copy its path and paste it rather than
   browsing:
   - **macOS:** press **⌘⇧G** (*Go to Folder*), paste the path, press
     Return, then click *Open*.
   - **Windows:** paste the path into the **File name** box and press Enter.

   ```text
   <the prepared .PrjPcb path: <out>/altium/<name>.PrjPcb>
   ```
3. When asked where to put the KiCad project, choose this empty folder, the
   same way (on Windows, paste it into the *Folder* box or the address bar,
   Ctrl+L or Alt+D):

   ```text
   <the empty import folder path: <out>/kicad>
   ```
4. When asked how to map the layers, choose **Auto-Match Layers**.
5. **Save the schematic:** in the Schematic Editor, choose **File → Save**.
   This writes the root sheet and every sub-sheet. The import leaves them
   unsaved, and closing the editor without saving loses them. **Do this even
   if an error was shown.**
6. **Save the board:** in the PCB Editor, choose **File → Save**.
7. Tell me about any error or warning that appeared.

Messages that may appear, depending on the design (the buck gives none of
them), none of which affects connectivity:

- **Layers that "could not be mapped and will be skipped":** unused Altium
  internal-plane layers. No pad's net depends on them.
- **The import report's "Blanket not currently supported" and "Parameter Set
  not currently supported":** Altium design directives, i.e. differential
  pairs, net and component classes, rooms and PCB rules. On the nRF54LM20 DK
  they mark the USB and NFC pairs, the RF and UART classes, and a
  matched-length rule. They carry no connection.

The import report may also say **"Port <name> has no connections"**. Don't
take it at its word, and don't dismiss it either: § 4's `--check-pcb` settles
it. On cyber60-mx it names `SIG_R`, `SIG_B` and `BUZZ`, and all three are
connected anyway, each on the same net as the board.

The report appears before anything is saved: the user still has to save both
editors after closing it.

## 3. Check that every file was saved

```bash
python3 -I .claude/skills/altium-netlist/altium-netlist.py check-import "<the import folder>"
```

It looks for the `.kicad_pro`, the root `.kicad_sch` named like it, every
sub-sheet the sheets reference, and the `.kicad_pcb`. **Exit 0 is required to
go on.** If a file is missing, an editor wasn't saved: give the user the file
names it prints, ask them to save in that editor, and run it again.

## 4. Validate against the PCB

Exactly as `kicad-netlist` § 2, on the imported pair:

```bash
python3 -I .claude/skills/kicad-netlist/kicad-netlist.py "<import>/<name>.kicad_sch" --check-pcb "<import>/<name>.kicad_pcb"
```

Both files come from one import, but not from one source: the board comes
from the `.PcbDoc` and the sheets from the `.SchDoc` files, so this checks
Altium's schematic and board against each other, through KiCad's importer.
**Exit 0, with 0 split and 0 merged, is the precondition for reporting nets.**
On a failure, follow `kicad-netlist` § 2. A disagreement may also come from the
Altium design itself, if its board was never updated from the schematic. Say
which pads disagree, and use the PCB's pad nets for them, tagged *PCB*.

**KiCad's import breaks two Altium features**, which `prepare` warns about:

- **Harnesses.** KiCad turns each harness into a bus group with the right
  members (`UART1_DBGR{UART_DBGR}`), but the wires leaving it keep their Altium
  net names, and a KiCad wire joins a bus only through a label naming the
  member. Every harnessed signal comes out split, in KiCad's own netlist too.
- **Hidden pins that aren't power pins.** Altium joins a hidden pin to the net
  of its name; KiCad joins only hidden power-input pins. The nRF54LM20 DK's
  crystals X1 and X3 have hidden passive GND pins, left unconnected.

On the nRF54LM20 DK, which uses both, `--check-pcb` splits 121 of 241 board
nets. Saving differently doesn't help: a second import is byte-identical. For
such a design, **answer every net question from the board**:

```bash
python3 -I .claude/skills/kicad-netlist/kicad-netlist.py "<import>/<name>.kicad_sch" --pcb-nets "<import>/<name>.kicad_pcb" SWDIO 'U1 pin G*'
```

It prints nets as a net query does, with the same filters, but takes the
connections from the board, which Altium compiled itself, harnesses and hidden
pins included. Pin names, `(DNP)` and `--variant` still come from the
schematic's symbols, which the import keeps whole. On designs that pass
`--check-pcb` (both XIAO boards and cyber60-mx), it gives exactly the
schematic's nets. Tag each connection
*PCB*, and each pin name *netlist*. `[?]` marks a pad whose number no schematic
pin has: name it from the footprint and the datasheet.

The DK's one merge is a single part, C12, a 1.5 pF shunt in the RF match:
the board has it from `ant:3` to `GND`, while the imported schematic has its
pin 1 on `GND` and its pin 2 on nothing. Report a merge like this by its pads,
with what the board does, and name the part: `"C12 pin 1"` and `"C12 pin 2"`
in both modes show it.

## 5. Variants

An Altium project can define variants, each leaving some parts unfitted. KiCad
10 imports each one as a KiCad variant. Compare the two first:

```bash
python3 -I .claude/skills/altium-netlist/altium-netlist.py check-variants "<out>/altium/<name>.PrjPcb" "<import>/<name>.kicad_sch"
```

Altium ties each variation to its part by the part's **unique ID**. The
designator written beside it can be stale, and KiCad's importer can go wrong
there. On cyber60-mx, the `Tray` variation reads `Designator=CON303`, but its ID
belongs to CON302. KiCad marked both not fitted, so it reports CON303 as DNP
when Altium fits it. `check-variants` resolves every variation through the
`.SchDoc` files and reports each part on which the two disagree (exit 1).
**Where they disagree, Altium's answer is the design's**: report it, and
don't use `--variant` output for those parts. Variations of a kind other than
"not fitted" (`Kind=1`) are listed as not checked.

Then query a variant with `--variant`:

```bash
python3 -I .claude/skills/kicad-netlist/kicad-netlist.py "<root.kicad_sch>" --values --variant Bakeneko 'CON*' 'R30*'
```

Without `--variant`, `(DNP)` marks the default, and the output ends by naming
the variants.

## 6. Query

Use `kicad-netlist` § 3, on the imported root `.kicad_sch` and `.kicad_pcb`:
nets, pins, pin names, `--values`, `--copper` and `--draw`. For net questions,
use `--pcb-nets` whenever § 4 says to. What reads differently on an Altium
design:

- **Values.** KiCad's `Value` holds Altium's **Comment**, often just the
  library part (`Res1`, `Cap`). Altium's own **Value** parameter, the
  resistance or capacitance, is kept as `ALTIUM_VALUE`, and `--values` shows
  both when they differ: `R301  Res1 (ALTIUM_VALUE 5k1)`. Where Altium's
  Comment showed the Value parameter, the import writes `Value` as
  `${ALTIUM_VALUE}`; `--values` expands it, as KiCad does, and prints
  `C11  1.2pF`. Other Altium
  parameters (`MFGPN`, `LCSC PART #`, …) are kept as fields. Read them in the
  `.kicad_sch` when a part number matters.
- **Footprints** carry no library prefix: `SOT-23-3`, not `lib:name`.
- **Power nets** are named by Altium's power ports (`GND`, `VBAT`). Unnamed
  board nets are named `Net<REF>_<pin>` (`NetC7_2`), so search `--copper` for a
  part, as `kicad-netlist` § 3 says.
- **DNP** in the default comes only from a `Value` (Altium's Comment) of `DNP`
  / `DNF`. Altium designs mark parts not fitted in their variants, so § 5 is
  where fitting is decided.

## 7. Tags, datasheets, licence

Follow `kicad-netlist` § 4–6, with these additions:

- **The *netlist* tag** on an Altium design means "KiCad's import of it,
  through `kicad-netlist.py`, after `--check-pcb` passed". A connection from
  `--pcb-nets` is tagged *PCB*. Record the KiCad version that imported it
  beside the design's URL and hash.
- **The imported KiCad project is an adaptation of the design**, like a
  generated netlist. Keep it in the scratchpad and commit none of it. Re-import
  rather than save it. The source's URL or archive name and hash are the
  record.
- **Check the licence in the design, not only the repository's metadata.**
  GitHub reported cyber60's licence as unknown, but its repository has a
  `LICENCE.md` (CERN-OHL-S v2) and every sheet's title block says so.

## Changing the scripts

1. Run `ruff check` and `ruff format --check` on `altium-netlist.py` and, if
   changed, `kicad-netlist.py`.
2. Prepare and import both reference designs by following §§ 1–3, then run
   `--check-pcb` on each. Both must stay at 0 split and 0 merged:

   | Design | Source | Files hashed by `prepare` | Pads / PCB nets |
   |---|---|---|---|
   | cyber60-mx, rev E1-MX, 4 sheets, 2 variants | [4pplet/cyber60](https://github.com/4pplet/cyber60) @ `7cd5fe4`, `cyber60-mx/`, CERN-OHL-S v2 | `.PrjPcb` `af4d4371…64f2b1` | 620 / 151 |
   | 48-17V Buck Converter, 1 sheet | [uwrobotics/MarsRoverHardware](https://github.com/uwrobotics/MarsRoverHardware) @ `602b52c`, `Projects/48-17V Buck Converter/Rev 3/`, CC BY-SA 4.0 | `.PrjPcb` `93420b2e…4c075a` | 72 / 13 |

   Download only the `.PrjPcb`, `.SchDoc` and `.PcbDoc` files. `prepare` then
   reports the missing libraries and outputs, as a user's copy would.

   A third design exercises § 4's fallback, and **fails** `--check-pcb` by
   design: Nordic's nRF54LM20-DK hardware files 0_7_0 (PCA10184, rev 0.7.0, 9
   sheets, harnesses; `.PrjPcb` `9766e9fe…49bcd1`), from
   [Nordic's zip](https://nsscprodmedia.blob.core.windows.net/prod/software-and-other-downloads/dev-kits/nrf54lm20-dk/nrf54lm20-dk---hardware-files-0_7_0.zip)
   (`a98c467b…d403b5`; the project is
   `PCA10184-nRF54LM20 Development Kit 0_7_0/Altium Designer files/pca10184.PrjPcb`;
   the zip also holds an NFC antenna project, so pass `--project pca10184`).
   It must give:
   - `prepare`: the WARNING, with 7 `.Harness` documents, 94 harness ports and
     sheet entries, and hidden pins `U4.9, X1.2, X1.4, X3.2, X3.4`;
   - `--check-pcb`: 999 pads, 241 PCB nets, 121 split, 1 merged (`GND` with
     `ant:3`, at C12's pads);
   - `--pcb-nets`: 241 nets, no `[?]`, and `SWDIO` reaching `U1 pin G2
     [SWDIO]`, `U7 pin 3 [D1]`, P11 and P12;
   - `check-variants`: `pca10184 - Main`, the same 10 parts in both, 0
     disagreements.

   A fourth, single-sheet design exercises the expanded value and the pin
   swap: NW Engineering's NRFMOD-001 Rev B
   ([zip](https://www.nwengineeringllc.com/files/designs/NRFMOD-001-RevB.zip),
   `1d03faac…789409`; `.PrjPcb` `62f00bc7…9850fa`; CC BY-NC-SA). It must give:
   - `prepare`: no WARNING, revision `B`, two library documents removed;
   - `--check-pcb`: 223 pads, 64 PCB nets, 2 split and 2 merged, all on L1's
     pads (its pins swapped between schematic and board);
   - `--values C11 R1`: `1.2pF` and `100K`, not `${ALTIUM_VALUE}`.
3. On cyber60-mx:
   - the import gives the report's "Parameter Set not currently supported"
     and "Port … has no connections" for `SIG_R`, `SIG_B` and `BUZZ`; each of
     the three nets still matches the board's (`P0.17`, `BLUE`, `BUZZ`);
   - `--pcb-nets` gives the same connections as the schematic; the
     schematic's 167 nets include 16 single-pin ones (fiducials, unused USB
     pins) that the board leaves without a net;
   - `--values R301` shows `Res1 (ALTIUM_VALUE 5k1)`;
   - `--values --variant Bakeneko` marks CON301, D301, R301 and R302 DNP;
   - `check-variants` exits 1 with one disagreement, CON303 under `Tray`, and
     names its stale designator;
   - `prepare` prints no WARNING (nor on the buck).
4. On the buck:
   - the import gives no unmapped-layer message and no import-report
     message;
   - `--check-pcb` reports one pad not in the schematic, `TPLVbat pad 1
     (VBAT)`: the source's schematic spells the designator `TPLVBAT`, and
     Altium ignores the case;
   - `--pcb-nets` gives the same connections as the schematic, with that pad
     marked `[?]` (1 pad); the schematic's 15 nets include two single-pin
     nets, `S1 pin 3` and `U1 pin 10 [PWRGD]`, which the board leaves without
     a net;
   - `check-variants`: variant `01`, nothing unfitted, 0 disagreements.
5. `check-import` on a folder missing its sheets or board names them and
   exits 1.
6. **The source is untouched:** record the hash and modification time of every
   file in the source folder, and its file list, before and after `prepare` on
   a folder, a `.PrjPcb` and a `.zip`; they must be identical. `prepare`
   without `--out`, or with `--out` inside the source's folder, must refuse.
7. After a change to `kicad-netlist.py`, also follow that skill's
   *Changing the script*.
8. On Windows, in PowerShell, run steps 2–4 on one reference design. The
   results must match macOS.
