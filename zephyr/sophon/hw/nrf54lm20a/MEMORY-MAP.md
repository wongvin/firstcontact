# XIAO nRF54LM20A — memory map, SWD, the lock and backups

What occupies RRAM, how a probe reaches it, and how to read a board without
losing what is on it. Established in #369 (part of the port, #368; plan in
[NRF54LM20A-PLAN.md](../../NRF54LM20A-PLAN.md)).

Companion: [HARDWARE.md](HARDWARE.md) is what the board *is*. The nRF52840
equivalent of this file is [../nrf52840/MEMORY-MAP.md](../nrf52840/MEMORY-MAP.md); the headings
here follow it, so the two read side by side.

## Memory map

| Region | Address | Size |
|---|---|---|
| RRAM | `0x00000000` | `0x1FD000` = 2036 KB (FICR `INFO.RRAM` = `0x7F4`) |
| FICR | `0x00FFC000` | `0x1000` |
| UICR | `0x00FFD000` | `0x1000` |

### RRAM is not flash

| | nRF52840 flash | nRF54LM20A RRAM |
|---|---|---|
| Rewrite | bits only go 1→0; a page must be erased first | any line is rewritten in place; there is no erase |
| Write unit | 32-bit word | 128-bit line (16 B) |
| "Erase" | a real 4 K page erase, up to 89.7 ms | emulated — the driver writes `0xFF` (`nrf_rram_fill_impl`); the 4 K `erase-block-size` exists only for the flash API and MCUboot's sector math |
| Radio impact | erase stalls the CPU, hence `SOC_FLASH_NRF_PARTIAL_ERASE` (#271) | still radio-synchronised, but no long stalls; partial erase does not exist |
| Erased value | `0xFF` | `0xFF` |

An emulated erase is a full write, so it costs **wear**, not just time. The port
puts settings on ZMS rather than NVS and enables
`CONFIG_NRF_RRAM_FILL_SKIP_IF_FILLED` for that reason (plan, Phase 2). Endurance
figures are to be taken from the nRF54LM20A datasheet and recorded here; none is
assumed.

The MCUboot partition layout is #370's, and lands in § MCUboot on this board.

## SWD access

### Use the read-only config, not the board's

```bash
SDK=~/zephyr-sdk-1.0.1/hosttools/opt/openocd
$SDK/bin/openocd -s $SDK/share/openocd/scripts \
    -f zephyr/sophon/hw/nrf54lm20a/openocd-readonly.cfg \
    -c "init; sophon_ctrl_ap_status; exit"
```

[openocd-readonly.cfg](openocd-readonly.cfg) is Zephyr's
`boards/seeed/xiao_nrf54lm20a/support/openocd.cfg` with everything that can
change the part taken out: no flash bank, no RRAM write-enable proc, and above
all **no examine-fail handler**. Upstream's runs `nrf54l_mass_erase` by itself
when it finds the part locked — so its first connect to a locked board wipes it.
`west flash` and `west debug` use that file.

OpenOCD has no stock target script for the nRF54LM20A (the SDK's 0.12 ships
`nrf51.cfg` and `nrf52.cfg` only), so there was no neutral one to use. The
stock `nrf52.cfg` never had this problem: on a locked part it only prints a
warning and leaves `nrf52_recover` to a person.

### Which probe

| `SOPHON_PROBE_SERIAL` | Probe used |
|---|---|
| unset | the XIAO's onboard probe only, by VID:PID `0x2886:0x0068` |
| `<serial>` | exactly that adapter — onboard (`D9E2169F` on `Sophon-F9B0`) or an external Debug Probe |

Unset never picks up a Debug Probe (`0x2e8a:0x000c`) by accident; a wrong serial
fails with "unable to find a matching CMSIS-DAP device" rather than falling back.
All three cases checked on `Sophon-F9B0`.

The nRF52840 never needed this: its USB-C goes to the nRF52840, so the Debug
Probe was the only CMSIS-DAP adapter attached. Here the board brings its own.

**An external probe goes on the back pads silkscreened `SWDIO` / `SWCLK` /
`RST`** (TP2 / TP1 / TP4). The `…2` set beside them is the SAMD11's own.

**With USB connected, only one probe runs an SWD session at a time**: the SAMD11
is powered from VBUS and drives the same nets through U4. With USB disconnected
the SAMD11 is unpowered and U4's OE is low (HARDWARE.md § The SAMD11) — likely
the clean case for an external probe, pending the UM3204H datasheet, and the board
then needs power from its battery. The external path has not been tested yet.

### Reading never halts (#275)

`init` only — no `halt`, no `reset`. `dump_image` and `read_memory` go through
the debug port with the core running, as on the nRF52840. In a batch `-c`
script, `mdw` output is not printed; wrap `read_memory` in `echo`:

```
-c "init; echo \"CPUID: [read_memory 0xe000ed00 32 1]\"; exit"
```

## The lock

### Closed at every reset, by design

On the nRF54L the debug signals (TAMPC `DBGEN` / `NIDEN` / `SPIDEN`) are
**closed by hardware at every reset**. Firmware opens them: `SystemInit()` calls
`nrf54l_handle_approtect()` (nrfx `system_nrf54l_approtect.h`), and Zephyr's
default on the nRF54L is `CONFIG_NRF_APPROTECT_DISABLE` — "open at boot".

So:

- **A blank part is locked after every power-on.** No code runs to open it. On
  `Sophon-F9B0`, after an erase and a USB-C power cycle, memory reads were refused
  again with UICR still all-unprotected.
- **A board running a Zephyr image opens itself on every boot** — MCUboot's own
  `SystemInit` does it before the application runs. *Expected from the code; not
  yet verified on hardware (needs a write; #370).*
- **A board where neither MCUboot nor slot0 boots stays locked**, and the only way
  in is ERASEALL — which also wipes settings. On the nRF52840, UICR alone decided,
  so a broken image never cost debug access.

This is the main difference from the nRF52840, where UICR `APPROTECT` was the
whole story.

### How to tell

`sophon_ctrl_ap_status` decides by **trying a CPUID read** (`0xE000ED00`):
refused means locked. It also prints the CTRL-AP IDR (`0x32880000` on the
nRF54L) and register `0x0C` raw.

**CTRL-AP `0x0C` is not a lock indicator.** Upstream's lock check reads it and
treats a value below 1 as locked. On `Sophon-F9B0` it read `0x00000000` while
locked *and* after ERASEALL had unlocked the part. An earlier version of the
check trusted it, and #369's first findings comment reported "two independent
signs" of the lock on that basis; only the refused reads were evidence.

### Unlocking: CTRL-AP ERASEALL

The same sequence as upstream's `_nrf_ctrl_ap_recover`, on CTRL-AP (AP 2):
write `ERASEALL` (0x04) 0 then 1, poll `ERASEALLSTATUS` (0x08) for 1
(READYTORESET; 3 is ERROR), pulse `RESET` (0x00) 2 then 0, clear `ERASEALL`,
re-examine. On `Sophon-F9B0` it reached READYTORESET in about 400 ms, after which
the core examined (`Cortex-M33 r1p0`) and sat in HardFault lockup — what a
blank part does with no vector table.

**It wipes all of RRAM.** Run it only as a decision, never from a connect
handler.

**The part stays open only until the next power-on**, so flashing a blank or
locked board is **ERASEALL then write, in one session**. That is why upstream's
config recovers on connect; the read-only config deliberately does not.

### UICR after ERASEALL

`APPROTECT`, `SECUREAPPROTECT`, `AUXAPPROTECT`, `ERASEPROTECT` and `BOOTCONF` all
read `0xFFFFFFFF` — Nordic's "Unprotected". Non-`0xFF` words appear only in
reserved gaps of the layout, recorded raw and not interpreted:

```
+0x004 0x66665555  +0x008 0x88887777  +0x00C 0xAAAA9999   (and again +0x010..+0x018)
+0x024 0x9999AAAA  +0x028 0x77778888  +0x02C 0x55556666   (and again +0x030..+0x038)
+0x044 0x22221111  +0x048 0x44443333  +0x04C 0x66665555   (and again +0x050..+0x058)
+0x084 0x50FA50FA
```

`0x50FA50FA` is also the value Nordic's headers give for `ERASEPROTECT`
"Protected", but it sits at +0x084, a reserved word, not at `ERASEPROTECT`
(+0x060 / +0x07C).

## Backups

Kept in **`~/.sophon/backups/`**, outside the repo, as for the nRF52840 boards
(BOOTLOADER.md § Backup and recovery) — including running Time Machine after
taking one.

```bash
... -c "init;
        dump_image <prefix>_rram-2036KB.bin 0x00000000 0x1FD000;
        dump_image <prefix>_uicr-4KB.bin    0x00FFD000 0x1000;
        dump_image <prefix>_ficr-4KB.bin    0x00FFC000 0x1000;
        exit"
```

**Verify by dumping twice** and comparing SHA-256s. A locked part cannot be
dumped at all.

| Backup | What restoring it gives you |
|---|---|
| `Sophon-F9B0_20261029T020034Z_erased_{rram-2036KB,uicr-4KB,ficr-4KB}.bin` | the board immediately after ERASEALL: RRAM all `0xFF` (2,084,864 bytes), UICR as above |

SHA-256: RRAM `fad4813d58b48159dcce774e164e32ed7ecab719b60def2ba911869ec9540e9a`,
UICR `06f4af83fcd2659a91ad36d1bc18aa0504ef4f890668b4ba50e7f2587779ee28`,
FICR `74b1ecebaa3221abe4552317c4bc480b99c74768727bd21e05ed99f46dfa1f8d`.
Two dumps matched.

**There is no factory backup.** The part arrived locked, and unlocking erased it
(HARDWARE.md § Factory state). The FICR file is the board's identity record; it
survives an erase.

## MCUboot on this board

Not yet: #370. Upstream's partition table (`nrf54lm20_a_b_cpuapp_partition.dtsi`)
is the starting point — boot 62 K, slot0 and slot1 968 K each, storage 36 K —
and the plan splits storage into settings + reserved. This section gets the
final table, the flashing procedure, and MCUboot's measured size.

## Console

One port: `uart20` (P1.10 RX, P1.11 TX) through the SAMD11 bridge, 115200 8N1,
appearing on the Mac as `/dev/cu.usbmodem<serial>3` —
`/dev/cu.usbmodemD9E2169F3` for `Sophon-F9B0`. Use `cu.*`, not `tty.*`, as on
the nRF52840.

The bridge stays enumerated across nRF54 resets, so nothing is lost to
re-enumeration, and MCUboot can log on the same port with no overlay. But it is a
dev-board convenience: a production board will not have a SAMD11 (plan, *Design
constraint*), and nothing may depend on it.

## Hazards

- **Zephyr's `support/openocd.cfg` mass-erases a locked board on connect.** So do
  `west flash` and `west debug`, which use it. Read a board with something on it
  only through `openocd-readonly.cfg`.
- **A blank board relocks at every power-on.** Erase and write in one session.
- **Never build with `CONFIG_NRF_APPROTECT_LOCK=y`** (or
  `NRF_SECURE_APPROTECT_LOCK`): debug would stay shut on every boot, short of
  ERASEALL. Sophon relies on the nRF54L default.
- **One SWD session at a time while USB is connected.** The onboard SAMD11 and
  an external probe on `SWDIO` / `SWCLK` / `RST` (TP2 / TP1 / TP4) drive the same
  nets. The `…2` pads are the SAMD11's, not the nRF54's.

## Migrating a board

There is **no probe-free path** onto this board. It has no UF2 bootloader and the
nRF54 has no USB on the connector, so the nRF52840's `sophon-installer` approach
has nothing to install through. A board arriving locked or blank is migrated by
SWD: ERASEALL, then MCUboot and a signed image in the same session (#370 sets the
layout). The onboard probe makes that a USB-C cable on a dev board, but a
production board needs pads and an external probe.

## Not established

- That a Zephyr image keeps debug open across a power cycle (#370).
- RRAM write endurance, from the datasheet.
- The external Debug Probe path on TP1/TP2/TP4, untested; and whether U4's B
  side is high-impedance with OE low, as the USB-disconnected case assumes.
- What the patterned reserved UICR words are.
