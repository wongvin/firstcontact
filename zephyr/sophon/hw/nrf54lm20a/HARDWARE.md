# XIAO nRF54LM20A Sense — the board, as established

What the board *is*, independent of any firmware on it. Established while
backing up and inspecting the first board (#369), as part of the nRF54LM20A port
(#368; plan in [NRF54LM20A-PLAN.md](../../NRF54LM20A-PLAN.md)).

Companion: [MEMORY-MAP.md](MEMORY-MAP.md) is what occupies RRAM, the SWD path,
the lock, and backups. The nRF52840 boards' equivalents are
[HARDWARE.md](../../HARDWARE.md) and [BOOTLOADER.md](../../BOOTLOADER.md).

As on the nRF52840, entries that were wrong on the first attempt are kept, with
the correction next to them.

## Where the authoritative data is

| Source | Contents |
|---|---|
| [KiCad project](https://files.seeedstudio.com/wiki/XIAO_nRF54LM20A/getting_start/RES/XIAO_nRF54LM20A_V1.0_SCH&PCB_260508.zip) | root sheet + six hierarchical sub-sheets, `.kicad_pcb`, `.kicad_pro`, `.step`. SHA-256 `ca7f509f5716c57dd0d9a3f3098e249d805c3037fc3d80fd5e7d3cf6e4f60ada` |
| [Schematic PDF](https://files.seeedstudio.com/wiki/XIAO_nRF54LM20A/getting_start/RES/XIAO_nRF54LM20A_Schematic.pdf) | KiCad 10 export, 7 pages. SHA-256 `f877501a6ff64b1fd9da15eb7df643c339f426869e8cf81ca4c727ec97260da3` |
| Zephyr board | `~/zephyrproject/zephyr/boards/seeed/xiao_nrf54lm20a/` (Zephyr 4.4.99) |

**The archive name agrees with its contents** — unlike the nRF52840's (see
[HARDWARE.md § The archive naming is a trap](../../HARDWARE.md)). Every sheet's
title block reads **rev V1.0, 2026-04-09**, and so does the PDF ("First
Release", 12/18/2025).

Neither file is committed: a CC BY-SA design does not belong in a repo with no
LICENSE, the same rule as the flash backups. The URL and hash are the record.

### How each fact below was established

Every claim carries its source, because the first draft of this file did not,
and three of its statements turned out to be read off the PDF's *text layer* —
words that happened to sit near each other on the page — while being presented
as netlist facts. Two were wrong (§ Corrections).

| Tag | Meaning |
|---|---|
| *netlist* | resolved from a `.kicad_sch` with `scripts/kicad-netlist.py`, **one sheet at a time** |
| *+ rail* | the script prints power symbols as bare `#PWR0xx`; the rail name was read from that symbol's `Value` property in the same sheet |
| *PCB* | read from the `.kicad_pcb`: a pad's net, or silkscreen position |
| *PDF text* | from the PDF's extracted text only — weakest; not used for a conclusion here unless stated |

The design is hierarchical, and the script neither names power symbols nor
follows hierarchical labels between sheets. It also mis-associates the pins of
the nRF54LM20A's multi-unit symbol (U8, units A–F), so anything on U8's pins is
taken from the *PCB* instead. Extending the script is the hardware review's
first task (#368).

## This board

| | |
|---|---|
| Tag | **`Sophon-F9B0`** — the low 16 bits of FICR `INFO.DEVICEID[0]`, as `src/ident.c` derives it |
| FICR `INFO.DEVICEID` | `0xF5F0F9B0 0x8F4F04C3` |
| FICR `INFO.RRAM` | `0x7F4` = **2036 KB** |
| FICR `INFO.RAM` | `0x200` = 512 KB |
| CPUID | `0x411FD210` (Cortex-M33 r1p0) |
| USB | `Seeed Studio XIAO nRF54LM20A CMSIS-DAP`, VID:PID `0x2886:0x0068`, serial `D9E2169F`, CMSIS-DAPv2, FW 2.0.0 |

All read from the board over SWD (#369).

**RRAM is 2036 KB, not 1.5 MB.** The Zephyr board doc (`doc/index.rst`) says
"1.5 MB RRAM"; the SoC dtsi says 2036 K. FICR settles it in favour of the dtsi.
The board's `.yaml` also says `flash: 449`, which matches neither and is not
used for anything here.

## The nRF54 has no USB, and no UF2 path

*PCB:* the nRF54LM20A's `D+` (K5) and `D−` (K4) pads are
`unconnected-(U8B-D+-PadK5)` / `unconnected-(U8B-D--PadK4)`. Its `VBUS` (K7)
and `DECUSB` (K6) are connected, but with no data lines that is not a USB port.

*Netlist, sheet 03:* the USB-C's `DP2` reaches `SAMD11_USB_DP` through R5 (22 Ω);
`DP1`/`DN1` go to local labels `DP`/`DN` on the same sheet. No `DP`/`DN`/USB label
appears on the nRF54 sheet.

So:

- **the nRF54 has no USB on this board** — no CDC ACM console, no USB DFU, no
  mass storage — and no pads to add it;
- **there is no UF2 path.** On #369's board no volume mounted, at plug-in or on a
  double-tap of reset. The SAMD11 presents CMSIS-DAP and one CDC serial port only.

## The SAMD11: probe, console bridge, and powered only from USB

*Netlist + rail, sheets 03 and 04:*

| Net / part | Connects |
|---|---|
| **U3** (TPS22916 load switch) | `VSYS_3V3` → **`SAMD11_3V3`**. EN pulled down by R15 to GND, pulled up by R19 from **`VBUS`** |
| `SWDIO` / `SWCLK` | SAMD11 PA02 / PA03 → U4 (UM3204H) A1 / A2 |
| `nRF54_SWDIO` | U4 B1 — **TP2** |
| `nRF54_SWCLK` | U4 B2 — **TP1** |
| `~nRF54_RESET` | Q1 drain — **TP4** |
| `SAMD11_RX` / `SAMD11_TX` | SAMD11 PA05 / PA08 → U4 A3 / A4 → B3 / B4 = P1.11 / P1.10 (`uart20`) |
| U4 supplies | VCCA = `SAMD11_3V3`, VCCB = `VSYS_3V3` |
| U4 `OE` | to **`SAMD11_3V3`**, R16 to GND |
| `SAMD11_SWDIO` / `SWCLK` / `~RESET` | TP8 / TP7 / TP6 — the SAMD11's **own** debug pads |

What follows from it:

- **The SAMD11 runs only while USB VBUS is present.** On battery it is
  unpowered, so it **draws nothing from the pack**.
- **U4 is enabled only while the SAMD11 is powered** (OE follows
  `SAMD11_3V3`). With USB connected, an external probe on TP1/TP2/TP4 shares
  the nets with a live SAMD11 — one SWD session at a time. With USB
  disconnected, U4's OE is low; whether its B side is then high-impedance is the
  UM3204H datasheet's to confirm, not yet checked.

### The back pads, by silkscreen

*PCB*, back silkscreen against pad positions:

| Silk label | Nearest pad | Net |
|---|---|---|
| `SWDIO` / `SWCLK` / `RST` | TP2 / TP1 / TP4 (1.1–1.7 mm) | **nRF54** |
| `SWDIO2` / `SWCLK2` / `RST2` | TP8 / TP7 / TP6 | **SAMD11** |

**An external probe for the nRF54 goes on the unsuffixed `SWDIO` / `SWCLK` /
`RST`.**

## Power rails

*Netlist + rail, sheet 03:*

| Rail | Source |
|---|---|
| `VSYS` | nPM1300 (U2) `VSYS` / `PVDD` |
| `VSYS_3V3` | nPM1300 **BUCK2** (`VOUT2`, through L2) — the nRF54's supply |
| `IMU&MIC_3V3` | nPM1300 **`LSOUT1/VOUTLDO1`** — load switch / LDO1 |
| `3V3_OUT` | TPS628438 buck (U1) from `VSYS` — the XIAO header's 3V3 pin |
| `SAMD11_3V3` | U3 from `VSYS_3V3`, while `VBUS` is present |

U1's EN is pulled up to `VSYS` by R36 (1 M), and R3 (249 K) sits on its MODE pin
to GND. U6 (a second TPS22916) passes the connector's VBUS to the `VBUS` rail,
with EN from R41/R45.

**The IMU is powered by the nPM1300, not by a GPIO.** That is consistent with
Zephyr's board file, which declares the nPM1300's LDO1 `regulator-boot-on`, and
with the factory demo reading the IMU. Zephyr's file sets LDO1 to **1.8 V** on a
rail the schematic names `…_3V3`; the LSM6DS3TR-C runs from either, but its I²C
pull-ups and logic levels then need checking (hardware review).

### `power_en` (P1.12) drives nothing

*PCB:* P1.12 (U8 pad C4) is `unconnected-(U8D-P1.12-PadC4)`. Zephyr's board file
declares a `regulator-fixed` named `power_en` on `gpio1 12`, `regulator-boot-on`;
on this V1.0 board that pin goes nowhere. It is harmless, but **nothing in
Sophon should rely on it** — the IMU rail is the nPM1300's.

## Factory state

As received, before #369 touched it:

- **Firmware:** Seeed's demo. On the console, about once a second:

  ```
  XIAO nRF54LM20A Demo, LED ON
  accel data:5.504688,-7.537989,3.007179gyro data: -0.004046,-0.053068,-0.004581
  XIAO nRF54LM20A Demo, LED OFF
  ```

  This shows the LSM6DS3TR-C powered and readable as shipped.
- **Locked.** The AHB-AP refused every memory read, so RRAM, UICR and FICR
  were unreadable. Unlocking is a CTRL-AP ERASEALL, which wipes RRAM, so **no
  copy of the factory image exists**. See [MEMORY-MAP.md § The lock](MEMORY-MAP.md).
- **Why it was locked is not known.** The factory UICR could not be read, and on
  this SoC a lock can come from UICR or from the running firmware's startup code
  leaving debug closed (MEMORY-MAP.md).

## XIAO header pin map

*PDF text + Zephyr pinctrl*, not netlist: D0 P1.00, D1 P1.31, D2 P1.30, D3 P1.29,
D4 P1.03, D5 P1.07, D6 P1.08, D7 P1.09, D8–D10 P1.04/P1.05/P1.06. The PDF's net
names (`P1.31/A1/D1`, …) and Zephyr's `spi23` (P1.04/P1.06/P1.05) and `i2c22`
(P1.03/P1.07) pinctrl agree. A Wio-SX1262 therefore lands entirely on port P1.
To be netlist-confirmed when the script follows sheets.

## Corrections

Kept, as on the nRF52840, because each read as plausible:

- **"The IMU and microphone share a switched rail from U3 (TPS22916), whose EN is
  presumably `power_en` P1.12."** Wrong twice. U3 switches the **SAMD11's**
  supply, enabled by VBUS; the IMU rail is the nPM1300's LDO1; and P1.12 is
  unconnected. The first version came from PDF text: `IMU&MIC_3V3` and U3's
  label sat close together on the page.
- **"`VSYS_3V3` comes from the TPS628438."** Wrong: it is the nPM1300's BUCK2;
  the TPS628438 makes `3V3_OUT`. Same cause.
- **"U4's OE is wired on — always enabled."** Incomplete: it is tied to
  `SAMD11_3V3`, so it is enabled only while USB powers the SAMD11.
- **The nRF54's pads were first given as "SWDIO2 / SWCLK2 / RST2"**, from PDF
  text. The silkscreen has both sets; `…2` marks the SAMD11's pads, and the nRF54's
  are the unsuffixed `SWDIO` / `SWCLK` / `RST`.
- **"The nRF54's D+/D− carry no net label"** was a label search, and only
  suggestive; the PCB now shows the pads unconnected.

## Not established

- **Whether U4's B side is high-impedance with OE low** — what an external probe
  on the nRF54 pads sees with USB disconnected (UM3204H datasheet).
- **LDO1 at 1.8 V on `IMU&MIC_3V3`**: what Seeed intended, and what the IMU's
  I²C pull-ups (R28/R29, 4.7 K) are tied to.
- **The XIAO header pin map from the netlist** (above, from PDF text + pinctrl).
- **Why the factory part was locked.**
