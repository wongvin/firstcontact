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
script as arguments, and always run Python with `-I`.

**Check the revision before anything else.** Read the title block of every
sheet and compare it with what the archive's name claims:

```bash
grep -h -A4 '(title_block' <dir>/*.kicad_sch | grep -E 'rev|date'
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
  Test points are DNP as a matter of course: bare pads.
- **A single-pin net means the pin is unconnected.** The script ignores
  no-connect flags. Confirm in the `.kicad_pcb`: an unconnected pad's net is
  named `unconnected-(…)`.
- **A reference designator is not a function.** Read the footprint in
  `--values` before naming a part's role: `ANT2` is an IPEX connector footprint.
  The `Value` field can be unhelpful too (U4's is `英联`, "Union").
- **Ball names on multi-unit parts** come from the library symbol. For a BGA or
  WLCSP part, check them against the datasheet's ball map once.

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
- **Read** with poppler: `pdftotext -layout <pdf> -` for tables, or the Read
  tool's `pages` for figures and ball maps.
- **A part with no datasheet of its own:** use a same-package proxy only after
  checking its package size and full pinout against the footprint and the
  netlist. Mark it as a proxy wherever it is cited. The MSM261DGT003 stands in
  for the DGT006 in `hw/nrf54lm20a/HARDWARE.md`; the DHT006, the closer name,
  was rejected for its pinout.

## 6. Licence

Commit **no generated netlist and no third-party design file**. Seeed's are
CC BY-SA 4.0, and this repo has no LICENSE. The script's output derives from
the design, so re-run it rather than saving it. For a third-party design, the
URL or archive name and its hash are the record. A design that already lives
in the repo is cited by its path.

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
