# XIAO nRF52840 — battery, charger and power, as established

The XIAO nRF52840 module's own circuits: the battery divider, the charger, the
power path, the ADC, and the plain XIAO nRF52840 used as a gateway. Established
while implementing #268 and after; split out of the root
[HARDWARE.md](../../HARDWARE.md) unchanged when the nRF54LM20A joined (#373). The
root keeps how these facts were established, and the Wio-SX1262.

Companion: [MEMORY-MAP.md](MEMORY-MAP.md) is what occupies this board's flash.

## Design reviews

Both boards were reviewed from their KiCad source with the
`kicad-design-review` skill (#391). The reports are frozen records; their
verified findings are merged below, each citing its report. Where a report and
this file disagree, this file is right.

| Board | Design archive | Report |
|---|---|---|
| Sense Plus | [`Seeed_Studio_XIAO_nRF52840_Plus.zip`](https://files.seeedstudio.com/wiki/XIAO-BLE/Seeed_Studio_XIAO_nRF52840_Plus.zip), SHA-256 `f5e4e0e9…a99bdd9`. The file names say v1.1; the bundled PDF and folder say V1.0; there is no title block | [2026-11-12, Sense Plus v1.1](reviews/2026-11-12-xiao-nrf52840-sense-plus-v1.1.md) |
| plain XIAO nRF52840 (gateway) | [`260828_Seeed_Studio_XIAO_nRF52840_v1.2.zip`](https://files.seeedstudio.com/wiki/XIAO-BLE/Res/260828_Seeed_Studio_XIAO_nRF52840_v1.2.zip), SHA-256 `973a5543…511ea95`, title blocks V1.2, 2026-08-28 | [2026-11-12, V1.2](reviews/2026-11-12-xiao-nrf52840-v1.2.md) |

Both designs pass `--check-pcb` (266 and 252 pads, no split or merged nets).
The reports' figures show the SWD pads, the not-fitted parts and the RF chain.
The V1.2 report adds where the Sense-only parts would sit.

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
| `P0.31_AIN7_BAT` | `R16.2`, `R17.1`, `U1.A8` (P0.31/AIN7), and on the Sense Plus `U4.20`, an extra castellated pad: **the divider's midpoint is on the board's edge** ([review](reviews/2026-11-12-xiao-nrf52840-sense-plus-v1.1.md)). Not on the plain V1.2's header |
| `P0.14_~{READ_BAT}` | `R17.2`, `U1.AC9` (P0.14) |

| Part | Value | Note |
|---|---|---|
| R16 | **1 MΩ 1%** | upper leg, from VBAT |
| R17 | **499 kΩ 1%** in the Sense Plus KiCad archive / **510 kΩ 1%** in the `…_SCH_PCB_v1.1.zip` PDF (a v1.0 drawing) and in the plain V1.2 design | lower leg, to P0.14 |

Both `R0201`. The schematic's own note: *"Set P0.14 to output Sink only to enable
BAT voltage read"*.

**R17 is the open question.** 499 kΩ vs 510 kΩ is a **1.46%** difference in the
ratio — about 60 mV at a full pack, which reads as a perfectly ordinary battery
voltage. Sophon is configured for 499 kΩ. State it by archive, not by revision:
the archive with 499 kΩ is labelled v1.1 by its file names, but its own PDF and
folder say V1.0. Settle it by measuring the pack with a
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

On the plain V1.2, with R17 = 510 kΩ, the driven-high case is `3.3 + 0.9 ×
510/1510` = **3.604 V**: just *over* the 3.6 V absolute maximum (VDD + 0.3 V,
nRF52840 PS Table 173), not at it ([review](reviews/2026-11-12-xiao-nrf52840-v1.2.md)).

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
| Net `P0.17_~{CHG}` | **charge LED `CHG0` cathode**, R8 (DNP), P0.17, U2.C1 | **charge LED `CHG0` cathode**, R8 (DNP), P0.17, U2.C1 |
| `CHG0` Value | `RED` | `RED` (the LED measured green is on the Sense Plus, 86F0; V1.2's colour isn't established) |
| `CHG0` anode | **R5 → 3V3** (2.2 kΩ). The LED *is* connected; an earlier version of the parser left it unconnected ([review](reviews/2026-11-12-xiao-nrf52840-sense-plus-v1.1.md)) | **R5 → 3V3** |

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
| `P0.13_HICHG` | `R12` 2.7k, **in series** to the ISET net | — (only R12 and P0.13 are on this net) |
| ISET (unnamed) | `U2.B2` `ISET` | `R12` from P0.13; `R18` 2.7k to GND |
| `/CE` (a misleading label) | `U2.B1` **`TS`**; the BQ2510x has no CE pin | `R20` 10k to GND: TI's configuration when no thermistor is used ("a fixed 10-k can be placed between TS and VSS"), so charging is never temperature-limited |

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
into ISET through R12 and disturb the setting, and costs a continuous ~0.6 mA
(3.3 V across R12 + R18, 5.4 kΩ) on battery too. Only low is meaningful (both
reviews; the net table above was corrected by them).

Both variants regulate `OUT` to `VO(REG)` = **4.20 V**, so the BQ25100/BQ25101
question doesn't change the charge voltage (SLUSBV8 p3).

## Power path: VBAT is not on the load path while USB is present (#319)

The 3.3 V rail comes from **U6**, a 3.3 V LDO (X2SON-4) whose EN is tied to its
input, so **3V3 is always on** whenever VIN is: on battery, the header's 3V3
pin, and a Wio-SX1262 on it, are powered all the time. The two boards fit
different parts:

| | Sense Plus | plain V1.2 |
|---|---|---|
| U6 | `Value = 3.3V`; the symbol library names a **TLV733P** | **`SGM2040-3.3YUDH4G/TR`** (the symbol is still `TLV733P`) |
| Ground / quiescent current, no load | **34 µA** typ, 60 µA max (TI TLV733P) | **1.0 µA** typ, 1.5 µA max (SGM2040) |
| Q1 / D1 | no part numbers | `LP0404N3T5G` P-MOSFET / `SDM20U40-7` Schottky |

If the Sense Plus's U6 really is a TLV733P, it alone is about 90% of that board's
fixed sleep draw (§ Sleep current on battery). Its marking is not established.

Its input, `VIN`, is fed through a diode-or of USB and the battery:

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

Reproduce with `kicad-netlist.py '<sch>' VIN VBUS VBAT 3V3` and
`--values U6 Q1 D1 C30 C4 R9`. The base XIAO nRF52840's v1.2 schematic (sheet
`02 XIAO Header & nRF52840`) has the same members on `VBUS`, `VIN` and `VBAT`.
There is no reverse-polarity protection on the battery pads ([V1.2
review](reviews/2026-11-12-xiao-nrf52840-v1.2.md)).

## Sleep current on battery

What each board draws from the pack with the MCU asleep, excluding the MCU.
From the reviews, which give the per-part tables:

| | Sense Plus ([review](reviews/2026-11-12-xiao-nrf52840-sense-plus-v1.1.md) § 14) | plain V1.2 ([review](reviews/2026-11-12-xiao-nrf52840-v1.2.md) § 13) |
|---|---|---|
| Fixed draw, typical | **≈ 37 µA** (≤ 64 µA bound) | **≈ 22 µA** |
| Dominant term | U6 TLV733P, 34 µA | U7, the QSPI flash, in standby: ~18 µA (Puya P25Q16H as a proxy; U7's Value is empty) |
| With the flash in deep power-down | — (U7 not fitted in the design) | ≈ 4.5 µA |

**The QSPI flash.** Zephyr's board file declares a `p25q16h` on `&qspi`, and
Sophon's MCUboot build includes its driver (`CONFIG_NORDIC_QSPI_NOR=y`). That
driver enters deep power-down only through device power management, and Sophon
has no `CONFIG_PM_DEVICE`. So a fitted flash idles in standby. On the Sense
Plus the design marks U7 **not fitted** (Value `DNP`; P0.20–P0.25 reach only its
pads). Whether real units carry it isn't established (§ Not established).

**The IMU, not the board, sets the Sense Plus's sleep current as Sophon runs
today:** it streams at 52 Hz and is never powered down. The LSM6DS3TR-C's
datasheet gives 0.29 mA at 52 Hz in *low-power* mode (`IddLP`), and the part
powers up in high-performance mode. So expect more, roughly ten times the
board's own floor. Battery-life work starts there.

## ADC configuration

| | |
|---|---|
| Input | `AIN7` = P0.31 — fixed silicon mapping |
| Gain / reference | `ADC_GAIN_1_4` against the internal 0.6 V → 2.4 V full scale |
| Resolution | 12-bit |
| Acquisition time | **40 µs**, the SAADC's longest (#319) |

A 4.2 V pack presents `4.2 × 499/1499` = **1.40 V** at the pin (1.42 V with
R17 = 510 kΩ): comfortable headroom without waste. Gain 1/2 (1.2 V FS) would clip; 1/6 (3.6 V FS) would
discard a third of the resolution.

Note **AIN6 is P0.30, which the board uses for LED1** — the neighbouring channel
is already taken, so AIN7 is not merely free but the correct choice.

The board files declare **none** of this: no divider node, no named enable pin,
and `&adc` enabled with no channel children. All of it lives in `boards/xiao_ble_nrf52840_sense.overlay`.

### Acquisition time: 40 µs, not the default

The source the SAADC sees is the divider's Thévenin resistance, 1 MΩ ∥ 499 kΩ ≈
**333 kΩ**, and nothing holds the node: `AIN7` carries only R16, R17, the pin
and, on the Sense Plus, header pad 20 (`kicad-netlist.py '<sch>' 'AIN7*'`).

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
[`260828_Seeed_Studio_XIAO_nRF52840_v1.2.zip`](https://files.seeedstudio.com/wiki/XIAO-BLE/Res/260828_Seeed_Studio_XIAO_nRF52840_v1.2.zip),
SHA-256 `973a5543514b2a6799fdb658666a803c0694a784f21ef8633debbccd1511ea95`.
That is revision **V1.2**, titled "XIAO nRF52840", with three sheets. The
nRF52840 and the header are on `02 XIAO Header & nRF52840.kicad_sch`.

This section's findings were first made with an early
[`kicad-netlist.py`](../../../../.claude/skills/kicad-netlist/kicad-netlist.py), run on that one
sheet, with a pin-transform bug fixed later in #384. The [V1.2
review](reviews/2026-11-12-xiao-nrf52840-v1.2.md) (#391) re-ran the whole design: `--check-pcb` passes
(252 pads, 67 nets), and every V1.2 statement here held, apart from the
corrections now made in place (§ Corrections).

**This design file is not a BOM for the board.** It marks the IMU (`U3`,
LSM6DS3TR-C), the microphone (`MIC1`) and their support parts (C1, C8, R14, R15)
fitted; only R8 and C40 are DNP. Yet 01A7's IMU driver fails to initialise on
every boot. That shows nothing answers at 0x6A, not that the mic or the support
parts are absent. Read the file for connectivity; what is actually fitted can't
be read from it (§ Not established). The V1.2 review's last figure shows where
U3 and MIC1 would sit, to check a board by eye.

### The Sense-only pins are harmless here

| Pin | Net (V1.2 schematic) | What the Sense image does | On this board |
|---|---|---|---|
| **P1.08** | `6D_PWR`: C1 100 nF, R14/R15 10 kΩ I²C pull-ups, IMU VDD/VDDIO/CS | driven **high** at boot (`lsm6ds3tr-c-en`, `regulator-boot-on`) | feeds whatever of C1, R14, R15 is fitted, on idle-high lines; no load to fight either way |
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

The offsets match the Sense Plus: 16.51 mm and 19.05 mm from the TX/RX edge,
and 7.62 mm and 10.16 mm from the D0–D6 edge (*PCB*, [V1.2 review](reviews/2026-11-12-xiao-nrf52840-v1.2.md)).
Unlike the Sense Plus, **no silkscreen text names these pads**, so identify them
by position, seen from the back: TP5 (SWDIO) and TP2 (RESET) in the row nearer
D0–D6, TP3 (SWDCLK) and TP1 (GND) in the row nearer D7–D10. The review's back
view shows them. BOOTLOADER.md's probe instructions apply unchanged. 01A7 was
migrated, and is debugged, this way.

### The battery divider differs: R17 is 510 kΩ

| | Sense Plus v1.1 | **XIAO nRF52840 V1.2** |
|---|---|---|
| R16 (upper) | 1 MΩ 1% | 1 MΩ 1% |
| R17 (lower) | **499 kΩ** 1% | **510 kΩ** 1% |

`boards/xiao_ble_nrf52840_sense.overlay` carries the Sense Plus's 499 kΩ (§ The battery sense circuit),
because the image is shared. On this board the battery reading is therefore
about **1.5% high**, ≈60 mV at a full 4.2 V pack: the ratio is 1499/499 against
1510/510.

**Today that changes nothing.** As a gateway, this board serves the **sensor's**
relayed battery reading, not its own (LORA-PROTOCOL.md § How the gateway maps
onto the BLE protocol). It would matter only if a base board ran as a direct
board on battery. The fix then is a per-board divider value, which Sophon has
no mechanism for yet: #393.

## Corrections

From the 2026-11-12 design reviews ([Sense Plus](reviews/2026-11-12-xiao-nrf52840-sense-plus-v1.1.md), [V1.2](reviews/2026-11-12-xiao-nrf52840-v1.2.md), #391).
Each was checked against the netlist, the PCB or the datasheet before being
corrected in place above:

- **"`CHG0` anode | R5 (the parser leaves the LED unconnected on this sheet)"**
  (Sense Plus). The LED is connected: cathode on `P0.17_~{CHG}`, anode through
  R5 to 3V3, as on V1.2. An early parser version missed it.
- **"`P0.13_HICHG` | `U2.B2` `ISET` | `R18` 2.7k, `R12` 2.7k to GND".** The
  `P0.13_HICHG` net is only R12 and P0.13. R12 is *in series* to the ISET net,
  where R18 goes to GND, on both boards. The 50/100 mA prose had the topology
  right; only the table row was wrong.
- **"A 4.2 V pack presents 4.2 × 499/1499 = 1.42 V".** 1.40 V; 1.42 V is the
  510 kΩ figure. Sophon's overlay has the same stale comment: #393.
- **"U6 … the schematic gives `Value = 3.3V` and no part number"**, stated for
  both boards. True of the Sense Plus only, whose symbol names a TLV733P. V1.2
  gives `SGM2040-3.3YUDH4G/TR`.
- **"P0.14 driven high … = 3.60 V at 4.2 V — the limit".** True for 499 kΩ. On
  V1.2 (510 kΩ) it is 3.604 V, just over.
- **"Driving [P0.13] high would push current into ISET … only low is
  meaningful".** Incomplete: it also draws a continuous ~0.6 mA.
- **"`AIN7` carries only R16, R17, the pin and the header".** On V1.2 AIN7 is
  not on the header; on the Sense Plus it is extra pad 20.
- **"The vertical offsets weren't measured, because this PCB file's `Edge.Cuts`
  layer carries drawings beyond the board outline"** (V1.2). In the archive now
  recorded (`973a5543…`), `Edge.Cuts` holds only the outline, and the offsets
  are measured. #301 recorded no hash for its "XIAO nRF52840 v1.2.zip", so it
  may have read another file.
- **"the fitted board has neither"** (the IMU and mic, on V1.2). The design
  marks both, and their support parts, fitted. 01A7's boot log shows only that
  nothing answers at 0x6A. Which parts a plain board carries is now under
  § Not established.
- **R17 stated by revision ("499 kΩ (v1.1) / 510 kΩ (v1.0)").** The archive
  with 499 kΩ calls itself V1.0 in its own PDF. R17 is now stated by archive.

## Not established

- **R17 on real Sense Plus units** (§ The battery sense circuit): a meter on the
  pack against the reported voltage.
- **Whether real units carry the QSPI flash (U7)**, and, on V1.2, which part it
  is (its Value is empty; the review used the P25Q16H as a proxy). An MCUboot
  build's boot log on 86F0 and 01A7 shows the `p25q16h` init result, or read the
  JEDEC ID (9Fh). A fitted flash needs deep power-down for battery life.
  Sophon's build doesn't do that today (§ Sleep current on battery); an absent
  one means `&qspi` should be disabled.
- **Which Sense-only parts a plain V1.2 board carries** (U3, MIC1, C1, C8, R14,
  R15): look at the board's front, at the positions in the V1.2 review's last
  figure.
- **The fitted part numbers on the Sense Plus** for U6 (TLV733P by symbol), U2,
  Q1 and D1: read the markings. The TLV733P's 34 µA dominates that board's sleep
  draw only if it is really fitted.
- **The charge LED's colour on V1.2** (Value `RED`; 86F0's is green).
- **The IMU's real draw under Sophon**, and the nRF52840's own sleep current: a
  pack-current measurement. That measurement also bounds Q1's and D1's leakage.
- **P0.14 floats from reset until `sophon_battery_init()`**, all through
  MCUboot, so AIN7 sits above its absolute maximum through 1 MΩ during every
  boot. Driving P0.14 low earlier, in MCUboot, would close that window; whether
  it's worth doing is a judgement call.
- **`&reg0` is enabled** in Zephyr's board file, which sets DCDCEN0 with no
  inductor on DCCH. The PS says that's inert in normal voltage mode (VDDH tied to
  VDD, as here); `&reg0 { status = "disabled"; }` would remove the question.
- **The Wio-SX1262's SPI** runs at 8 MHz on P1.13–P1.15, which the nRF52840 PS
  lists as "Standard drive, low frequency I/O". Any effect on BLE or LoRa
  sensitivity would need an RF measurement.
- **The Sense Plus's extra pads 18/19** (P0.09/P0.10, printed RX1/TX1) stay in
  NFC mode unless `nfct-pins-as-gpios` is set, and none of the extra pads 15–23
  is in Zephyr's XIAO connector map.
- **ANT1's pad 3**: a ground or a tuning terminal. The antenna's datasheet
  (AN3216) isn't held.
