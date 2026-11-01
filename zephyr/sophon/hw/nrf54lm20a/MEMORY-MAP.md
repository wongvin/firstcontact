# XIAO nRF54LM20A — memory map, SWD, the lock and backups

What occupies RRAM, how a probe reaches it, and how to read a board without
losing what is on it. Established in #369 (part of the port, #368; plan in
[NRF54LM20A-UPDATED-PLAN.md](../../NRF54LM20A-UPDATED-PLAN.md)).

Companion: [HARDWARE.md](HARDWARE.md) is what the board *is*. The nRF52840
equivalent of this file is [../nrf52840/MEMORY-MAP.md](../nrf52840/MEMORY-MAP.md); the headings
here follow it, so the two read side by side.

## Memory map

Not to a shared scale; each column is internally proportional only.

```
        A: UPSTREAM TABLE            B: SOPHON MCUBOOT (in use, #370)
           (board file)                 (storage split as in #329)

0x1FD000 ┌──────────────────┐  0x1FD000 ┌──────────────────┐
         │ storage    36 KB │           │ reserved   28 KB │
         │                  │  0x1F6000 ├──────────────────┤
         │                  │           │ settings    8 KB │
0x1F4000 ├──────────────────┤  0x1F4000 ├──────────────────┤
         │ slot1 "image-1"  │           │ slot1 "image-1"  │
         │        968 KB    │           │        968 KB    │
         │                  │           │ DFU target       │
         │                  │           │ image at +4 KB   │
0x102000 ├──────────────────┤  0x102000 ├──────────────────┤
         │ slot0 "image-0"  │           │ slot0 "image-0"  │
         │        968 KB    │           │        968 KB    │
         │                  │           │ smp_svr test     │
         │                  │           │ 194 KB   (20.1%) │
0x010000 ├──────────────────┤  0x010000 ├──────────────────┤
         │ unassigned  2 KB │           │ unassigned  2 KB │
0x00F800 ├──────────────────┤  0x00F800 ├──────────────────┤
         │ mcuboot    62 KB │           │ mcuboot    62 KB │
         │                  │           │ 38.3 KB  (61.9%) │
0x000000 └──────────────────┘  0x000000 └──────────────────┘
```

**Column B is what runs today** (#370). Column A is the table Zephyr's board
file brings in (`nrf54lm20_a_b_cpuapp_partition.dtsi`); B keeps its boot
partition and slots exactly and splits only its 36 KB storage, as #329 split the
nRF52840's: **`settings_partition`** at `0x1F4000`, 8 KB (two sectors), for the
config record, and **`reserved_partition`** at `0x1F6000`, 28 KB, unassigned and
kept erased. The image figures are the `smp_svr` test's on Zephyr v4.5.0
(#379): MCUboot as built, 39,268 B, and the signed app, 198,948 B. They stand
until the Sophon app runs here (Phase 3).

**The 2 KB at `0xF800`–`0xFFFF` belongs to nothing.** Upstream sizes
`boot_partition` at 62 KB, for FPROTECT (§ MCUboot on this board), but starts
slot0 at the next 64 KB boundary.

**There is no factory column**, unlike the nRF52840's. The board arrived locked,
so its factory layout could not be read, and unlocking erased it (#369,
HARDWARE.md § Factory state).

Above RRAM, Zephyr's devicetree has no node until the configuration and
information registers at `0xFFC000` (checked across the SoC and cpuapp
`.dtsi` files). Column C's top boundary is where the reads stopped, not a known
end of the region:

```
         C: ABOVE RRAM

0x1000000 ┌──────────────────┐
          │ undefined        │
          │ SWD read fails   │
 0xFFF000 ├──────────────────┤
          │ SICR        4 KB │
          │ secure-only;     │
          │ SWD read fails   │
 0xFFE000 ├──────────────────┤
          │ UICR        4 KB │
          │ user config      │
 0xFFD000 ├──────────────────┤
          │ FICR        4 KB │
          │ factory info     │
 0xFFC000 └──────────────────┘
```

| Region | Address | Size | Over SWD (unlocked) |
|---|---|---|---|
| RRAM | `0x00000000` | `0x1FD000` = 2036 KB (FICR `INFO.RRAM` = `0x7F4`) | read and written |
| *(nothing in the devicetree)* | `0x001FD000`–`0x00FFBFFF` | | not tried |
| FICR | `0x00FFC000` | `0x1000` | read (#369) |
| UICR | `0x00FFD000` | `0x1000` | read (#369) |
| SICR | `0x00FFE000` | `0x1000` reserved; 4 B defined | **read fails** |
| *(undefined)* | `0x00FFF000` | | **read fails** |

### SICR

`0x00FFE000`, the region after UICR. All that is known, from Nordic's MDK
(`nrf54lm20a_types.h`, `nrf54lm20a_global.h`) and from the board:

- **Defined as one reserved, read-only word.** `NRF_SICR_Type` is a single
  `__IM uint32_t RESERVED`, size 4 bytes; no fields are documented. Its
  `@brief` repeats FICR's ("Factory Information Configuration Registers"), so
  the header gives no reliable expansion of the name, and none is assumed here.
- **Secure address only.** The MDK defines `NRF_SICR_S_BASE` and maps `NRF_SICR`
  to it, with no non-secure alias. FICR, by contrast, is defined at its
  non-secure address (`NRF_FICR_NS_BASE`).
- **Not in Zephyr's devicetree**, which has `ficr@ffc000` and `uicr@ffd000` and
  nothing at `0xffe000`. Nothing Sophon builds refers to it.
- **Not readable over SWD.** On `Sophon-F9B0`, running Zephyr and unlocked
  (CPUID read back in the same session), `read_memory 0xFFE000` fails. So do
  `0xFFF000`, `0xFFF100` and `0xFFFFF0`.

A failed read does not show that a region is empty: SICR is defined and still
fails, so access is restricted rather than absent. What the SICR holds, and
whether anything is mapped at `0xFFF000`, is for the nRF54LM20A Product
Specification's memory map; it is not in this workspace.

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
  `SystemInit` does it before the application runs. Verified on `Sophon-F9B0`
  (#370): with MCUboot and an app flashed, a USB-C power cycle left debug open
  (CPUID readable, core running), where a blank part had relocked.
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

Established in #370. Unlike the nRF52840, this board is MCUboot-shaped
upstream: its `.dts` already chooses `slot0_partition` as the code partition,
from Zephyr's `nrf54lm20_a_b_cpuapp_partition.dtsi`.
[mcuboot-partitions.overlay](mcuboot-partitions.overlay) keeps upstream's boot
and slots exactly and splits only its storage, as #329 did on the nRF52840:

| Partition | Offset | Size | |
|---|---|---|---|
| `boot_partition` | `0x000000` | 62 K | upstream; MCUboot uses 39,268 B (61.9%) on v4.5.0, 35,296 B on 4.4.99 |
| `slot0_partition` | `0x010000` | 968 K | upstream |
| `slot1_partition` | `0x102000` | 968 K | upstream; 964 K usable under swap-using-offset |
| `settings_partition` | `0x1F4000` | 8 K | the config record (#329): two 4 K sectors |
| `reserved_partition` | `0x1F6000` | 28 K | unassigned, kept erased; ends at `0x1FD000` = 2036 K |

Both images are built against the same table. MCUboot's code partition is
`boot_partition`, the application's is `slot0` with `settings_partition` as its
settings partition, as `mcuboot/app-slot0.overlay` sets for every MCU. MCUboot is
swap-using-offset with the fleet's RSA-2048 key, configured by the shared
`sysbuild/mcuboot.conf`.

**Why upstream's boot and slots are kept.** Redefining them only creates drift
against the next `west update`, and their boundaries suit FPROTECT, the NCS
library that write-protects MCUboot's partition until reset. Vanilla Zephyr
never enables it, so the 62 K is inherited; MCUboot fits with 28 K to spare, and
the room is kept for adding that protection later. Slot size costs nothing:
swap-using-offset moves only the sectors an image occupies.

### Bluetooth and the clock nodes (fixed in Zephyr v4.5.0)

Zephyr 4.4.99's board file enabled `lfxo`/`hfxo` but not `xo`, `lfclk` and
`xo24m`, and the Bluetooth controller fails to compile without an enabled
`lfclk`. No Bluetooth app built for this board, Zephyr's own
`samples/bluetooth/peripheral` included (#370). Sophon carried an overlay enabling
all three until v4.5.0 enabled them upstream (`97da33c77ad`, `e82c1044c31`).
The overlay was removed in #379, and Bluetooth builds from the board file alone.
MCUboot was never affected: it has no radio.

### Building, until build.sh learns this board

`scripts/build.sh` builds only the nRF52840 until Phase 2 of the port, and the
Sophon app itself waits for Phase 3. #370 proved the layout with Zephyr's
`smp_svr` sample (BLE SMP and image management) built against this repo's
files, from the activated venv with `ZEPHYR_BASE` set:

```bash
R=zephyr/sophon
west build -p always -b xiao_nrf54lm20a/nrf54lm20a/cpuapp --sysbuild -d <build> \
  $ZEPHYR_BASE/samples/subsys/mgmt/mcumgr/smp_svr -- \
  -DEXTRA_CONF_FILE="bt.conf;<no-fs.conf>" \
  -DSB_CONFIG_BOOT_SIGNATURE_KEY_FILE="\"$HOME/.sophon/keys/sophon-fw-rsa-2048.pem\"" \
  -DEXTRA_DTC_OVERLAY_FILE="$R/hw/nrf54lm20a/mcuboot-partitions.overlay;$R/mcuboot/app-slot0.overlay" \
  -Dmcuboot_EXTRA_DTC_OVERLAY_FILE=$R/hw/nrf54lm20a/mcuboot-partitions.overlay \
  -Dmcuboot_EXTRA_CONF_FILE=$R/sysbuild/mcuboot.conf
```

Two things about the sample, neither about the layout:

- **Its `bt.conf`** (this Zephyr has no `overlay-bt.conf`) mounts LittleFS on
  `storage_partition`, and its "zephyr basic" MCUmgr group erases it. Sophon's
  layout has no `storage_partition`, so `<no-fs.conf>` turns both off:
  `CONFIG_MCUMGR_GRP_FS=n`, `CONFIG_FILE_SYSTEM=n`,
  `CONFIG_FILE_SYSTEM_LITTLEFS=n`, `CONFIG_MCUMGR_GRP_ZBASIC=n`,
  `CONFIG_MCUMGR_GRP_ZBASIC_STORAGE_ERASE=n`.
- **`sysbuild/mcuboot.conf` must be passed explicitly.** Sysbuild picks it up
  only for the app whose directory it is in.

### Flashing and the OTA test

**On Zephyr v4.5.0 (#379), it just works.** On `Sophon-F9B0`:

- **`west flash -d <build> --erase`** mass-erased the board, wrote MCUboot and
  the app, and committed the write buffer (upstream's `nrf54l_load`). A read-back
  matched both images byte for byte, including the app's last line: it ends at
  `0x40924`, 4 bytes into a line, the case that failed on 4.4.99.
- **The BLE OTA cycle passed with the default one-line RRAM write buffer**:
  upload of 199 KB in 18 s, then test swap, revert and confirm.
- **New on v4.5.0:** each time the central ends a connection, the console logs
  `bt_ctlr_hci: Invalid Tx Enqueue` → `bt_conn: Unable to send to driver (err
  -22)` → `Fatal error (-5). Disconnecting` → `Unable to disconnect (err -13)`, at
  the same timestamp as "Disconnected, reason 0x13". The host still had a packet
  queued for a link the controller had already torn down. Nothing failed: every
  operation had completed. Seen with `smp_svr`, and not yet checked with the
  Sophon app or on the nRF52840.

The rest of this section is the original run, on Zephyr 4.4.99 (#370), from a
blank, locked board, kept because it is how both upstream defects were found.

1. **`west flash -d <build>`** uses Zephyr's OpenOCD config, which found the part
   locked and **erased it by itself** before writing MCUboot (§ Hazards). MCUboot
   then ran and reopened debug, so the app's session needed no erase.
2. **The app's write was short by 8 bytes.** A read-back
   (`scripts/ihex-cmp.py` against both `.hex` files) matched MCUboot and all of
   the app except `0x3DFD0`–`0x3DFD7`, still `0xFF`: the end of the signature
   TLV. MCUboot correctly refused it: "Image in the primary slot is not valid!".
   Cause: the board's `nrf54lm20a-load` turns on RRAM writes with a one-line
   write buffer and never commits it (§ Hazards). Rewritten with the commit:

   ```
   init; reset halt; mww 0x5004e500 0x101; load_image <app>.signed.hex;
   mww 0x5004e008 1; sleep 20; mww 0x5004e500 0; reset run; exit
   ```

   The read-back then matched both images. The console showed the boot:
   `Image version: v0.0.0`, `Jumping to the first image slot`, then the Bluetooth
   controller and "Advertising successfully started".
3. **The first OTA upload failed** on the device, `flash_write error -116
   offset=0x00103000` (`-ETIMEDOUT`), 25 s in: RRAM writes cannot complete while
   a BLE link is up with the default write buffer (§ Hazards). With
   `CONFIG_NRF_RRAM_WRITE_BUFFER_SIZE=32` (a board `.conf` until #379):

   | Step (`smpmgr --ble`) | Result |
   |---|---|
   | `image upload` 0.0.2 | 188,376 B in 22 s, to slot1 |
   | `image state-write <hash>`, `os reset` | "Starting swap using offset algorithm", `v0.0.2` booted, unconfirmed |
   | `os reset` without confirming | **reverted**: `v0.0.0`, confirmed |
   | test again, `state-write --confirm`, `os reset` | **kept** `v0.0.2`, confirmed, "Swap type: none" |

The layout, swap-using-offset on RRAM, and rollback all work on this board.

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
- **Zephyr older than v4.5.0: `west flash` can drop the end of an image.** The
  4.4.99 board's `nrf54lm20a-load` set RRAMC `CONFIG` to `0x101` (writes on,
  one-line buffer) and never triggered `TASKS_COMMITWRITEBUF` (`0x5004E008`). An
  image not ending on a 16-byte line lost its last partial line, part of its
  signature, so MCUboot rejected it. v4.5.0's `nrf54l_load` commits and the
  runner verifies (`ca77b788f93`; #377, #379). Sophon requires v4.5.0, but a
  read-back stays the proof that a write landed.
- **Zephyr older than v4.5.0: RRAM writes time out while a BLE link is up.**
  With Zephyr's controller, the RRAM driver's one-line write buffer gives a
  500 µs radio slot, and the ticker backend's `500 − 1700 µs` interval
  underflowed, so writes longer than one line failed with `-ETIMEDOUT` after
  ~24 s, for OTA and the config record alike. Fixed upstream in `c91fb6ead29`
  (#377). Sophon's `CONFIG_NRF_RRAM_WRITE_BUFFER_SIZE=32` workaround was removed
  in #379.
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

- RRAM write endurance, from the datasheet.
- The external Debug Probe path on TP1/TP2/TP4, untested; and whether U4's B
  side is high-impedance with OE low, as the USB-disconnected case assumes.
- What the patterned reserved UICR words are.
- What the SICR holds, and whether anything is mapped at `0xFFF000` (§ SICR).
