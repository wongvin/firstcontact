# XIAO nRF52840 — battery voltage, as established

Everything here was established while implementing #268. It is separated from
`PROTOCOL.md` (which describes the wire format Sophon speaks) and from
`README.md` (which describes building and flashing) because it describes the
**board**, and would be true of any firmware running on it.

Several entries record things that turned out to be wrong on the first attempt.
Those are kept deliberately: each one produced a plausible result rather than an
error, which is the only reason they were worth an hour of measurement.

## Where the authoritative data is

| Source | Contents |
|---|---|
| [KiCad project](https://files.seeedstudio.com/wiki/XIAO-BLE/Seeed_Studio_XIAO_nRF52840_Plus.zip) | `.kicad_sch`, `.kicad_pcb`, gerbers, and a **v1.1** PDF |
| [Symbol library](https://files.seeedstudio.com/wiki/XIAO-KiCad-Library/XIAO_Series_SCH_Symbols.zip) | `Seeed_Studio_XIAO_Series.kicad_sym` |
| [Schematic PDF](https://files.seeedstudio.com/wiki/XIAO-BLE/Seeed_Studio_XIAO_nRF52840_Plus_SCH_PCB_v1.1.zip) | a **v1.0** PDF, despite the archive's name |
| [Wiki](https://wiki.seeedstudio.com/XIAO_BLE/) | specifications table and a battery-reading FAQ |

### The archive naming is a trap

`…_SCH_PCB_v1.1.zip` contains a schematic of board revision **v1.0**. The KiCad
project archive contains **v1.1**. They disagree about a resistor value that
scales every battery reading, and nothing in either filename says so.

**Use the KiCad source.** It carries the netlist and the BOM outright. The PDF
carries component values only inside `/Annot` JavaScript actions, which have to
be matched to symbols by coordinate — inference dressed as evidence, and it
produced two wrong conclusions here (see P0.17, and R17 below).

### Extracting from the PDF, when that is all there is

Component values, shown as a pop-up on click in a viewer:

```bash
python3 - "Seeed Studio XIAO nRF52840 Plus v1.0.pdf" <<'EOF'
import sys, re
d = open(sys.argv[1], 'rb').read()
for m in re.finditer(rb'/JS \((?:[^()\\]|\\.)*\)', d):
    print(m.group(0).decode('latin-1'))
EOF
```

Net names and sheet notes are ordinary content-stream text. To view a page with
no extra tooling, macOS renders it with `qlmanage -t -s 6000 -o <dir> <pdf>`;
inserting a `/CropBox` into the page first zooms a region to full resolution.

### Extracting from the KiCad source

`.kicad_sch` is S-expressions. Symbol properties are direct; **connectivity is
not** — it must be computed from symbol placement, library pin offsets, wire
segments and label positions.

[`scripts/kicad-netlist.py`](scripts/kicad-netlist.py) does that, and is what
settled P0.17 after two wrong guesses from the PDF:

```bash
scripts/kicad-netlist.py 'Seeed Studio XIAO nRF52840 v1.1.kicad_sch' AIN7_BAT READ_BAT
scripts/kicad-netlist.py 'Seeed Studio XIAO nRF52840 v1.1.kicad_sch' --values R16 R17
```

Read its docstring before trusting it on another board: it handles a single
sheet and ignores hierarchical sheets, buses and no-connects. Every claim in this
file is reproducible with it, which is the point — the numbers below are not
asked to be taken on faith.

**No generated netlist is committed.** The script is ours; its output is a
derivative of a design that is CC BY-SA 4.0, and this repo is public with no
LICENSE. Re-run it instead.

## The battery sense circuit

```
VBAT ──[ R16 ]──┬──[ R17 ]── P0.14_READ_BAT
                │
          P0.31_AIN7_BAT
```

Netlist-derived, not read off a drawing:

| Net | Members |
|---|---|
| `VBAT` | `U2.A1` (charger `OUT`), `BAT0` pad, `C30.1`, `R16.1`, `Q1.1` |
| `P0.31_AIN7_BAT` | `R16.2`, `R17.1`, `U1.A8` (P0.31/AIN7), `U4.20` |
| `P0.14_~{READ_BAT}` | `R17.2`, `U1.AC9` (P0.14) |

| Part | Value | Note |
|---|---|---|
| R16 | **1 MΩ 1%** | upper leg, from VBAT |
| R17 | **499 kΩ 1%** (v1.1) / **510 kΩ 1%** (v1.0) | lower leg, to P0.14 |

Both `R0201`. The schematic's own note: *"Set P0.14 to output Sink only to enable
BAT voltage read"*.

**R17 is the open question.** 499 kΩ vs 510 kΩ is a **1.46%** difference in the
ratio — about 60 mV at a full pack, which reads as a perfectly ordinary battery
voltage. Sophon is configured for 499 kΩ. Settle it by measuring the pack with a
meter and comparing against what the board reports; see `TEST-PLAN.md` §5b.

## P0.14 must be held low. It is not a power-saving control.

This is the most important entry here, because the pin looks exactly like a
power-saving control and treating it as one is what creates the hazard.

Seeed's FAQ: *"When P0.14 is set HIGH, the battery voltage reading path is
disabled and P0.31 may reach the input voltage limit of 3.6V, posing a risk of
damaging the P0.31 pin."*

The arithmetic agrees. P0.14 is the divider's **low leg**, so:

| P0.14 | AIN7 sits at | Current from pack |
|---|---|---|
| driven low (enabled) | `Vbat × 499/1499` ≈ **1.4 V** at 4.2 V | 2.8 µA |
| driven high | `3.3 + (Vbat − 3.3) × 499/1499` = **3.60 V** at 4.2 V — the limit | 0.6 µA |
| high-impedance | pulled toward **Vbat** by R16; ESD clamp conducts | ~0.5 µA via the clamp |

There is **no safe released state**: nothing else holds the node down. Holding
P0.14 low costs ~2.8 µA — about 25 mAh a year, against a 200 mAh pack whose own
self-discharge is several times that.

### Consequences for Zephyr

- **Do not put the pin in the divider's `power-gpios`.** That property exists so
  the driver can release the pin between samples, which is the one thing this
  board must not do.
- Sophon declares it under its own binding (`dts/bindings/sophon,vbatt-enable.yaml`)
  and configures it `GPIO_OUTPUT_ACTIVE` once at init.
- `GPIO_ACTIVE_LOW` in the flags, so "active" means the pin sinks.

## What the board cannot tell you

### Remaining capacity

There is **no fuel gauge**. `U2` is a **BQ25101** — a charger. Nothing counts
charge in or out of the pack, so remaining mAh is not a quantity the hardware can
report.

Deriving it from voltage would be modelling, and the model is poor here: a LiPo
sits between roughly 3.7 V and 3.9 V for most of its usable discharge; a 52 Hz
IMU with an active radio sags the terminal voltage in bursts, biasing samples low
exactly when a connected peripheral would take them; and the curve shifts with
temperature and cell age.

Zephyr's own framing agrees — boards that report a battery figure from a divider
do it through `zephyr,fuel-gauge-composite`, i.e. a *composite estimate* layered
on a divider rather than a reading from one.

### Whether a pack is fitted

VBAT is the charger's `OUT`, the `BAT` pad and the top of the divider shorted
together. **No measurement at that node can say what is driving it** — a meter
cannot either.

The one discriminator is **VBUS**, read from the SoC with
`nrf_power_usbregstatus_vbusdet_get(NRF_POWER)`, a register read needing no
driver:

| VBUS | What may honestly be said |
|---|---|
| absent | the board is running off the pack, so the reading **is** the pack |
| present | the charger is holding VBAT; the reading is that net's voltage, and may or may not be a pack |

Pack **absence** stays undetectable.

## The charger, and the pins that are not what they seem

`U2` is a **BQ25101** per the wiki's specifications table, which lists it for all
XIAO nRF52840 variants. **The schematic contradicts itself**: `Value = BQ25100`,
while both the footprint and the library symbol say BQ25101. Neither is an
orderable MPN, there is no `MPN` property on the part, and `Datasheet` is empty.

| Net | Lands on | Also on the net |
|---|---|---|
| `P0.17_~{CHG}` | `U2.C1` **`PRETERM`** | `R8` → GND, **`DNP`** |
| `P0.13_HICHG` | `U2.B2` `ISET` | `R18` 2.7k, `R12` 2.7k to GND |
| — | `U2.B1` `TS` | `R20` 10k to GND — temp sense disabled per the sheet note |

**P0.17 is not a charge-status readback**, despite the `~{CHG}` name and its
active-low overbar. It lands on the charger's `PRETERM` current-programming
input, whose programming resistor is not fitted. This was mis-identified twice
from the PDF — once from the net name, once from where symbols sat on the page —
and only the netlist settled it.

That closes off the obvious refinement: `/CHG` would have distinguished "charging,
therefore a pack is present" from "not charging", but this board does not expose
it.

**P0.13** selects charge current: high-impedance ≈ 50 mA, driven low ≈ 100 mA
(wiki). Sophon does not touch it.

## ADC configuration

| | |
|---|---|
| Input | `AIN7` = P0.31 — fixed silicon mapping |
| Gain / reference | `ADC_GAIN_1_4` against the internal 0.6 V → 2.4 V full scale |
| Resolution | 12-bit |

A 4.2 V pack presents `4.2 × 499/1499` = **1.42 V** at the pin: comfortable
headroom without waste. Gain 1/2 (1.2 V FS) would clip; 1/6 (3.6 V FS) would
discard a third of the resolution.

Note **AIN6 is P0.30, which the board uses for LED1** — the neighbouring channel
is already taken, so AIN7 is not merely free but the correct choice.

The board files declare **none** of this: no divider node, no named enable pin,
and `&adc` enabled with no channel children. All of it lives in `app.overlay`.

### Accuracy

1% on each resistor bounds the ratio error at roughly **±1.35%** — about ±55 mV
at a full pack — before the SAADC's own gain and reference error. The reading is
good to a few tens of millivolts, **not** to the millivolt, despite the wire
format carrying mV. Present about two decimal places in volts and no further.

## Traps confirmed on hardware

**`CONFIG_PM_DEVICE_RUNTIME` is a global policy.** Enabling it to let the divider
driver release its enable GPIO changed the lifecycle of every device on the board
and stopped the LSM6DS3TR-C data-ready trigger firing — `no IMU sample for
400 ms` on repeat, forever, while init still reported success. Reaching for
system-wide power management to toggle one pin is the wrong scope.

**A sample takes ~70 ms.** Eight conversions spaced 10 ms apart, spread rather
than bursted so the mean straddles both the radio's transmit bursts and the quiet
between them. Reading the cached value on the line after `init()` returns the
not-yet-sampled sentinel and logs a confident `0 mV`.

**The uf2 runner does not match this board.** `board.cmake` passes
`--board-id=Seeed_XIAO_nRF52840_Sense`; the bootloader reports
`nRF52840-SeeedXiaoSense-v1`. `west flash -r uf2` fails and the copy fallback is
the working path. See `README.md`.

## Measurements

All from `Sophon-86F0`, a Sense Plus, bootloader UF2 0.9.2 dated Oct 15 2025.

| Config | Condition | Reported |
|---|---|---|
| R17 = 510 kΩ | pack fitted | 4084, 4079, 4081 mV |
| R17 = 510 kΩ | USB, no pack | ~3940 mV |
| R17 = 499 kΩ | pack fitted, USB | 4143, 4134 mV |
| R17 = 499 kΩ | USB, no pack | 3889 mV |

The 510 kΩ and 499 kΩ figures are the same pin voltage scaled differently; only
the constant changed. Which is correct is still open — see the top of this file.
