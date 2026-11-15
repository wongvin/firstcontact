---
name: hardware-design-review
description: Review a board's hardware design from its KiCad or Altium project (a project directory, archive or URL; an Altium project is first imported into KiCad with the user, through altium-netlist) — power tree and load path, always-on rails, regulator and PMIC strapping, debug access, USB, header pin map, peripherals, RF, DNP parts and variants, hazards, and a battery quiescent budget — producing a dated, standalone review report in hw/<mcu>/reviews/ with every fact tagged by source, plus the verified facts to merge into hw/<mcu>/HARDWARE.md. Use when asked to review a board, a KiCad or Altium design, or a schematic for firmware work.
---

A review asks the same questions of every board, deliberately. On the XIAO
boards reviewed so far (#384, #268, #319), the findings that mattered all came
from asking them, not from reading the schematic top to bottom:

- what is at the end of the radio's matching network;
- what a part marked DNP leaves disconnected;
- which GPIO a battery divider depends on;
- what idles on an always-on rail.

**The design can be KiCad or Altium.** Every question below is answered by
`kicad-netlist.py`, on KiCad files:

- **A KiCad design** is read as it is, through the `kicad-netlist` skill
  (`.claude/skills/kicad-netlist/SKILL.md`). Follow it for getting the design,
  `--check-pcb`, filters, `--draw`, `--copper`, source tags, datasheets and the
  licence rule.
- **An Altium design** is first turned into a KiCad one, through the
  `altium-netlist` skill (`.claude/skills/altium-netlist/SKILL.md`): you
  prepare a copy, the user runs KiCad's import on it, and you check the result.
  § 0 runs those steps; the user needs no KiCad files beforehand. After that,
  everything in `kicad-netlist` applies to the imported files, plus
  `altium-netlist`'s notes on values, variants and tags.

This skill adds the questions. Below,
`K=.claude/skills/kicad-netlist/kicad-netlist.py`, run from the repo root, and
`$SCH` / `$PCB` are the design's root `.kicad_sch` and `.kicad_pcb` (for an
Altium design, the imported ones). In PowerShell, set them as
`$K = ".claude/skills/kicad-netlist/kicad-netlist.py"` and so on; the commands
then run unchanged, except that `| grep X` is `| Select-String X`.

**Net queries take one of two forms, chosen in § 0 step 3.** In *schematic
mode* they run as written below, `python3 -I $K $SCH <filters>`. In *board
mode*, every net query adds `--pcb-nets $PCB`:
`python3 -I $K $SCH --pcb-nets $PCB <filters>`. `--values`, `--draw` and
`--copper` are the same in both.

**Pin names vary by symbol library, so search loosely first.** On the XIAO
nRF52840 (an Eagle import) the SWD pins are `SWDIO@AC24` and `SWDCLK@AA24`,
its LDO's pins are plain `IN`/`OUT`, and its charger's output isn't called
VBAT. Nordic names the clock `SWDCLK`, not `SWCLK`. The queries below therefore:

- start from a part's **exact reference**, which lists every net it is on;
- use the **contains** form `'NAME='`;
- anchor with `[` / `]` only to narrow a result that is too broad.

An empty result means only that nothing matched the name, never that the
function is absent.

## Input and output

**Input:** a KiCad or Altium project, as a URL, a local archive or a local
directory. Its files say which: a `.kicad_pro` with its `.kicad_sch` and
`.kicad_pcb` is KiCad; a `.PrjPcb` with its `.SchDoc` and `.PcbDoc` files is
Altium. If an archive or folder holds several projects, or both kinds, ask
which to review. Optional:
- the MCU and the firmware's intended use (battery-powered, USB-powered, which
  peripherals matter);
- the subproject it belongs to, e.g. `zephyr/sophon/`.

**Output: a review report that stands on its own**, at
`<subproject>/hw/<mcu>/reviews/<YYYY-MM-DD>-<board>-<revision>.md`, with its
figures in `reviews/figures/<YYYY-MM-DD>/`, the review's date, so that figures
from different reviews never mix. Write it as a draft in the scratchpad first, and
commit it when the user agrees.

**A report is frozen once committed**, like the original `*-PLAN.md` records.
It is a dated pass of this checklist over one design revision. Later
knowledge goes in HARDWARE.md, and the report is never edited, except for a
banner at the top when it has been overtaken.

**`hw/<mcu>/HARDWARE.md` stays the live record of the board.** It holds
verified facts only, and also what was measured on a real unit, which no design
review can produce. Where the two disagree, HARDWARE.md wins. The last step
below feeds the report's new facts into it.

The report's outline:

0. **Credits and licence for figures** (when the document has figures): the
   source's creator, design and revision, URL, the licence and its link, how
   the figures were changed, which figures are covered (†), and that only those
   are under the licence. The text is in `kicad-netlist` § 6.
1. **Where the authoritative data is**: the design (URL or archive, SHA-256,
   revision) and a datasheet table (part, ref, source URL, SHA-256, proxy or
   not). For an Altium design, also the KiCad version that imported it, and
   the messages the import showed.
2. **How each fact was established**: the tag table, the `--check-pcb`
   result, and the query mode (§ 0 step 3). In board mode, say why at the top
   of the report: `prepare`'s warning, or the split and merged nets.
3. **This board**: parts table (ref, part, role).
4. One section per checklist area below, in the same order.
5. **Corrections**, then **Not established**.
6. **For HARDWARE.md**: the verified facts and the leads (§ Merge into
   HARDWARE.md).

**Figures** go in `<subproject>/hw/<mcu>/reviews/figures/<YYYY-MM-DD>/`, made with
`--draw … --credit "<credit>"`. Each is marked † where the document uses it, and
gets a caption saying what it shows. Each section below that calls for a
drawing says which. For an Altium design, the credit names the Altium design
(its creator, URL and licence), and the imported KiCad files stay in the
scratchpad, uncommitted (`altium-netlist` § 7).

**Every fact carries a tag**: *netlist*, *PCB*, *datasheet* (with page or
table), or *PDF text*, plus *Zephyr* (with the file) for what the board's
devicetree or a driver does. In board mode, each connection is *PCB* and each
pin name *netlist*. A sentence without a tag is an inference; say so, or move
it to § Not established.

**A devicetree node acts only if its driver is built.** Before calling a
board-file node a hazard (e.g. a PWM node claiming a pin the board uses for
something else), check the application's built `.config`
(`build/zephyr/.config`, e.g. `# CONFIG_PWM is not set`). Report it as a hazard
only for builds that enable the driver.

## 0. Set up

1. **Get the design and check its revision.**
   - **KiCad:** `kicad-netlist` § 1. `$SCH` and `$PCB` are the project's root
     `.kicad_sch` and `.kicad_pcb`.
   - **Altium:** `altium-netlist` § 1–3, in order:
     1. Run `altium-netlist.py prepare` on the source, with `--out` a new
        folder in the scratchpad. The source is only read. Keep three things
        from its output: the SHA-256s, the title blocks, which give the
        revision (the imported title blocks can't), and any **WARNING**.
     2. Give the user the import guide (`altium-netlist` § 2), with the two
        paths `prepare` printed, and **stop until they report back**. Note
        every message they report.
     3. Run `altium-netlist.py check-import` on the import folder. Exit 0 is
        required; if a file is missing, ask the user to save it and run it
        again.

     `$SCH` and `$PCB` are then the imported root `.kicad_sch` and
     `.kicad_pcb`. Record the KiCad version that imported them: the root
     sheet's `generator_version` (e.g. `10.0`), or the full version from the
     user's *Help → About*.
2. **Validate:** run `--check-pcb` (`kicad-netlist` § 2).
3. **Choose the query mode** for every net query in the review:
   - **schematic mode** when `--check-pcb` passes, with 0 split and 0 merged,
     and `prepare` printed no WARNING;
   - **board mode** otherwise: connections come from the board through
     `--pcb-nets`, with the schematic's pin names (`altium-netlist` § 4). An
     Altium design with harnesses, or hidden pins that aren't power pins,
     always lands here. So does any design whose schematic and board
     disagree; then also list the disagreeing pads at the top of the report.
     When the only disagreement is a two-pin part with no polarity numbered
     the other way round (`kicad-netlist` § 2), say that the circuit is the
     same, and stay in board mode.
4. **Altium variants:** run `altium-netlist.py check-variants` (`altium-netlist`
   § 5) now, and carry each part it reports as differing to § 9.
5. **Decide what kind of review this is**, from `hw/<mcu>/reviews/`. Read only
   the earlier reports' file names, and the design's SHA-256 in each one's
   sources table (`grep -i sha-256`), not their findings. For an Altium
   design, the hash to compare is the archive's when it came as one, and
   otherwise the `.PrjPcb`'s, as `prepare` printed them:

   | Since the last review | Do |
   |---|---|
   | nothing: same design hash, same checklist | no review; say so, and point to the report and HARDWARE.md |
   | the checklist gained questions, same design | answer only the new questions, in a short dated report that names the full one it extends |
   | a new design revision, or no earlier review | a full review |

   Earlier answers are not reused. Fresh passes find what earlier ones missed:
   on the XIAO nRF54LM20A, a blind re-run found the INT1 drain and the R3/VSET
   mislabel that #384's review had missed.
6. **Read the board's HARDWARE.md and the previous report after the review, not
   before.** Then compare: each disagreement goes in § Corrections, with which
   side was right and why.

## 1. Parts and datasheets

```bash
python3 -I $K $SCH --values
```

- Every active part (U, Q, X, ANT, J/USB connectors, K, LEDs, ferrites on
  rails) goes in the parts table. **Name its role from the footprint and the
  part number, never from the reference designator.**
- On an Altium design, a passive's value is usually in `(ALTIUM_VALUE …)`;
  the plain value is Altium's Comment, often just the library part (`Res1`).
  Its footprint has no library prefix. The manufacturer's part number, which
  the datasheet search needs, is often in another Altium parameter (`MFGPN`,
  …): read the part's fields in the `.kicad_sch` (`altium-netlist` § 6).
- Fetch a datasheet (`kicad-netlist` § 5) for every IC and transistor. For
  crystals, ESD diodes, switches and connectors, fetch one only when a question
  below depends on it, e.g. the RF connector's type. For a part with none of
  its own, use a same-package proxy whose pinout matches the netlist, marked as
  a proxy everywhere.
- **A symbol's pin names can be wrong, not just different.** On the XIAO
  nRF54LM20A, the buck's symbol calls a pin `MODE` that the TPS62843
  datasheet calls `VSET`. Check each pin you rely on against the datasheet's
  pinout.
- For a WLCSP or BGA part, check the netlist's ball names against the
  datasheet's ball map. The part's exact reference lists every ball as
  `REF pin <ball> [<name>]`; compare that list with the datasheet's ball
  table, from `pdftotext -layout`, and report the count that agrees.
- Missing datasheets go in § Not established, by part.

## 2. Power

**Which rails exist, what makes each, and what does each feed?**

- Each regulator, PMIC, load switch and charger: its exact reference lists
  every net it is on. Its pins are read by name:
  ```bash
  python3 -I $K $SCH <REF>                  # every net that part is on
  python3 -I $K $SCH 'VIN=' 'VOUT=' 'EN=' 'VBUS=' 'VBAT=' 'VSYS='
  ```
- Each rail, by exact name, gives its loads:
  `python3 -I $K $SCH <RAIL>`.
- **Load path:** where USB power and battery power meet. That could be a
  charger IC, a PMIC with VBUS/VBAT/VSYS pins, a diode-OR, or a PMOS whose gate
  is on VBUS (`--values 'Q*' 'D*'`, then each one's nets). State which source
  feeds the loads with USB present and with it absent.
- **Always-on rails:** a rail is always on when its source's enable is tied, or
  pulled up, to a battery-derived rail rather than to a GPIO. Follow every
  `EN` net to its end. An always-on rail feeding a header pin powers whatever
  plugs into it.

## 3. Regulator and PMIC strapping

**What does each part do on power-up, before firmware runs?**

```bash
python3 -I $K $SCH 'VSET=' 'MODE=' 'NTC=' '[TS]=' 'SHIP=' 'SHPHLD=' 'ISET=' 'ILIM=' 'PRETERM=' 'LED='
python3 -I $K $SCH --values <R…> <R…>       # the strapping resistors found above
```

Map each strap to its effect from the datasheet's table: the default output
voltage, buck on or off, an NTC fixed or a real thermistor, the ship-mode exit,
the charge current, which LED driver mode applies. Then note what firmware later
overrides. For Zephyr, read the board's devicetree for the PMIC's properties.

## 4. Debug access

**Where does a probe connect, and what else is on those lines?**

```bash
python3 -I $K $SCH 'SWDIO=' 'CLK=' 'RESET=' 'SWD*' 'SWCLK*'
python3 -I $K --draw $PCB "<figures dir>" 'TP*' --credit "<credit>" --name probe   # the back view: a figure
```

A probe chip's side of the lines can carry neither name: the XIAO
nRF54LM20A's SAMD11 drives them from pins `PA02`/`PA03`, on nets called
`SWDIO`/`SWCLK`. Follow the MCU's SWD nets through any level shifter by the
shifter's exact reference, rather than searching for names.

- Identify each test pad by its **net**, then read its printed label off the
  `--draw` drawing (`kicad-netlist` § 3, Drawing the board). Report both, as a
  table of label, pad and net, plus the pattern that ties them (e.g. "each
  label to the left of its pad"). Show the user the back-view drawing: it is
  what they will match against the board in their hand.
- **An onboard probe** (a second MCU on the SWD nets, often via a level
  shifter):
  - **Powered** from where? Follow its supply pin to a source. Does it draw
    from the battery?
  - **Isolated** when off? Check the level shifter's `OE` (`'OE='`) and what
    drives it, then the datasheet for the outputs' state when disabled.
  - **Able to hold reset?** Follow its reset-control net. Is a gate pull-down
    present, so it can't assert reset when unpowered?

## 5. USB

**Which chip does the connector reach, and is the MCU's own USB wired?**

```bash
python3 -I $K $SCH <USB connector ref>               # the connector's nets
python3 -I $K $SCH 'D+=' 'D-=' 'DP=' 'DM=' 'DN=' 'VBUS=' 'DECUSB='
```

- Follow D+/D− from the connector through any series resistors to the chip
  they reach.
- For the MCU's own USB pins, a single-pin net is unconnected (confirm
  `unconnected-(…)` on the PCB; an Altium board gives such a pad no net at
  all, so it is missing from board-mode output). A DNP part on the path means "not fitted",
  not "wired".

## 6. Header and connector pin map

```bash
python3 -I $K $SCH --values 'J*' 'U*' 'P*'          # pick the header by footprint name
python3 -I $K $SCH <header ref>                      # the header part, exact
```

- Recognise the header by the footprint's **name**, the part after the colon.
  The library part, before it, can contain the board's name on every part
  (`Seeed Studio XIAO nRF52840 v1.1:…`), so a text search of whole lines finds
  everything. An Altium footprint has no library part: the whole field is the
  name.
- Map each header pin to its MCU pin and net, plus power, ground and VBUS.
- **A header can continue on pads.** The XIAO nRF54LM20A's D11–D18 are bottom
  test pads (TP11–TP18), not pins of the header part. Check the MCU pins the
  board files assign to the connector, and list where each one lands.
- Compare with the Zephyr board files, e.g.
  `~/zephyrproject/zephyr/boards/<vendor>/<board>/`: the connector `.dtsi`
  (`gpio-map`) and the pinctrl. A difference is a finding.

## 7. Peripherals

For each peripheral IC, its exact reference, then:

- **Bus:** SDA/SCL, SPI, PDM, UART pins, to which MCU pins, and which
  pull-ups, to which rail.
- **Address strapping:** SA0, ADDR, AD0 to GND or VDD, giving the address
  from the datasheet.
- **Mode pins:** e.g. CS held high selecting I²C.
- **Interrupts:** to which MCU pins, with pull-ups; which are unconnected.
  **For every pulled-up output, ask what it drives at idle:** its default mode
  (push-pull or open-drain) and active level, from the register defaults. A
  push-pull, active-high output idles low against its pull-up and draws V/R
  constantly. On the XIAO nRF54LM20A, the IMU's INT1 drew about 33 µA into a
  100 kΩ pull-up, more than everything else on the board (#389).
- **Supply:** which rail, through what filter, at what voltage, against the
  datasheet's range.

Compare with the devicetree node (`reg`, `int-gpios`, bus).

## 8. RF

**What is between the radio pin and the air?**

```bash
python3 -I $K $SCH 'ANT=' 'RF='                      # the radio pin's net
python3 -I $K $SCH "<REF> pin 2"                     # walk: each part's other pin, net by net
python3 -I $K $SCH --values <each part on the chain> # values and footprints
```

- Walk the matching network to its end, noting series and shunt parts and any
  DNP. A part whose other pin is on GND is a shunt: note it, and don't query
  that pin, which prints the whole ground net.
- The last part's **footprint** decides it: chip antenna, PCB antenna, or a
  connector such as U.FL or IPEX.
- Confirm on the PCB that no copper antenna exists, with `--copper`
  (`kicad-netlist` § 3): no zones and no copper graphics on the RF nets, and
  none with no net. A connector with no on-board antenna means the radio needs
  an external one.

## 9. DNP parts

```bash
python3 -I $K $SCH --values | grep DNP              # the list
python3 -I $K $SCH "<REF> pin 1" "<REF> pin 2"      # each one, both sides
```

For every DNP part that is not a test point, query both of its pins, and state
what it would connect, and therefore what is disconnected as built. Fitting it
is a board variant. **Draw where they are**, so someone fitting one can find its
pads: `--draw $PCB "<figures dir>" <each DNP ref> --credit "<credit>" --name dnp`. Each is
ringed and labelled with its pads' nets. Use the view of the side they're on
as a figure. Avoid `'(DNP)*'` here: a not-fitted part with a pin on GND
prints the whole ground net. A side on GND is a shunt; note it and don't print
it.

**Variants.** If the output ends by naming variants, the list above is the
default's. Repeat it with `--variant <NAME>` for each one, and report what each
fits or leaves off. On an Altium design, the default's list is usually empty:
Altium marks parts not fitted in its variants, so this is where fitting is
decided. Each part that § 0 step 4's `check-variants` reported as differing
is a finding: report Altium's answer for it, not `--variant`'s.

## 10. Hazards

**Is there anything firmware must do, or never do, for the board to be
safe?**

- **Dividers on the battery:** a resistor chain from VBAT whose low end is a
  GPIO. That pin must be held in a state, and the datasheet's absolute maximum
  on the ADC pin says which.
- **Back-feed:** pull-ups or I/O to a part on a switchable rail. Driving those
  pins high with the rail off powers the part through its clamps.
- **Pins with fitted loads:** e.g. NFC pins with capacitors, crystal pins, or
  strapping pins sampled at reset.
- **Unconnected GPIOs** are listed but are not hazards.

State "no hazard found" explicitly when that is the result.

## 11. Battery quiescent budget

**What does the board draw from the pack with the MCU asleep?**

List every part on a battery-derived or always-on rail, in the state it is in
on battery:

- regulator `IQ`, load switch off-current, a level shifter with one side
  unpowered;
- flash standby against deep power-down;
- a sensor in power-down;
- a microphone with no clock;
- resistive paths across the battery (V / R);
- **pull-ups held against an output that idles low** (§ 7), at V/R.

A part on a switchable rail has two states. Give both, and say which one the
firmware sets (or leaves at reset).

Each figure is from its datasheet, with the conditions (often at 1.8 V). Sum
the fixed parts, and name the dominant one. Flag parts whose low-power state
needs firmware, e.g. a flash that idles in standby unless sent to deep
power-down. Leave the MCU's own figure to § Not established unless measured.

## 12. Corrections and Not established

- **Corrections:** each earlier statement, in this repo's docs, the plans, or
  the vendor's material, that the review contradicts. Quote it, give the
  finding and its tag, and say how the error arose (PDF text, a reference
  designator, a missed DNP).
- **Not established:** what these sources cannot settle, each with what would
  settle it (a measurement, a missing datasheet, a part on the board).

## Report

Give the user the five or so findings that change what firmware or a user
must do: hazards, an antenna to fit, rails that can't be switched off, the
dominant sleep current, probe safety. The rest stays in the document.

## Merge into HARDWARE.md

End the report with **§ For HARDWARE.md**, sorting what it found into two
lists:

- **Verified:** new facts, and corrections to HARDWARE.md, each with its tag.
  These go into HARDWARE.md, each citing the report.
- **Leads:** claims not yet checked against their source, or that need a
  measurement. Verify each before it goes in, or list it in HARDWARE.md's
  § Not established.

Making the merge is its own piece of work, with its own issue. Don't edit
HARDWARE.md as part of the review. HARDWARE.md's sources table links the
report.
