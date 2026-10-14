# XIAO nRF52840 — battery voltage, as established

Everything here was established while implementing #268. It is separated from
`PROTOCOL.md` (which describes the wire format Sophon speaks) and from
`README.md` (which describes building and flashing) because it describes the
**board**, and would be true of any firmware running on it.

Several entries record things that turned out to be wrong on the first attempt.
Those are kept deliberately: each one produced a plausible result rather than an
error, which is the only reason they were worth an hour of measurement.

See also [BOOTLOADER.md](BOOTLOADER.md) for what occupies flash, the SWD
access path, and backup/recovery.

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

Pack **absence** stays undetectable, though not for want of a signature (#319).

**Why the reading wanders on USB: the charger's battery-detect routine.** With no
battery, the BQ25101 runs it continuously: it regulates `OUT` at `VO(REG)` 4.2 V,
then at `VREG-BD` = `VO(REG)` − 0.40 V (0.35–0.45 V) while sinking `IBD-SINK`
2 mA, for `tDGL(HI/LOW REG)` 25 ms each (datasheet SLUSBV8, Electrical
Characteristics, Battery Detect Routine; § 8.4.6). It also runs after each charge
termination, to tell a removed battery from a full one (§ 8.3.10). A reading's 8
conversions span ~70 ms, more than the 50 ms cycle, so its average lands anywhere
between the levels: that is the minute-to-minute wander of up to ~350 mV that
#319 was filed for.

Measured on VBAT at 40 µs acquisition, 8 conversions 10 ms apart:

| Board on USB | Levels | Step within one reading |
|---|---|---|
| no pack (`0FAA`) | 4.17–4.20 V / 3.76–3.79 V | 400–421 mV, every reading |
| 200 mAh pack (`86F0`) | 4.17–4.20 V / 3.83–4.04 V | 165–371 mV, varying; above 280 mV for minutes at a time |

**Tried and dropped:** reporting no reading when a reading's step exceeded a
threshold. With this pack the charger runs the routine much of the time, and the
pack's steps (up to 371 mV) come within ~30 mV of the no-pack ones. Even
requiring three such readings 500 ms apart blanked a fitted pack for 47 of 60
reads. A sturdier pack or connection would likely separate cleanly; the firmware
can't count on one. So on USB the board reports the average, flagged USB, and the
app labels it accordingly.

## The charger, and the pins that are not what they seem

`U2` is a **BQ25101**. The two variants differ on exactly one ball, C1: it is
**`PRE-TERM` on the BQ25100 and `/CHG` on the BQ25101** (TI SLUSBV8, Pin
Functions: "spins have different pin definitions"). The part is under the
module's shield, so the evidence is the schematics and the board's behaviour
(#323):

| | Sense Plus v1.1 schematic | Base v1.2 schematic |
|---|---|---|
| U2 | `Value = BQ25100`, on an Eagle-imported `BQ25101` symbol and footprint | **`BQ25101YFPT`**, an orderable part number |
| Ball C1 named | `PRETERM` | **`~{CHG}`** |
| Net `P0.17_~{CHG}` | U2.C1, R8 (DNP), P0.17 | **charge LED `CHG0` cathode**, R8 (DNP), P0.17, U2.C1 |
| `CHG0` anode | R5 (the parser leaves the LED unconnected on this sheet) | **R5 → 3V3** |

An LED from 3V3 onto C1 is the standard `/CHG` indicator. **On hardware**
(86F0, a Sense Plus, read over SWD without halting): P0.17 reads **low while
charging**, **high once the charge terminated with USB still in**, and **high
with no pack fitted** (3,000 samples over 3.55 s, no edges). The charge LED,
which is **green** (not red as drawn), follows it. A pin that tracked VBUS would
have stayed low at termination. So C1 is `/CHG` on the Sense Plus too, and the
v1.1 `BQ25100`/`PRETERM` labels are artefacts of the Eagle import. This file
said the opposite until #323, from those labels.

| Net | Lands on | Also on the net |
|---|---|---|
| `P0.17_~{CHG}` | `U2.C1` **`/CHG`**, open drain | green charge LED `CHG0` + `R5` to 3V3; `R8` → GND, **`DNP`** |
| `P0.13_HICHG` | `U2.B2` `ISET` | `R18` 2.7k, `R12` 2.7k to GND |
| — | `U2.B1` `TS` | `R20` 10k to GND — temp sense disabled per the sheet note |

**Reading `/CHG`.** Sophon reads P0.17 as an input **with the internal
pull-up**: with `/CHG` released, the LED and R5 pull the net only weakly toward
3V3, possibly below the nRF's logic-high threshold. The pull-up would be harmless
even on a BQ25100, since the LED already ties the net to 3V3. It is reported as
two bits in the battery flags (PROTOCOL.md § Battery frame):

| On USB | `/CHG` | Meaning |
|---|---|---|
| low | charging | the first charge cycle is running, so a pack is fitted and taking current |
| released | not charging | the pack is full, **or** no pack is fitted. The pin cannot separate them. |

The BQ25101 drives `/CHG` low for the **first** charge cycle only: a later top-up
of a full pack (refresh, § 8.4.7) leaves it released. Pack **absence** therefore
stays undetectable: neither `/CHG` nor the VBAT swing (§ Whether a pack is
fitted) separates it from a full pack.

**P0.13** selects charge current, through ISET: high-impedance → R18 alone,
2.7 kΩ ≈ **50 mA**; driven low → R18 ∥ R12 = 1.35 kΩ ≈ **100 mA** (the datasheet's
range, 13.5 kΩ for 10 mA to 0.54 kΩ for 250 mA, is about 135 mA·kΩ). Sophon
does not touch it, so the charger runs at 50 mA. Measured: a 200 mAh pack went
from ~60% to terminated in 1.7–3.3 h. Driving it **high** would push current
into ISET through R12 and disturb the setting; only low is meaningful.

## Power path: VBAT is not on the load path while USB is present (#319)

The 3.3 V rail comes from **U6**, a 3.3 V LDO (X2SON-4; the schematic gives
`Value = 3.3V` and no part number). Its input, `VIN`, is fed through a
diode-or of USB and the battery:

| Net | Members |
|---|---|
| `VBUS` | USB connector, charger `U2.IN`, **D1** anode, **Q1** gate, `R9` 100k, `U1.VBUS`, header 5V/VBUS pin |
| `VIN` | **D1** cathode, **Q1** source, `U6.IN`, `U6.EN`, `C4` 2.2 µF |
| `VBAT` | charger `U2.OUT`, `BAT0` pad, `C30` 2.2 µF, divider `R16`, **Q1** drain |
| `3V3` | `U6.OUT`, the nRF52840's VDD and VDDH, the header 3V3 pin (`U4.12`), which powers the Wio-SX1262 carrier |

`Q1` is a P-MOSFET whose gate is VBUS. **With USB present** its gate is high, so
it is off, and `VIN` comes from VBUS through `D1`. The board's whole load, the
SX1262 transmitting included, is drawn from USB and never passes through
`VBAT`. **With USB absent**, `R9` pulls the gate low, `Q1` turns on, and the
pack feeds `VIN`.

Consequences:

- On USB, a battery reading cannot sag under the board's own load: `VBAT` is the
  charger's output, loaded only by the pack (if any), `C30` and the 1.5 MΩ
  divider.
- **With no pack fitted, the charger drives just 2.2 µF and ~2.8 µA.** Whatever
  the reading does then is the charger's own output behaviour, not a battery.

Reproduce with `scripts/kicad-netlist.py '<sch>' VIN VBUS VBAT 3V3` and
`--values U6 Q1 D1 C30 C4 R9`. The base XIAO nRF52840's v1.2 schematic (sheet
`02 XIAO Header & nRF52840`) has the same members on `VBUS`, `VIN` and `VBAT`.

## ADC configuration

| | |
|---|---|
| Input | `AIN7` = P0.31 — fixed silicon mapping |
| Gain / reference | `ADC_GAIN_1_4` against the internal 0.6 V → 2.4 V full scale |
| Resolution | 12-bit |
| Acquisition time | **40 µs**, the SAADC's longest (#319) |

A 4.2 V pack presents `4.2 × 499/1499` = **1.42 V** at the pin: comfortable
headroom without waste. Gain 1/2 (1.2 V FS) would clip; 1/6 (3.6 V FS) would
discard a third of the resolution.

Note **AIN6 is P0.30, which the board uses for LED1** — the neighbouring channel
is already taken, so AIN7 is not merely free but the correct choice.

The board files declare **none** of this: no divider node, no named enable pin,
and `&adc` enabled with no channel children. All of it lives in `app.overlay`.

### Acquisition time: 40 µs, not the default

The source the SAADC sees is the divider's Thévenin resistance, 1 MΩ ∥ 499 kΩ ≈
**333 kΩ**, and nothing holds the node: `AIN7` carries only R16, R17, the pin
and the header (`kicad-netlist.py '<sch>' AIN7`).

The nRF52840 product specification sets the acquisition time by source
resistance ([§ SAADC, Acquisition time, Table 1](https://docs.nordicsemi.com/r/bundle/ps_nrf52840/page/saadc.html)):

| TACQ | Maximum source resistance |
|---|---|
| 3 µs | 10 kΩ |
| 5 µs | 40 kΩ |
| **10 µs** (Zephyr's `ADC_ACQ_TIME_DEFAULT`) | **100 kΩ** |
| 15 µs | 200 kΩ |
| **20 µs** | **400 kΩ**, the shortest that covers 333 kΩ |
| **40 µs** (chosen) | **800 kΩ** |

The base XIAO nRF52840's divider (R17 = 510 kΩ, § The battery divider differs)
is 1 MΩ ∥ 510 kΩ ≈ 338 kΩ, in the same row. The default is rated for a third of
either divider's resistance. 20 µs would meet
the table; 40 µs is chosen for margin, since R16 and R17 are 1% parts and nothing
on the node helps. It is also the longest the SAADC offers, so there is no
further step if a future divider goes higher: above 800 kΩ needs a capacitor on
the node or a buffer, not a longer acquisition.

At the 10 µs default the sampling capacitor did not charge in time, and readings
came out low by an amount that varied with the level:

| 86F0 | 10 µs | 40 µs | Reference |
|---|---|---|---|
| on its pack, no USB | 3.73–3.81 V | 4.03 V | 4.08 V on a meter at the pack terminals |
| charger regulating (`VO(REG)`) | 4.04–4.14 V | 4.17–4.20 V | 4.2 V nominal |

Every reading before #319 was taken at 10 µs, including the table under
§ Measurements.

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
**Taken at the 10 µs acquisition time, so they read low** (see § Acquisition
time), and the "USB, no pack" rows are averages of the charger's detect
waveform rather than voltages (§ Whether a pack is fitted). Since #319, the
same board reads 4.03 V on a pack metered at 4.08 V.

| Config | Condition | Reported |
|---|---|---|
| R17 = 510 kΩ | pack fitted | 4084, 4079, 4081 mV |
| R17 = 510 kΩ | USB, no pack | ~3940 mV |
| R17 = 499 kΩ | pack fitted, USB | 4143, 4134 mV |
| R17 = 499 kΩ | USB, no pack | 3889 mV |

The 510 kΩ and 499 kΩ figures are the same pin voltage scaled differently; only
the constant changed. Which is correct is still open — see the top of this file.

## Seeed Studio XIAO nRF52840 (formerly XIAO BLE): the LoRa gateway board

Everything above describes the **XIAO nRF52840 Sense Plus** (`Sophon-86F0`,
`Sophon-4D88`). This section describes the base board: **Seeed Studio XIAO
nRF52840** (SKU 102010448), sold earlier as **XIAO BLE**. It has **no IMU and no
microphone**. `Sophon-01A7` is one: it shipped in the XIAO nRF52840 &
Wio-SX1262 Kit, and it is the LoRa gateway in #303.

Sophon has one image for every board (LORA-PROTOCOL.md § Roles), built for
`xiao_ble/nrf52840/sense`. So this board runs Sense firmware that drives pins
for parts it doesn't have. The question this section answers (#303) is whether
that is harmless.

### Source

The base board's own KiCad project, from the [wiki's
resources](https://wiki.seeedstudio.com/XIAO_BLE/#resources):
**"XIAO nRF52840 v1.2.zip"**. That is revision **V1.2**, titled "XIAO
nRF52840", with three sheets. The nRF52840 and the header are on
`02 XIAO Header & nRF52840.kicad_sch`.

[`scripts/kicad-netlist.py`](scripts/kicad-netlist.py) reads one sheet and
ignores hierarchical connections, so it was run on that sheet alone. It was
first checked against the net whose answer is known: it reproduces the battery
divider topology, `VBAT – R16 – P0.31/AIN7 – R17 – P0.14`.

**This design file is not a BOM for the board.** It draws the IMU (`U3`,
LSM6DS3TR-C) and the microphone (`MIC1`) with no DNP flag, yet the fitted board
has neither: 01A7's IMU driver fails to initialise on every boot. Read it for
connectivity. What is actually fitted can't be read from it.

### The Sense-only pins are harmless here

| Pin | Net (V1.2 schematic) | What the Sense image does | On this board |
|---|---|---|---|
| **P1.08** | `6D_PWR`: C1 100 nF, R14/R15 10 kΩ I²C pull-ups, IMU VDD/VDDIO/CS | driven **high** at boot (`lsm6ds3tr-c-en`, `regulator-boot-on`) | feeds a capacitor and two pull-ups on idle-high lines; no load to fight |
| **P0.07 / P0.27** | `INTERNAL_I2C_SDA/SCL`: R15/R14 pull-ups, IMU SDA/SCL | `i2c0` at 400 kHz; TWIM only ever pulls low | nothing answers, so the IMU driver fails cleanly: the "no IMU" path |
| **P0.11** | `6D_INT1` → IMU INT1 | input | harmless |
| **P1.10** | `MIC_PWR`: C8, MIC1 VDD | microphone regulator, **not** boot-on, so held low | the mic stays unpowered |

Every pin is an input, an open-drain bus, or a supply feeding a capacitor and
pull-ups. Nowhere does this board drive a pin against another driver. That
agrees with 01A7 running the Sense image as a gateway, continuously, since
2026-10-09. Its boot log shows `LSM6DSL: Failed to initialize chip` and
`role: gateway (radio yes, IMU no)`, as intended.

### SWD test points: same as the Sense Plus

| Pad | Net | |
|---|---|---|
| TP1 | GND | B.Cu, the same 2×2 grid at 2.54 mm pitch as the Sense Plus (§ SWD access in BOOTLOADER.md) |
| TP2 | RESET (P0.18, shared with K1) | |
| TP3 | SWDCLK | |
| TP5 | SWDIO | |

The horizontal offsets match the Sense Plus exactly (16.51 mm and 19.05 mm from
the left edge). The vertical offsets weren't measured, because this PCB file's
`Edge.Cuts` layer carries drawings beyond the board outline. BOOTLOADER.md's
probe instructions apply unchanged. 01A7 was migrated, and is debugged, this
way.

### The battery divider differs: R17 is 510 kΩ

| | Sense Plus v1.1 | **XIAO nRF52840 V1.2** |
|---|---|---|
| R16 (upper) | 1 MΩ 1% | 1 MΩ 1% |
| R17 (lower) | **499 kΩ** 1% | **510 kΩ** 1% |

`app.overlay` carries the Sense Plus's 499 kΩ (§ The battery sense circuit),
because the image is shared. On this board the battery reading is therefore
about **1.5% high**, ≈60 mV at a full 4.2 V pack: the ratio is 1499/499 against
1510/510.

**Today that changes nothing.** As a gateway, this board serves the **sensor's**
relayed battery reading, not its own (LORA-PROTOCOL.md § How the gateway maps
onto the BLE protocol). It would matter only if a base board ran as a direct
board on battery. The fix then is a per-board divider value, which Sophon has
no mechanism for yet.

## Seeed Wio-SX1262 for XIAO: the LoRa board (#303)

The LoRa radio on both the sensor and the gateway. It is two things stacked: a
**carrier board**, "Wio-SX1262 for XIAO" V1.0, which plugs under a XIAO; and on
it, the **Wio-SX1262 module**, an SX1262 in a 12-pin SMT can. Both boards in
the XIAO nRF52840 & Wio-SX1262 Kit carry the same pin assignment, which is why
one image serves the sensor and the gateway.

### Sources

| Document | Contents |
|---|---|
| [Wio-SX1262 for XIAO V1.0 schematic](https://files.seeedstudio.com/products/113010003/Wio-SX1262%20for%20XIAO%20V1.0.pdf) | the carrier board: one sheet, KiCad 8. The kit wiki's "The Schematic Diagram of the SX1262 compatible with Xiao nRF52840" |
| [Wio-SX1262 Module Datasheet](https://files.seeedstudio.com/products/SenseCAP/Wio_SX1262/Wio-SX1262_Module_Datasheet.pdf) | the module: pinout, internal RF switch and TCXO, electrical ratings |
| [Kit wiki](https://wiki.seeedstudio.com/xiao_nrf52840&_wio_SX1262_kit_for_meshtastic/) | resources list, Meshtastic setup |

### The carrier board

| XIAO pin | nRF | Header | Net | Module pin | On the carrier |
|---|---|---|---|---|---|
| D0 | P0.02 | J1-1 | `D0` | — | footprints for a push button K1 to GND and a 10 kΩ pull-up R2, **not loaded on the kit**: see below |
| D1 | P0.03 | J1-2 | `LORA_DIO1` | 12 DIO1 | direct |
| D2 | P0.28 | J1-3 | `LORA_RST` | 5 NRST | **10 kΩ pull-up (R1)** |
| D3 | P0.29 | J1-4 | `LORA_BUSY` | 11 BUSY | direct, **no pull** |
| D4 | P0.04 | J1-5 | `LORA_SPI_NSS` | 6 NSS | 22 Ω series (R3) |
| D5 | P0.05 | J1-6 | `LORA_RF_SW1` | 1 RF_SW | direct |
| D6 | P1.11 | J1-7 | — | — | not connected |
| D7 | P1.12 | J2-7 | — | — | not connected |
| D8 | P1.13 | J2-6 | `LORA_SPI_SCK` | 4 SCK | 22 Ω series (R6) |
| D9 | P1.14 | J2-5 | `LORA_SPI_MISO` | 2 MISO | 22 Ω series (R4) |
| D10 | P1.15 | J2-4 | `LORA_SPI_MOSI` | 3 MOSI | 22 Ω series (R5) |
| 3V3 | — | J2-3 | `+3V3` | 8 VCC | 100 nF (C1); **the module runs from the XIAO's 3.3 V** |
| GND | — | J2-2 | `GND` | 7, 10 | |
| 5V | — | J2-1 | `VIN` | — | label only, unused |

This is the map `app.overlay`'s `lora0` node uses, taken from Meshtastic's
`seeed_xiao_nrf52840_kit` variant and now confirmed against the carrier's own
schematic. Two notes on it:

- **BUSY has no pull resistor.** With no Wio fitted, D3 floats, which is why
  the loramac-node driver's unbounded BUSY wait could hang a board with no radio.
  `src/role.c`'s presence check pulls BUSY **down** and reads the sync word
  first (LORA-PROTOCOL.md § Roles).
- **D0 is free on the kit's carrier.** The schematic draws a user button K1
  (to GND) and a 10 kΩ pull-up R2 on D0, but on carriers bought as the **XIAO
  nRF52840 & Wio-SX1262 Kit** (SKU 102010710), **K1 and R2 are not loaded**.
  That's from inspecting the kit boards (2026-10-11); the product page doesn't
  say. So D0 is as unconnected as D6 and D7, and #314's D0↔D0 jumper stands.
  **Check before driving D0 on a carrier from elsewhere:** one with K1 fitted
  would short a D0 output to GND whenever the button is pressed.

### The module

From the datasheet, and why each fact matters to the firmware:

| Fact | Value | In Sophon |
|---|---|---|
| Transceiver | Semtech SX1262, **DC-DC** regulator mode | the driver's default (`regulator-ldo` not set) |
| Reference | active **TCXO powered from DIO3**; its voltage must be ≥ 200 mV below VCC | `dio3-tcxo-voltage = <SX126X_DIO3_TCXO_1V8>`, 5 ms start-up; 1.8 V against 3.3 V |
| TX/RX switch | inside the module, **selected solely by DIO2**: high = transmit, low = receive | `dio2-tx-enable` |
| `RF_SW` (pin 1, D5) | "external IO control internal gate RF switch" | driven as `rx-enable-gpios`: high while receiving, low otherwise, as Meshtastic's RXEN. The datasheet doesn't detail this gate beyond the line quoted; the TX/RX selection itself is DIO2's. |
| Antenna | **U.FL (IPEX) on the module**, 50 Ω. The module's `ANT` pin is unconnected on the carrier | **attach the antenna before transmitting** |
| Frequency | 862–930 MHz | 915.0 MHz |
| TX power | 22 dBm max; **125 mA at 22 dBm** (typical) | presets use +14 dBm; V6/V6b use +22. The plan's ~118 mA figure is the bare-chip value; the module's is 125 |
| RX current | 7.6 mA at 125 kHz (typical) | slightly more at 500 kHz and with `rx-boosted` (≈ +2 mA, Zephyr binding) |
| Sleep | 1.62 µA | the loramac-node driver sleeps the radio after every completed send (`modem_release()` → `Radio.Sleep()`), so the sensor's radio sleeps between packets. The gateway's stays in continuous receive |
| Sensitivity | −136.73 dBm at SF12/125 kHz, including line loss | not a mode Sophon uses: at 500 kHz, ≈ −117 (SF7) and −120 dBm (SF8) (LORA-UPDATED-PLAN.md) |
| Supply | 1.8–3.6 V operating, 3.3 V typical | from the XIAO's 3V3 |
| Size | 11.6 × 11 × 2.95 mm, 12-pin SMT | — |

### Antenna and RF exposure

- **Never transmit without an antenna on the U.FL connector.** At +22 dBm an
  unterminated output reflects its power back into the PA.
- Both antennas vertical: polarisation mismatch costs up to about 20 dB
  (LORA-UPDATED-PLAN.md § Levers).
- For antenna gain and the FCC EIRP limit, the sensor is capped at 14 dBi at
  +22 dBm, and the receive-only gateway has no limit. See LORA-UPDATED-PLAN.md
  § Antenna gain and the FCC limit.
