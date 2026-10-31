# Hardware, as established

What the hardware *is*, as opposed to the wire format Sophon speaks
(`PROTOCOL.md`) or how it is built and flashed (`README.md`). True of any
firmware running on it.

**This file holds what is shared** (#373): how to establish a board's facts from
its design sources, learned on the XIAO nRF52840 in #268, and the Wio-SX1262
LoRa board, which both MCUs carry. Each MCU's own module is in its own file:
[hw/nrf52840/HARDWARE.md](hw/nrf52840/HARDWARE.md) (battery divider, charger,
power path, the plain XIAO gateway) and
[hw/nrf54lm20a/HARDWARE.md](hw/nrf54lm20a/HARDWARE.md).

Several entries record things that turned out to be wrong on the first attempt.
Those are kept deliberately: each one produced a plausible result rather than an
error, which is the only reason they were worth an hour of measurement.

See also [BOOTLOADER.md](BOOTLOADER.md) for what is shared about flashing and
recovery, and each MCU's `MEMORY-MAP.md` for what occupies its flash.

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

This is the map `boards/common/wio-sx1262.dtsi`'s `lora0` node uses, taken from Meshtastic's
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

#### No output power is specified as safe without an antenna

What the datasheets say about transmitting into a mismatched or open antenna
port:

| Source | Figure | What it means here |
|---|---|---|
| Semtech SX1261/2 datasheet Rev 1.2, Table 3-3, Operating Range | **VSWR ≤ 10:1** at the antenna port | about half the power reflected; this is the specified limit. An open U.FL reflects essentially all of it, far outside the range |
| Same, § 15.2, "Better Resistance of the SX1262 Tx to Antenna Mismatch" | the PA has an internal **clamp that backs off output power on over-voltage**, "to protect the internal devices and ensure long-term reliability" | some built-in self-protection. Semtech's workaround raises the clamp threshold, and says reliability "is guaranteed with or without" it |
| Zephyr's loramac-node driver, `sx126x.c:554` | applies that workaround: `TxClampConfig` (0x08D8) bits 4–1 set to `1111` | Sophon runs with the less protective clamp, which Semtech still calls reliable |
| Seeed Wio-SX1262 module datasheet | nothing on mismatch or running without an antenna | — |

So the SX1262 guards itself to a degree, but **no source gives an output power
that is safe with the antenna disconnected**. Stress rises with power. A brief
accidental transmission at +14 dBm is much less likely to harm the PA than
sustained transmission at +22 dBm, now the default preset (V6), but neither is
within specification.

#### Receiver input limits, and bench spacing

| Source | Figure |
|---|---|
| SX1261/2 datasheet Table 3-3 (Operating Range); Wio-SX1262 datasheet, Operating Range | RF input **≤ 0 dBm** for normal operation |
| SX1261/2 datasheet Table 3-2 (Absolute Maximum Ratings); Wio-SX1262 datasheet, Absolute Maximum Ratings | RF input **+10 dBm**, beyond which damage is possible |

Two boards close together can exceed those limits. Free-space path loss at
915 MHz is 20·log10(4πd/λ), with λ = 0.328 m. At +22 dBm, with roughly 2 dBi
on each antenna, the receiver sees approximately:

| Spacing | Path loss | Received |
|---|---|---|
| 10 cm | 11.7 dB | **+14 dBm**: above the absolute maximum |
| 30 cm | 21.2 dB | **+5 dBm**: above the operating limit |
| 1 m | 31.7 dB | −6 dBm: fine |

These are estimates, loosest at the shortest range, where the antennas are
within each other's near field. They fit the desk tests: at +22 dBm the
gateway's RSSI pegged at 0 dBm, the top of the scale.

**Bench rules:**

- **Attach the antenna before power, every time.**
- **With no antenna, terminate the port**: a 50 Ω U.FL load or an attenuator,
  not a low power setting.
- **At +22 dBm, keep the sensor and the receiver at least 1 m apart**, or
  lower the sensor's TX power for desk work.

Local copies of all three datasheets (SX1261/2, Wio-SX1262, BQ25101) are kept
in `datasheets/`, which is gitignored: they are not ours to redistribute.

### Receiver noise floor (#336)

Measured on 2026-10-22 with 0FAA (base XIAO + Wio-SX1262, the kit's
antenna) on firmware 2.31.1, which samples the radio's instantaneous RSSI
between packets (LORA-PROTOCOL.md § Noise floor; NOISE-FLOOR-PLAN.md). 20 one-second
windows per setup, no sensor transmitting unless noted, antenna in the same place:

| Setup | Noise min | Median of the window medians |
|---|---|---|
| Mac's USB-C, sensor 4D88 transmitting at 100% LQ | −108 dBm | −105.5 dBm |
| Mac's USB-C, nothing transmitting | −107 dBm | −105 dBm |
| USB power pack, no host | −106 dBm | −104 dBm |
| iPhone's USB-C, phone 30 cm or more away | −107 dBm | −105 dBm |
| iPhone's USB-C, **phone and cable laid against the antenna** | −107 dBm | −105 dBm |

- **The phone and its cable add nothing measurable,** even touching the
  antenna, and neither does the computer's USB.
- **The receiver's own floor is about −105 dBm**, about 6 dB above the
  −111 dBm estimate for 500 kHz with a 6 dB noise figure. That gap belongs to
  the SX1262 and the Wio carrier, or to how the chip reports RSSI. It
  shouldn't be read as interference.
- **A second sensor on the same channel raises the median sharply:** with 4D88
  and 86F0 both on air, the median read about −58 dBm, because one sensor's
  packets land in the other's gaps.
- The 2026-10-18 walk's inferred −104 dBm floor is the same receiver floor,
  not noise from the phone. On that walk the phone wasn't in the same pocket
  as the antenna anyway.
