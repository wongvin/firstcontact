# XIAO nRF54LM20A Sense — the board, as established

What the board *is*, independent of any firmware on it. Established while
backing up and inspecting the first board (#369), then reviewed from the
design source as a whole (#384), and reviewed again with the
`kicad-design-review` skill (#387; [report](reviews/2026-11-10-xiao-nrf54lm20a-v1.0.md), merged in #389), as
part of the nRF54LM20A port (#368; plan in
[NRF54LM20A-UPDATED-PLAN.md](../../NRF54LM20A-UPDATED-PLAN.md)).

Companion: [MEMORY-MAP.md](MEMORY-MAP.md) is what occupies RRAM, the SWD path,
the lock, and backups. The nRF52840 boards' equivalents are
[../nrf52840/HARDWARE.md](../nrf52840/HARDWARE.md) and
[../nrf52840/MEMORY-MAP.md](../nrf52840/MEMORY-MAP.md); what both share is in the
root [HARDWARE.md](../../HARDWARE.md) and [BOOTLOADER.md](../../BOOTLOADER.md).

As on the nRF52840, entries that were wrong on the first attempt are kept, with
the correction next to them.

## Where the authoritative data is

| Source | Contents |
|---|---|
| [KiCad project](https://files.seeedstudio.com/wiki/XIAO_nRF54LM20A/getting_start/RES/XIAO_nRF54LM20A_V1.0_SCH&PCB_260508.zip) | root sheet + six hierarchical sub-sheets, `.kicad_pcb`, `.kicad_pro`, `.step`. SHA-256 `ca7f509f5716c57dd0d9a3f3098e249d805c3037fc3d80fd5e7d3cf6e4f60ada` |
| [Schematic PDF](https://files.seeedstudio.com/wiki/XIAO_nRF54LM20A/getting_start/RES/XIAO_nRF54LM20A_Schematic.pdf) | KiCad 10 export, 7 pages. SHA-256 `f877501a6ff64b1fd9da15eb7df643c339f426869e8cf81ca4c727ec97260da3` |
| Zephyr board | `~/zephyrproject/zephyr/boards/seeed/xiao_nrf54lm20a/` (Zephyr v4.5.0, #379) |
| [Design review, 2026-11-10](reviews/2026-11-10-xiao-nrf54lm20a-v1.0.md) | the `kicad-design-review` report (#387): every checklist question, its figures (probe pads, DNP parts, RF chain), and how each finding was verified for this file (#389). Frozen; where it and this file disagree, this file is right |

**The archive name agrees with its contents** — unlike the nRF52840's (see
[HARDWARE.md § The archive naming is a trap](../../HARDWARE.md)). Every sheet's
title block reads **rev V1.0, 2026-04-09**, and so does the PDF ("First
Release", 12/18/2025).

Neither file is committed: a CC BY-SA design does not belong in a repo with no
LICENSE, the same rule as the flash backups. The URL and hash are the record.

### Datasheets

Local copies are in `zephyr/sophon/datasheets/`, gitignored like the others
(root [HARDWARE.md](../../HARDWARE.md)): not ours to redistribute.

| Part | Ref | Source | SHA-256 |
|---|---|---|---|
| nRF54LM20A/B datasheet v1.0 | U8 | the user's copy; Nordic's site refuses scripted downloads, so no URL is recorded | `9f8250bf…69df37` |
| LN237N3T5G MOSFET, Rev. D | Q1 | source not recorded | `73abb1ff…82291ec09` |
| nPM1300 PMIC, PS v1.1 | U2 | [mikroe mirror](https://download.mikroe.com/documents/datasheets/nPM1300_datasheet.pdf) of Nordic's | `570eb58d…2272c53d` |
| TPS62843x buck (TPS628438) | U1 | [ti.com](https://www.ti.com/lit/ds/symlink/tps62843.pdf) | `1ee02c11…0b257fa` |
| TPS22916 load switch | U3, U6 | [ti.com](https://www.ti.com/lit/ds/symlink/tps22916.pdf) | `a4d81b70…5b33f` |
| UM3204 level translator, Rev 1.6 | U4 | [union-ic.com](https://www.union-ic.com/upload/Datasheet/Datasheet_UM3204_Rev16.pdf) | `72e3e3bc…84b903` |
| PY25Q64HA 64 Mbit NOR | U10 | [LCSC](https://atta.szlcsc.com/upload/public/pdf/source/20260729/15366C88563C3BB4D6F82BB09E8E9043.pdf) | `d18f8a43…eb6bca` |
| SAM D11, Atmel-42363H (09/2016) | U5 | [microchip.com](https://ww1.microchip.com/downloads/aemDocuments/documents/OTH/ProductDocuments/DataSheets/Atmel-42363-SAM-D11_Datasheet.pdf) | `14de7783…4895471` |
| LSM6DS3TR-C IMU, DocID030071 Rev 3 | U11 | [st.com](https://www.st.com/resource/en/datasheet/lsm6ds3tr-c.pdf) | `251737db…6a1b2b` |
| MSM261DGT003 PDM microphone, v1.0 (2021-09-16) — **a proxy** | U12 | [DFRobot mirror](https://dfimg.dfrobot.com/5d57611a3416442fa39bffca/wiki/d2c58ceeebf0ab6a527b0c37c0ef525e.pdf) | `30fde830…3290b7` |

**U12's datasheet is a proxy.** The board fits an MSM261DGT006, which has no
datasheet here. MEMSensing's DGT003 matches its footprint and every pin: a
4 × 2 × 1.1 mm, 6-pin LGA, with VDD 1, GND 2/5, DATA 3, CLK 4, L/R 6. The
MSM261DHT006, the nearest name, was checked and rejected: a 4 × 3 mm, 8-pin
package with a different pinout. Both datasheets give the same currents, supply
range and timing, differing only in SNR. Figures for U12 below are the DGT003's.

### How each fact below was established

Every claim carries its source, because the first draft of this file did not,
and three of its statements turned out to be read off the PDF's *text layer* —
words that happened to sit near each other on the page — while being presented
as netlist facts. Two were wrong (§ Corrections).

| Tag | Meaning |
|---|---|
| *netlist* | resolved from the root `.kicad_sch` with the [`kicad-netlist` skill](../../../../.claude/skills/kicad-netlist/SKILL.md), across all sheets |
| *PCB* | read from the `.kicad_pcb`: a pad's net, a footprint, or silkscreen position |
| *datasheet* | the part's datasheet, from the table above, with the page or table |
| *PDF text* | from the PDF's extracted text only — weakest; not used for a conclusion here unless stated |
| *Zephyr* | what the board's devicetree or a driver does, with the file named; it acts only if the driver is built |

**The script is validated against the PCB.** #369 ran it one sheet at a time,
without power-symbol names, hierarchical labels, or the nRF54LM20A's six-unit
symbol, so U8's pins were read off the PCB instead (the tags *netlist + rail*
and *PCB* in that version). #384 extended it to resolve the whole design, and
added `--check-pcb`, which compares every pad's net against the PCB's:

| Design | Pads compared | PCB nets | Split | Merged |
|---|---|---|---|---|
| XIAO nRF54LM20A V1.0 | 466 | 117 | 0 | 0 |
| XIAO nRF52840 v1.1 | 266 | 74 | 0 | 0 |

That check found a bug in the old pin transform (rotation sign and mirror
order), wrong for parts both rotated and mirrored; the nRF52840 divider net it
was first validated on has none. Every #369 statement below was re-checked with
the fixed script, and all held. The script also flags Do Not Populate parts,
`(DNP)`, which is how R11, R23 and C40 below were found.

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

### Parts

*Netlist*, `--values`:

| Ref | Part | Role |
|---|---|---|
| U8 | nRF54LM20A (CSP98) | the MCU |
| U2 | nPM1300-CAAA | PMIC: charger, BUCK2, LDO1, ADC |
| U1 | TPS628438 | buck, `3V3_OUT` for the header |
| U3 / U6 | TPS22916CN (no quick output discharge) | load switches: SAMD11 supply / VBUS |
| Q1 | LN237N3T5G, N-channel | the SAMD11's reset control of the nRF54 |
| U5 | ATSAMD11D14A | CMSIS-DAP probe and UART bridge |
| U4 | UM3204 (value field `英联`, "Union") | 4-bit auto-direction level translator |
| U10 | PY25Q64HA | 64 Mbit (8 MB) QSPI NOR |
| U11 | LSM6DS3TR-C | IMU |
| U12 | MSM261DGT006 | PDM microphone |
| X1 / X2 | 32.768 kHz / 32 MHz | crystals |
| ANT2 | ECT818000500 | **IPEX Gen4 RF receptacle** (§ RF) |
| D2 | red LED | charge LED, on the nPM1300's LED1 |
| LED1 | FC-B1010RGBT-HG | RGB user LED |
| K1 / K2 | TS-1001S | reset / user button |

## The nRF54 has no USB, and no UF2 path

*Netlist:* the nRF54LM20A's USB block is not wired.

- `D+` (K5) and `D−` (K4) are single-pin nets (*PCB:*
  `unconnected-(U8B-D+-PadK5)` / `unconnected-(U8B-D--PadK4)`).
- `VBUS` (K7) reaches the board's `VBUS` only through **R23 (0 Ω), which is
  DNP**; on the board it has C34 alone.
- `DECUSB` (K6) has its decoupling capacitor C54 and nothing else.

The USB-C's data lines reach `SAMD11_USB_DP`/`_DN` through R5 (22 Ω); no USB
net reaches the nRF54. So:

- **the nRF54 has no USB on this board** — no CDC ACM console, no USB DFU, no
  mass storage — and no pads to add it. A board variant could fit R23, but D+/D−
  have no copper at all;
- **there is no UF2 path.** On #369's board no volume mounted, at plug-in or on a
  double-tap of reset. The SAMD11 presents CMSIS-DAP and one CDC serial port only.

*Zephyr:* the board file enables the USB controller regardless
(`zephyr_udc0: &usbhs { status = "okay"; }`, `nrf54lm20a_cpuapp_common.dtsi`).
As built, it can never enumerate.

## The SAMD11: probe, console bridge, and powered only from USB

*Netlist:*

| Net / part | Connects |
|---|---|
| **U3** (TPS22916 load switch) | `VSYS_3V3` → **`SAMD11_3V3`**. EN pulled down by R15 to GND, pulled up by R19 from **`VBUS`** |
| `SWDIO` / `SWCLK` | SAMD11 PA02 / PA03 → U4 (UM3204) A1 / A2 |
| `nRF54_SWDIO` | U4 B1 — **TP2** |
| `nRF54_SWCLK` | U4 B2 — **TP1** |
| `~nRF54_RESET` | U8 `nRESET` (F2), reset button K1, C47, D3, pull-up R26 — **TP4**; and Q1's drain |
| `nRF54_RST_CTL` | SAMD11 PA04 → Q1's gate, R17 (100 K) to GND. Q1's source is on GND: driving PA04 high pulls `~nRF54_RESET` low |
| `SAMD11_RX` / `SAMD11_TX` | SAMD11 PA05 / PA08 → U4 A3 / A4 → B3 / B4 = P1.11 / P1.10 (`uart20`) |
| U4 supplies | VCCA = `SAMD11_3V3`, VCCB = `VSYS_3V3` |
| U4 `OE` | on **`SAMD11_3V3`** itself, with U4's VCCA and U5's VDD. R16 (10 kΩ to GND) is a load on that rail, not a pull-down for OE; it likely discharges the rail when USB goes, since U3 is a TPS22916CN, the variant without quick output discharge (*datasheet* TPS22916 p1) |
| `SAMD11_USB_DP` / `_DN` | PA25 / PA24, the SAMD11's USB D+ / D−, through R5 / R4 (22 Ω) from the USB-C |
| `SAMD11_SWDIO` / `SWCLK` / `~RESET` | PA31 / PA30 / PA28 → TP8 / TP7 / TP6 — the SAMD11's **own** debug pads. Reset pulled up by R18 (100 K) |

*Datasheet* (SAM D11, § 4.3 and the I/O multiplexing table): the netlist's
ball-to-port names for U5 (ATSAMD11D14A-UUT, the 20-ball WLCSP) agree with the
ball map, all 20 balls. The pins have the functions this wiring needs:

- PA24 / PA25 are the USB `DM` / `DP` pins;
- PA30 / PA31 are SWCLK / SWDIO, and PA28 is `RESET`;
- the UART fits one SERCOM: TX on PA08 is SERCOM0 PAD[2] (its alternate
  function), and a USART TX must be PAD[0] or PAD[2]; RX on PA05 is SERCOM0
  PAD[3] or PAD[1], and RX may use any pad;
- PA02 / PA03 / PA04 are plain GPIOs here: the probe firmware drives the
  target's SWD lines and reset by software.

Its single supply, 1.62–3.63 V, covers `SAMD11_3V3`. Microchip still publishes
the 2016 Atmel edition as the SAM D11's datasheet.

What follows from it:

- **The SAMD11 runs only while USB VBUS is present.** On battery it is
  unpowered, so it **draws nothing from the pack**.
- **U4 is enabled only while the SAMD11 is powered** (OE follows
  `SAMD11_3V3`). With USB connected, an external probe on TP1/TP2/TP4 shares
  the nets with a live SAMD11 — one SWD session at a time.
- **With USB disconnected, U4's outputs are disabled, but not provably
  unloaded.** *Datasheet* UM3204: OE low puts the ports in the high-impedance
  state, and the part "disables all output ports when either VCC is switched off"
  (p11). But IOZ (±2 µA) is specified only for VCCA 1.65–3.6 V (p6), and each B
  port has an internal 10 kΩ pull-up to VCCB, i.e. `VSYS_3V3` (p11–12), which
  the datasheet doesn't say is disconnected at VCCA = 0. An external probe on
  TP1/TP2/TP4 sees no driver from the bridge either way. If the pull-ups stay,
  though, `nRF54_SWCLK` draws about 3.3 V / (10 + 14) kΩ ≈ 140 µA through the
  nRF54's 14 kΩ pull-down (*datasheet* nRF54LM20A p1278) (§ Not established).
- **An unpowered SAMD11 cannot hold the nRF54 in reset.** R17 keeps Q1's gate
  low, so Q1 is off without USB and `~nRF54_RESET` is left to R26 and the
  button.

### The back pads, by silkscreen

*PCB*, back silkscreen against pad positions:

| Silk label | Nearest pad | Net |
|---|---|---|
| `SWDIO` / `SWCLK` / `RST` | TP2 / TP1 / TP4 (1.1–1.7 mm) | **nRF54** |
| `SWDIO2` / `SWCLK2` / `RST2` | TP8 / TP7 / TP6 | **SAMD11** |

**An external probe for the nRF54 goes on the unsuffixed `SWDIO` / `SWCLK` /
`RST`.** The review's [back-view drawing](reviews/figures/2026-11-10/XIAO_nRF54LM20A-probe-back.svg)
shows every pad with its net. Each label is printed vertically, immediately
to the left of its pad: the nRF54's pads are the left pair of columns
(`SWDIO`/`RST` over `SWCLK`/`GND`), the SAMD11's the right pair
(`SWDIO2`/`RST2` over `SWCLK2`/`3V3`). **TP5, printed `3V3`, is `3V3_OUT`**,
the header's always-on rail (§ Rails), not the nRF54's supply `VSYS_3V3`, which
has no test pad. A probe sensing target voltage there reads 3.3 V either way,
since both rails are 3.3 V.

Every TP is flagged DNP in the schematic, which is ordinary for a test point:
it is a bare pad, with no part to place.

## Power

### Rails

*Netlist:*

| Rail | Source | Loads |
|---|---|---|
| `VBUS` | USB-C `TYPEC_5V` through U6 (TPS22916; EN from R41/R45) | nPM1300 `VBUS`, header pin 14, U3's EN via R19 |
| `VBAT` | the battery's `+` pad, TP9 | nPM1300 |
| `VSYS` | nPM1300 (U2) `VSYS` / `PVDD` | U1, LDO1's input (via R14), D2's anode (via R7) |
| `VSYS_3V3` | nPM1300 **BUCK2** (`VOUT2`, through L2) | the nRF54, U10 NOR, U3 → SAMD11, U4's VCCB, the RGB LED |
| `IMU&MIC_3V3` | nPM1300 **`LSOUT1/VOUTLDO1`** — LDO1 | `IMU_VDD` through FB3, `MIC_VDD` through FB4 |
| `3V3_OUT` | TPS628438 buck (U1) from `VSYS` | the XIAO header's 3V3 pin (pin 12) |
| `SAMD11_3V3` | U3 from `VSYS_3V3`, while `VBUS` is present | SAMD11, U4's VCCA and OE |

**The load path is the nPM1300's** — the counterpart of the nRF52840's #319
question. Every load hangs off `VSYS` or `VBUS`, never `VBAT`. The PMIC feeds
`VSYS` from `VBUS` while USB is present, charging the pack from it, and from
`VBAT` otherwise. There is no separate charger and no diode-OR, so the nRF52840's
"VBAT is not on the load path while USB is present" answer has no analogue to
trace here.

U1's EN is pulled up to `VSYS` by R36 (1 M), and R3 (249 K) on its **VSET** pin
sets `3V3_OUT` to **3.3 V** (*datasheet* TPS62843 Table 7-1, p11: "249.0k or
larger"; the symbol calls that pin `MODE`, § Corrections). **`3V3_OUT` is
therefore always on**, on battery too. Anything on the
header's 3V3 pin — a Wio-SX1262 included — is powered whenever the pack is, and
the nRF54 cannot switch it off.

### The nPM1300's configuration in hardware

*Netlist + datasheet:*

| Pin / function | Wiring | Means |
|---|---|---|
| `VSET2` | R10, 470 K to GND | BUCK2 starts at **3.3 V** (PS Table 19). BUCK2 is `VSYS_3V3` |
| `VSET1` | R9, 0 Ω to GND | BUCK1's default is off (PS Table 18). `VOUT1`, `SW1` **and `PVSS1`** are unconnected, where Nordic's one-buck reference ties the unused buck's VOUT to VSYS and its PVSS to GND (Figure 57, p159); whether that matters with BUCK1 off is § Not established |
| LDO1 input | from `VSYS` through R14 (0 Ω). R11 (0 Ω), the alternative feed from `VSYS_3V3`, is **DNP** | LDO1 runs from `VSYS`, not after BUCK2 |
| LDO1 mode | — | resets **off** (p72) and as a **load switch** (`LDSW1LDOSEL` = 0, p79): enabled as a switch it would put `VSYS` on the IMU and mic (§ Unconnected pins and hazards). Zephyr selects LDO mode |
| LDO2 | `LSIN2/VINLDO2` not connected | unused |
| `NTC` | R6, a fixed 10 K | no thermistor. The PS says the NTC function "must be disabled" then (p29). Zephyr's board sets `thermistor-ohms = <10000>`, so the charger reads a constant 25 °C instead, and JEITA limits do nothing. **Decision (#389): Sophon's overlay sets `thermistor-ohms = <0>`**, which Zephyr's charger driver turns into NTC disabled (`npm13xx_charger.c`), when Phase 4 enables the charger |
| `CC1` / `CC2` | both to GND | no Type-C detection: the VBUS current limit stays at **100 mA** until the host raises it (p21). Zephyr's `vbus-limit-microamp = <500000>` does that, once the charger driver is built |
| `SHPHLD` | TP21 only (a bare pad) | no ship-mode button; waking from ship mode needs that pad pulled low |
| `GPIO0` / `GPIO1` | P1.25 / P1.26 | available to firmware (interrupt or host signals) |
| `LED1` | D2 (red), anode from `VSYS` via R7 (10 K) | the charge LED |
| `LED0`, `LED2` | not connected | |
| I²C | P1.18 SDA / P1.17 SCL, pull-ups R12/R13 to `VSYS_3V3` | |

**The charge LED depends on firmware.** LED1 resets to *charging* mode
(LEDDRV1MODESEL `0x01`, PS p82), so D2 tracks charging in hardware on a blank
part. But Zephyr v4.5.0's board file sets `nordic,led1-mode = "host"`. Once the
nPM1300 LED driver initialises, D2 lights only when software drives it. Phase 4
decides between restoring `charging` for Sophon and driving it from
`battery.c`.

**The IMU is powered by the nPM1300, not by a GPIO.** That is consistent with
Zephyr's board file, which declares LDO1 `regulator-boot-on`, and with the
factory demo reading the IMU. Zephyr 4.4.99's file set LDO1 to 1.8 V on a rail
the schematic names `…_3V3`. **v4.5.0 sets 3.3 V in LDO mode**
(`97da33c77ad`: "LDO1 supplies the 3.3 V rail that powers the IMU and the PDM
microphone"). It also marks BUCK2 (`VSYS_3V3`) always-on, since it powers the
nRF54 and the SAMD11, and orders regulator init after the charger: LDO1's
soft-start inrush exceeds the PMIC's 100 mA power-up VBUS limit and would
brown-out boot-loop the board. Sophon requires v4.5.0 (#379), so it gets this
configuration from the board file.

### `power_en` (P1.12) drives nothing

*PCB:* P1.12 (U8 pad C4) is `unconnected-(U8D-P1.12-PadC4)`. Zephyr 4.4.99's
board file declared a `regulator-fixed` named `power_en` on `gpio1 12`,
`regulator-boot-on`, on a pin that goes nowhere on this V1.0 board. v4.5.0
removes it ("non-existent power_en node", `19d36c89cc5`). Nothing in Sophon ever
relied on it: the IMU rail is the nPM1300's.

### Battery quiescent draw

What the board draws from the pack with the nRF54 asleep, by part. This is
Sophon's intended state: BUCK2 on, LDO1 on at 3.3 V, the IMU in power-down and
the mic unclocked. On battery `VBUS` is absent, so U3 is off, the SAMD11 is
unpowered, and U6 has no input. Figures are typical, at the datasheet's
conditions.

| Part | State on battery | Typical | Source |
|---|---|---|---|
| **IMU INT1 against R38** | **INT1 idles driven low** (§ IMU) | **33 µA** (3.3 V / 100 kΩ) | *datasheet* LSM6DS3TR-C p47, Table 57; *netlist*; *Zephyr* `lsm6dsl.c` |
| **PY25Q64HA (U10)** | **standby** | **15 µA** (30 max; deep power-down 1.0 µA, 3 max) | *datasheet* p8 |
| LSM6DS3TR-C (U11) | power-down | 3 µA (`IddPD`, at VDD 1.8 V) | *datasheet* Table 4 |
| MSM261DGT006 (U12) | no PDM clock: sleep | 1 µA (`ISLEEP`, clock ≤ 50 kHz, at VDD 1.8 V) | *datasheet*, DGT003 proxy |
| nPM1300 (U2) | battery operation | 800 nA (`IQBAT`, specified with "no BUCK load, VBUS disconnected"); 500 nA hibernate, 370 nA ship | *datasheet* p16 |
| TPS628438 (U1) | always enabled, no load | 275 nA IQ (1.5 µA max) + 275 nA VOS input leakage at 3.3 V (450 max) | *datasheet* p6 |
| UM3204 (U4) | VCCB up, VCCA off | ≤ 1 µA (max only), unless its pull-ups stay connected (§ The SAMD11) | *datasheet* p6 |
| TPS22916 (U3) | EN low | 10 nA | *datasheet* |
| nRF54LM20A | firmware's choice | not established | |

**The IMU's INT1 dominates, then the NOR flash.** The fixed draw is about
**53 µA typical**: 33 + 15 + 3 + 1 + 0.8 + 0.55, plus up to 1 µA from U4. Both
large terms need firmware:

- **INT1, −33 µA:** set INT1 open-drain (`PP_OD` = 1) or active-low
  (`H_LACTIVE` = 1, with the GPIO's polarity to match). A Phase 3 task.
- **The flash, −14 µA:** Zephyr's board file leaves its node disabled, so
  nothing sends it the deep-power-down command, and it idles in standby.
  Putting it in DPD at boot is a Phase 3/4 task.

With both done, the board's fixed draw is about **6.4 µA**, plus the MCU; with
LDO1 off as well, about 2.4 µA. A Wio-SX1262 on the header adds 1.62 µA from
`3V3_OUT`, once firmware puts the SX1262 to sleep (*datasheet* Wio-SX1262 p6).
`VSYS_3V3` loads draw from the battery through BUCK2, scaled by the voltage
ratio and the buck's light-load efficiency, which isn't counted here.

## XIAO header pin map

*Netlist*, U7 (`XIAO-Add-On-Plus`); it matches Zephyr's
`seeed_xiao_connector.dtsi`:

| Pin | Signal | | Pin | Signal |
|---|---|---|---|---|
| D0 | P1.00 | | D6 | P1.08 |
| D1 | P1.31 | | D7 | P1.09 |
| D2 | P1.30 | | D8 | P1.04 |
| D3 | P1.29 | | D9 | P1.05 |
| D4 | P1.03 | | D10 | P1.06 |
| D5 | P1.07 | | 12 / 13 / 14 | `3V3_OUT` / GND / `VBUS` |

The **Plus** back row, pins 15–23, is D19–D27 = P0.00–P0.05 and P3.09–P3.11.
D11–D18 (P3.00–P3.07) reach TP11–TP18 only. Zephyr's `spi23`
(P1.04/P1.06/P1.05) and `i2c22` (P1.03/P1.07) use the standard pins, so **a
Wio-SX1262 lands entirely on port P1**.

## Peripherals

### IMU (U11, LSM6DS3TR-C)

*Netlist:*

| Pin | Wiring | Means |
|---|---|---|
| `SDA` / `SCL` | P0.08 / P0.07, pull-ups R28/R29 (4.7 K) to `IMU_VDD` | `i2c30` |
| `SDO/SA0` | GND | address **0x6A** (`1101010b`; DS p39) |
| `CS` | P3.12, R37 (100 K) pull-up to `IMU_VDD` | held high: I²C mode (1 = I²C enabled; DS p38) |
| `INT1` | P0.06, R38 (100 K) pull-up to `IMU_VDD` | the data-ready interrupt. **It idles driven low against R38**: INT1 is push-pull and active-high by default (`PP_OD` = `H_LACTIVE` = 0, DS Table 57) and "forced to ground" when inactive (p47), and Zephyr's `lsm6dsl` driver writes only BDU, BLE and IF_INC in `CTRL3_C`. So it draws ~33 µA whenever LDO1 is on, the largest sleep term (§ Battery quiescent draw) |
| `INT2` | not connected | |
| `SDx` / `SCx` | GND | the sensor-hub master pins, unused; Mode 1 says tie to VDDIO or GND (DS Table 2) |
| `VDD`, `VDDIO` | `IMU_VDD` = LDO1 through FB3 (120 Ω) | the pull-ups share the IMU's rail, at 3.3 V on v4.5.0: within VDD 1.71–3.6 V (DS Table 4). Absolute maximum 4.8 V on any pin (p29) |

**Caution: back-feeding.** Every pull-up sits on `IMU_VDD`. If firmware turns
LDO1 off to save power while the nRF54 drives P0.07, P0.08 or P3.12 high, the
IMU's I/O clamps power its rail from the GPIO. Release those pins (input,
no pull) before cutting LDO1. Nothing does today: v4.5.0 keeps LDO1 boot-on.

### Microphone (U12, MSM261DGT006)

*Netlist:* PDM `CLK` P1.13, `DATA` P1.14, `VDD` = `MIC_VDD` from LDO1 through
FB4. `L/R` is grounded: the mic asserts DATA on CLK's falling edge, and the
nRF54 latches it on the rising edge (*datasheet*, DGT003 proxy, p7). VDD
1.6–3.6 V covers LDO1's 3.3 V. With no clock it sleeps at 1 µA, and it
draws 670 µA at 2.4 MHz. Sophon does not use it.

### RF

*Netlist + PCB:* U8's `ANT` (E1) → L5 (3.6 nH) → C38 (1.2 pF) shunt → L6
(4.7 nH) → C39 (1.2 pF) shunt → L7 (2.2 nH) → **C40 (1.2 pF) shunt, DNP** →
R25 (0 Ω) → **ANT2**.

**ANT2 is an IPEX Gen4 receptacle (footprint
`IPEX-GEN4-SMD-1.7X1.7X1.0MM`), not an antenna.** The PCB has no chip antenna
and no copper antenna: no other RF footprint, no copper graphics, and its
keepout zones carry no net. **The radio needs an external antenna on that
connector**, as the Wio-SX1262 needs one on its own.

### NFC

*Netlist:* P1.01/`NFC1` and P1.02/`NFC2` (U8 J6/J7) → R39/R40 (0 Ω) → TP19/TP20,
each with a 300 pF shunt (C25/C26). They are **not on the XIAO header**; an
NFC coil goes on those two pads. The 300 pF loads make them poor GPIOs.

### Buttons and LEDs

*Netlist:* K1 is reset (`~nRF54_RESET`). K2 is the user button on P0.09, with
pull-up R27 and ESD diode D4. LED1 (RGB, common anode on `VSYS_3V3`) has
cathodes through R30/R31/R32; D2 is the charge LED (§ The nPM1300's
configuration).

### Unconnected pins and hazards

**No P0.14-style hazard.** On the nRF52840, P0.14 is the battery divider's low
leg and must be held low ([../nrf52840/HARDWARE.md](../nrf52840/HARDWARE.md)).
No pin here plays such a role, and no GPIO has to be in a particular state for the
board to be safe. 12 GPIOs are unconnected, P1.12 (`power_en`) among them; the
nRF54's D+/D− are unconnected too, but are not GPIOs (*datasheet* p790).

Two cautions, both about LDO1, the IMU/mic rail:

- **Back-feed**, above: release the IMU's pins before cutting LDO1.
- **Never enable LDO1 as a load switch.** It resets as one (*datasheet*
  nPM1300 p79), and its input is `VSYS`: the battery, up to 4.45 V, or 5 V
  with USB. Switched through, that would exceed the IMU's 4.8 V and the mic's
  4.0 V (proxy) absolute maximums. Zephyr's board file selects LDO mode
  (`regulator-initial-mode`), so the hazard is in any code that writes the
  nPM1300 directly, or an overlay that drops those properties.

There is no battery-voltage divider either: battery voltage comes only from the
nPM1300's ADC (Phase 4).

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
- **"Its `VBUS` (K7) and `DECUSB` (K6) are connected"** (#369). K7's link to
  `VBUS` is R23, which is DNP, and K6 has only its decoupling capacitor. Found by
  the DNP flag (#384).
- **"Chip antenna ANT2"** (the plan, #368). ANT2 is an IPEX Gen4 receptacle;
  the board has no antenna of its own. Read from its reference designator, not
  its footprint.

From the 2026-11-10 [design review](reviews/2026-11-10-xiao-nrf54lm20a-v1.0.md)
(#387), each verified in #389:

- **"The NOR flash dominates. The fixed parts sum to about 1.1–2.1 µA"** (#384).
  The IMU's INT1 pull-up dominates, at ~33 µA, about twice the flash. #384 noted
  R38 but never asked what INT1 drives at idle. The sum also left out the IMU's
  and mic's rows from its own table, and U1's VOS leakage.
- **"R3 (249 K) sits on its MODE pin"** (#369, #384). C1 is **VSET** (TPS62843
  Table 5-1), and 249 kΩ selects 3.3 V. The family has no MODE pin: the name
  came from Seeed's symbol, taken as the pin's function without checking the
  pinout.
- **"The only caution is the IMU back-feed"** (#384). Incomplete: LDO1's reset
  mode, load switch, is a second one (§ Unconnected pins and hazards).
- **"14 GPIOs are unconnected"** (#384). 12: the other two pads are D+/D−,
  which are not GPIOs. A count of pads, labelled as GPIOs.
- **"U4 `OE` | to `SAMD11_3V3`, R16 to GND"** (#369), and "TPS22916C". OE *is*
  on `SAMD11_3V3`, and R16 is a load on that rail, not OE's pull-down. U3/U6 are
  TPS22916**CN**, without quick output discharge.
- **"With USB disconnected, U4's B side is high-impedance"** (#384). Overstated:
  the datasheet's high-impedance figure assumes VCCA ≥ 1.65 V, and its B-port
  pull-ups aren't said to disconnect (§ The SAMD11; § Not established).

## Not established

- **Why the factory part was locked.**
- **Whether the kit ships with an antenna for ANT2, and what was on it in
  #370.** The BLE OTA test passed at desk range, which a bare receptacle can do.
  Phase 3's TX-power and range checks need a known antenna fitted.
- **The nRF54's idle current under Sophon.** The IMU's 3 µA and the
  microphone's 1 µA are typicals at 1.8 V; the board runs both at 3.3 V, and
  the mic's figure is from its proxy (DGT003). Measure the whole board on
  battery in Phase 3. LDO1's quiescent current and BUCK2's light-load
  efficiency aren't given in the PS either.
- **Whether U4's B-port 10 kΩ pull-ups stay connected with the SAMD11
  unpowered.** If they do, `nRF54_SWCLK` draws ~140 µA on battery
  (§ The SAMD11). Settle it in the same battery measurement, or with a meter on
  TP1: ~0 V means they're off.
- **How far the 32 kHz clock is off.** Zephyr's board sets the LFXO's internal
  capacitors to 17 pF (`load-capacitance-femtofarad = <17000>`), and X1's Value
  is `32.768KHZ-7PF-20ppm`. On either reading of the setting, the binding's
  "load capacitance" or the nRF54L formula's per-pin capacitor
  (`soc/nordic/nrf54l/soc.c`), the crystal sees more than 7 pF, which pulls it
  slow. X1's datasheet, or measuring LFCLK accuracy, settles how much.
- **Whether the floating `PVSS1` matters** with BUCK1 off (§ The nPM1300's
  configuration).
- **The ANT2 connector's datasheet** (ECT818000500). LCSC's copies return HTML
  to scripted downloads; the IPEX Gen4 type rests on the footprint.
