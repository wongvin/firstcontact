# sophon: port to the XIAO nRF54LM20A Sense — MCUboot partitions first

> Original design record for #368, approved 2026-10-28. It is not edited after
> the fact; changes go in `NRF54LM20A-UPDATED-PLAN.md` with a dated changes
> table, as #303 did with [LORA-UPDATED-PLAN.md](LORA-UPDATED-PLAN.md). The
> pre-port state is tagged `pre-nrf54lm20a-port`.

## Context

Sophon should run, full app plus MCUboot, on the **Seeed XIAO nRF54LM20A Sense** as well as the
current XIAO nRF52840 Sense Plus. Work starts with the bootloader partition layout. Before
anything is designed against the board, its factory state is backed up and inspected over the
debug probe. Later work is a hardware design review, the build plumbing, the peripherals, and a
UF2-to-MCUboot migration app. Each is its own issue, cross-linked.

### What exists upstream (Zephyr 4.4.99 in `~/zephyrproject`)

- Board `xiao_nrf54lm20a/nrf54lm20a/cpuapp` (`boards/seeed/xiao_nrf54lm20a/`) is **already
  MCUboot-shaped**. Its `.dts` sets `zephyr,code-partition = &slot0_partition`, and it pulls in
  `dts/vendor/nordic/nrf54lm20_a_b_cpuapp_partition.dtsi`:

  | Partition | Offset | Size |
  |---|---|---|
  | `boot_partition` | 0x000000 | 62 K (sized to allow FPROTECT) |
  | `slot0_partition` | 0x010000 | 968 K |
  | `slot1_partition` | 0x102000 | 968 K |
  | `storage_partition` | 0x1F4000 | 36 K (ends at 2036 K, the end of RRAM) |

  The FLPR variant of that table is not used: the board does not define `WITH_FLPR_PARTITIONS`.
- **RRAM, not flash.** `erase-block-size = 4096` is emulated; `write-block-size = 16`.
  Compared with the nRF52840's flash:

  | | nRF52840 flash | nRF54LM20A RRAM |
  |---|---|---|
  | Size | 1 MB | 2036 K (FICR confirms in Phase 0) |
  | Rewrite | bits only go 1→0; a page must be erased first | any line is rewritten in place; there is no erase |
  | Write unit | 32-bit word | 128-bit line (16 B) |
  | "Erase" | real 4 K page erase, up to 89.7 ms (`FLASH_PAGE_ERASE_MAX_TIME_US`) | emulated: the driver writes 0xFF (`nrf_rram_fill_impl`); the 4 K block exists only for the flash API and MCUboot's sector math |
  | Radio impact | erase stalls the CPU, hence radio sync + `SOC_FLASH_NRF_PARTIAL_ERASE` (#271) | still radio-synced, but no long stalls; partial erase doesn't exist |
  | Erased value | 0xFF | 0xFF (same, so MCUboot's erased checks are unchanged) |

  Consequences: the link-drop risk during OTA uploads, which partial erase fixed, goes away. An
  emulated erase is a full write, so it **costs wear, not just time**. That's why settings move to
  ZMS (Phase 2), and why Phase 2 also turns on `CONFIG_NRF_RRAM_FILL_SKIP_IF_FILLED`
  (off by default), which skips lines already 0xFF. Endurance figures come from the
  nRF54LM20A datasheet, not from assumption. They're recorded in `hw/nrf54lm20a/MEMORY-MAP.md`.
- **Console is `uart20`**, routed through an onboard SAMD11 CMSIS-DAP bridge that also serves as
  an SWD probe. No CDC ACM is involved.
- Sysbuild defaults: `MCUBOOT_MODE_SWAP_USING_OFFSET`, `BOOT_SIGNATURE_TYPE_RSA`. That matches
  the nRF52840 boards.
- **Zephyr's overlay rule** (`cmake/modules/configuration_files.cmake:70-83`): if
  `boards/<board>.overlay` exists, `app.overlay` is **not** applied, while `boards/<board>.conf`
  is merged on top of `prj.conf`. `sysbuild/mcuboot.conf` has no per-board variant, so per-board
  MCUboot files must be passed by `build.sh`.

### What carries over from the nRF52840 files

| File | On the nRF54LM20A |
|---|---|
| `swd/mcuboot-partitions.overlay` | nRF52-only (deletes UF2/SoftDevice nodes) |
| `swd/mcuboot-console.overlay` | nRF52-only (`uart0` workaround for CDC ACM) |
| `swd/app-slot0.overlay` | Generic (chooses slot0 + `settings_partition`). Shared. |
| `sysbuild/mcuboot.conf` | Generic (UART console, `REGULATOR=n`, no serial recovery). Shared; the board's `power_en` `regulator-fixed` would hit the same `k_usleep` link error. |
| `swd/app-mcuboot.conf` | Mixed: `SOC_FLASH_NRF_PARTIAL_ERASE` (depends on `HAS_HW_NRF_NVMC_PE`, absent on RRAM) and the NVS backend are nRF52-only; MCUmgr/img-manager is shared |

## Step 0 — record this plan in the repo (first, after acceptance)

1. **File three issues** in `wongvin/firstcontact`, add each to Project 1, and cross-link
   them both ways. Bodies follow the house style: a short rationale plus a `### Requirements`
   checklist.
   - **Umbrella:** `sophon: port to the XIAO nRF54LM20A Sense`. Its checklist has one line per
     piece of work (Step R, Phase 0, Phase 1, hardware review, Phases 2–5, migration app,
     production notes), linking the two issues below. The rest are filed when each starts. It
     owns this plan doc (steps 3–6). Set it to **In progress** with today's Start date.
   - **Phase 0:** `sophon: back up and inspect the factory XIAO nRF54LM20A`. Requirements are
     Phase 0 steps 1–6: the read-only OpenOCD cfg, an APPROTECT check that stops if locked, the
     RRAM/UICR/FICR dumps and their verification, and the factory layout recorded in
     `hw/nrf54lm20a/`. It also tests the SAMD11-UF2 hypothesis. Left in **Backlog**.
   - **Phase 1:** `sophon: MCUboot partition layout for XIAO nRF54LM20A`. Requirements are the
     Phase 1 work and verification. Its body says it's **blocked by** the Phase 0 issue and Step R,
     since the layout is provisional until Phase 0 reports. Left in **Backlog**.
2. **Tag the head before any change.** `git checkout main && git pull`, then confirm that
   `HEAD` equals `origin/main` (51ca53a at planning time; use whatever it is then) and that the
   tree is clean. Then create an annotated tag in the existing `pre-<topic>` style
   (`pre-lora-relay`, `pre-vercel-migration`):
   `git tag -a pre-nrf54lm20a-port -m "Snapshot of nRF52840-only Sophon (firmware 2.38) before the nRF54LM20A port (#368)"`
   and `git push origin pre-nrf54lm20a-port`. Verify with `git ls-remote --tags origin`. It
   marks the last nRF52-only state, which is the reference point for Step R's byte-identical
   proof.
3. Branch `368-nrf54lm20a-plan` from that tagged `main`.
4. Write **`zephyr/sophon/NRF54LM20A-PLAN.md`**. It sits next to the other `*-PLAN.md` records,
   since it spans both MCUs (Step R) and the root is where design records live. It's this plan
   with the working draft's change callout and highlight tags removed, under a banner in the
   `LORA-PLAN.md` style: "Original design record for #368, approved 2026-10-28. It is not edited
   after the fact." Changes later go in `NRF54LM20A-UPDATED-PLAN.md` with a dated changes table,
   as #303 did. The schematic and KiCad zip are referenced by URL and hash only; neither file is
   committed. Absolute home paths are written as `~/`.
5. Link it from `zephyr/sophon/README.md` (one line) and the umbrella issue body.
   `ChangeLog.md` gets a `docs:` entry under the 2026-10-28 heading.
6. Move the issue to In review, post a summary comment, and **pause for consent** before
   staging or committing. Then commit (`docs: nRF54LM20A port plan (#368)`), push, and open a PR.

## Toolchain — no update needed

- **Zephyr SDK 1.0.1** (`~/zephyr-sdk-1.0.1`) is exactly what this Zephyr revision asks for
  (`zephyr/SDK_VERSION` = 1.0.1). Its GCC builds Cortex-M33, so there's nothing to install.
- **OpenOCD 0.12** from the SDK is enough. The board's `openocd.cfg` is self-contained: generic
  `cortex_m`, an `nrf5` flash bank over `0x0–0x1FD000`, and RRAM writes enabled through
  `RRAMC.CONFIG` in `nrf54lm20a-load`. No newer OpenOCD target script is needed.
- **nrfutil and J-Link are not installed** and aren't needed. The XIAO's probe is CMSIS-DAP,
  and the OpenOCD runner comes first in `board.cmake`.
- **Don't `west update` `~/zephyrproject` during this work.** It's at 4.4.99 (2026-08-08)
  and already has the board. The repo doesn't pin Zephyr (`zephyr/CLAUDE.md`), so an update would
  change the nRF52 images and void Step R's byte-identical proof. A Zephyr bump is its own
  issue.

## Design constraint: the SAMD11 is a dev-board convenience

A production Sophon board will drop the SAMD11 to cut component count: native nRF54 USB, and an
external probe when needed, which is the nRF52 model today. So nothing may *depend* on the bridge:
- **Probe**: every procedure (Phase 0 dumps, `flash-swd.sh`, recovery) must also work through an
  external CMSIS-DAP on the SWD pads. The onboard SAMD11 is just the default on the XIAO.
- **Console**: `uart20`-via-SAMD11 is what the XIAO gives. The app keeps its CDC ACM path from the
  nRF52 build, so it can move to native USB on a board whose D+/D− are wired. MCUboot logs on a
  production board need a UART on test pads, the same answer the nRF52 reached.
- **Recovery**: assume SWD through an external probe, as on the nRF52. Don't design around a
  bridge that production won't have.
- **Directory naming holds**: a production board is another *board* on the same MCU, so it adds a
  `boards/<board>.overlay`, not a new `hw/` directory.

## Repo structure (decided)

Board-independent things stay at `zephyr/sophon/`'s root. Everything MCU-specific lives in
`hw/<mcu>/`. Directories are named by **MCU**, not board, because the nRF52840 Sense image also
runs on the plain XIAO nRF52840 gateway (#301).

```
zephyr/sophon/
  src/ prj.conf Kconfig CMakeLists.txt     shared code
  PROTOCOL.md LORA-*.md CONFIG-PLAN.md …    shared, board-independent docs
  BOOTLOADER.md         shared MCUboot: signing key, OTA, swap, rollback, hazards
  README.md             adds a "Boards" table linking each hw/<mcu>/
  sysbuild/mcuboot.conf shared MCUboot Kconfig
  swd/app-slot0.overlay shared (app chosen nodes)   -> renamed mcuboot/app-slot0.overlay
  swd/app-mcuboot.conf  shared part only (MCUmgr)   -> renamed mcuboot/app-mcuboot.conf
  boards/                                   Zephyr auto-applies; replaces app.overlay
    xiao_ble_nrf52840_sense.overlay / .conf
    xiao_nrf54lm20a_nrf54lm20a_cpuapp.overlay / .conf
    common/wio-sx1262.dtsi                  #include'd by both, via &xiao_spi / &xiao_d
  hw/
    nrf52840/
      README.md   HARDWARE.md   MEMORY-MAP.md (layout, UF2, SWD, backups)   UF2-MIGRATION.md
      mcuboot-partitions.overlay   mcuboot-console.overlay   app-mcuboot.conf (partial erase, NVS)
    nrf54lm20a/
      README.md   HARDWARE.md   MEMORY-MAP.md
      mcuboot-partitions.overlay   app-mcuboot.conf (ZMS)
  scripts/common.sh   sophon_mcu "$BOARD" -> nrf52840 | nrf54lm20a; build.sh reads hw/<mcu>/
```

Rules this sets, recorded in `zephyr/CLAUDE.md`:
- A file is MCU-specific if it would be wrong on the other MCU. If so it goes in `hw/<mcu>/`,
  otherwise at the root.
- Root docs link down into `hw/<mcu>/` and never repeat MCU facts. `hw/<mcu>/` docs link up for
  shared procedure.
- The board-specific Kconfig *and* devicetree for the app go in `boards/` (Zephyr's
  mechanism). MCUboot-only, per-MCU files go in `hw/<mcu>/` and are passed by `build.sh`.
- Names: the root `BOOTLOADER.md` and `HARDWARE.md` keep theirs, because ChangeLog, frozen
  plans and issue comments link to them. Per-MCU boot, flash and debug details go in
  `hw/<mcu>/MEMORY-MAP.md`, and per-MCU circuits in `hw/<mcu>/HARDWARE.md`.
- Frozen and historical records (`*-PLAN.md` originals, `ChangeLog.md`) are **not** rewritten for
  the moved paths. Live docs are.

## Step R — restructure refactor (its own issue, nRF52-only, before Phase 1)

A pure move with **no behaviour change**, so it can be proved byte-identical and reviewed apart
from the port.

1. `git mv` the nRF52 files into `hw/nrf52840/`. Split `swd/app-mcuboot.conf` into a shared
   `mcuboot/app-mcuboot.conf` and `hw/nrf52840/app-mcuboot.conf`. Split `HARDWARE.md` and
   `BOOTLOADER.md` the same way: the nRF52-only sections move down, and the shared sections stay.
   `UF2-MIGRATION.md` moves whole.
   **Doc split, section by section.** The test for each section is whether it would be
   **wrong on the other MCU**. If so it moves down; if not it stays at the root. Moved text is cut
   and pasted, not rewritten, and each root section that loses a subsection gets a one-line link
   to the per-MCU file.

   | Current section | Goes to | Why |
   |---|---|---|
   | BOOTLOADER § The two boot paths | root, trimmed | MCUboot-vs-UF2 concept is shared; nRF52 addresses move down |
   | § Memory maps, § Where the stock layout comes from, § The Nordic SoftDevice | `hw/nrf52840/` | addresses, MBR, S140 are nRF52-only |
   | § SWD access: Test points, TP2, OpenOCD command, APPROTECT | `hw/nrf52840/` | pads, `target/nrf52.cfg` and the UICR semantics differ on the 54L |
   | § There is a debugger… (#279) | root | gdb/addr2line workflow is the same |
   | § Backup and recovery: principle, `~/.sophon/backups/`, Time Machine, verify with `cmp` | root | procedure and storage rules are shared |
   | … dump addresses, per-board backup tables, sophon-dumper, portability, Restoring, Full recovery | `hw/nrf52840/` | addresses and eras are per-MCU |
   | § MCUboot on this board: no partitions, why the app can't stay at 0x27000, slot sizing numbers | `hw/nrf52840/` | layout-specific |
   | … `sysbuild/mcuboot.conf`, the swap-using-offset rule, DFU transport (#271), From the iPhone (#357) | root | same config, mode and transport on both |
   | § The two consoles (CDC ACM vs `uart0`, device nodes, baud) | `hw/nrf52840/` | the 54L has one UART console via the SAMD11 |
   | § Image signing (all) | root | one key across the fleet |
   | § Hazards: `resume`, halt, console re-enumeration, `PM_DEVICE_RUNTIME` | root | SWD/host/Zephyr rules, not SoC rules |
   | … Never end a session between erase and write | `hw/nrf52840/` | NVMC page-erase hazard; the 54L file starts its own hazards with the auto-mass-erase `openocd.cfg` |
   | § Building for each boot path, What an MCUboot build produces, Guards | root | gains a `SOPHON_BOARD` column |
   | … Migrating a board (by probe, by UF2) | `hw/nrf52840/` | the 54L migration app is a later issue |
   | § Not established | split item by item | |
   | `UF2-MIGRATION.md` | `hw/nrf52840/` whole | Adafruit bootloader internals |
   | HARDWARE § Where the authoritative data is / KiCad extraction | root | methodology applies to both boards |
   | HARDWARE § battery, P0.14, charger, power path, ADC, traps, measurements, XIAO nRF52840 gateway | `hw/nrf52840/HARDWARE.md` | nRF52 module circuits |
   | HARDWARE § Wio-SX1262 (all, including the noise floor) | root | the same carrier on both MCUs |

   `hw/nrf54lm20a/MEMORY-MAP.md` mirrors the nRF52 file's headings (Memory map · SWD access ·
   Backups · MCUboot on this board · Console · Hazards · Migrating), so the two read side by
   side.
2. `app.overlay` → `boards/xiao_ble_nrf52840_sense.overlay`. The Wio block becomes
   `boards/common/wio-sx1262.dtsi`, still on the nRF52's literal pins for now. Porting it to
   `&xiao_d` happens in Phase 3 (direct role).
3. `scripts/common.sh` gains `sophon_mcu`. `build.sh` and `flash-swd.sh` (its stale-input check
   lists `swd/`) read from `hw/$(sophon_mcu)/`. `sophon-installer/CMakeLists.txt` and
   `scripts/build.sh`, which consume Sophon's `swd/` overlays, are updated too.
4. Fix the live doc links: `zephyr/CLAUDE.md`, `zephyr/sophon/README.md`, the
   `sophon-installer/` and `sophon-dumper/` READMEs, `PROTOCOL.md`, `ios/Sophon/TEST-PLAN.md`, and
   the root `README.md`. Afterwards a `git grep` for `swd/` and `app.overlay` should find hits only
   in frozen and historical files.
5. **Verify**: an MCUboot build of `sophon/` and a build of `sophon-installer/` are
   **byte-identical** to `main`'s. Compare `zephyr.hex` (MCUboot) and `zephyr.signed.bin` (app)
   with `scripts/ihex-cmp.py`, excluding only the build timestamp. Run the UF2 build too, while
   #362 hasn't landed. No hardware is needed: identical images are the proof.

## Phase 0 — back up and inspect the factory board (read-only)

The board is assumed to ship with a factory UF2 bootloader that upstream Zephyr's table knows
nothing about, as the nRF52840 XIAO's did (#253). Nothing is written to the board in this phase.
It can run before or alongside Step R, since it writes only new files.

0. Work happens under the **Phase 0 issue** (filed in Step 0). When it starts, set it to In
   progress with today's Start date and branch `<N>-nrf54lm20a-factory-backup`. Findings go in
   that issue's thread. The branch commits `hw/nrf54lm20a/openocd-readonly.cfg` and the
   factory-layout sections, never the dumps themselves.
**Hypothesis for Phase 0 to test:** with no USB on the nRF54, a UF2 drive that mounts from
this board is most likely the **SAMD11's** drag-and-drop programmer (DAPLink-style, flashing the
nRF54 over SWD), not a bootloader in nRF54 RRAM. If so, MCUboot coexists with it, the "migration
app" item shrinks to dropping a merged image on that volume, and Phase 0 should also record the
SAMD11 firmware version from its volume.
1. **UF2 drive files.** Double-tap reset. If a volume mounts, copy `CURRENT.UF2`, `INFO_UF2.TXT`
   and `INDEX.HTM` to `~/.sophon/backups/`, as was done for `01A7`/`0FAA`. If no volume mounts,
   record that.
2. **Probe check.** Netlist (sheet 04, KiCad V1.0): the USB-C's data lines go **only to the
   SAMD11** (U5); the nRF54's own D+/D− carry no net, so the nRF54 has **no USB on the connector**.
   The SAMD11 drives `nRF54_SWDIO`/`nRF54_SWCLK` and the `uart20` console (P1.10/P1.11) through a
   UM3204H auto-direction translator (U4), whose **OE is hard-wired on** (R16). The nRF54's SWD
   pads are **TP2 (SWDIO), TP1 (SWCLK), TP4 (nRESET)**, on the same nets. TP6–TP8 are the SAMD11's
   own SWD pads, not the nRF54's. So with USB-C plugged in, an external probe on TP1/TP2 shares
   the bus with a live SAMD11. Having both USB cables on the Mac is fine; **only one probe may run
   an SWD session at a time**. Phase 0 uses the onboard SAMD11 (USB-C alone gives probe +
   console), and the external Debug Probe stays the fallback. Identify which probe `/dev/cu.usbmodemD9E2169F3` is.
   **Do not use the board's upstream `support/openocd.cfg` for this phase.** It installs an
   `examine-fail` handler that runs `nrf54l_mass_erase` automatically if the part is locked, which
   would silently destroy the factory image on the first connect. Use a read-only copy,
   `hw/nrf54lm20a/openocd-readonly.cfg`, with that handler and the `nrf5` flash bank removed. It is
   committed with a comment explaining why. Read `CTRL-AP APPROTECTSTATUS` first. **If the
   part is locked, STOP and report.** Unlocking means a mass erase, which destroys what the backup
   exists to save.
3. **Dump, no halt** (`init; dump_image …; exit`, per #275):

   | Region | Address | Size | File suffix |
   |---|---|---|---|
   | RRAM | `0x00000000` | `0x1FD000` (2036 K) | `_rram-2036KB.bin` |
   | UICR | `0x00FFD000` | `0x1000` | `_uicr-4KB.bin` |
   | FICR | `0x00FFC000` | `0x1000` | `_ficr-4KB.bin` |

   Name the files `Sophon-<ID>_<UTC>_uf2-factory_…`. FICR records `INFO.RRAM`, which settles the
   doc's "1.5 MB" against the dtsi's 2036 K.
4. **Verify the backup**: dump twice and require identical SHA-256s. Check that the application
   region matches `CURRENT.UF2`. Then run Time Machine.
5. **Inspect** (offline): where the bootloader lives, and its vectors. Where it places apps. Any
   storage regions, and anything in the top 96 K. UICR contents, including any RRAMC protection.
   Whether it locks itself.
6. **Record** it in `hw/nrf54lm20a/HARDWARE.md` ("Factory layout") and
   `hw/nrf54lm20a/MEMORY-MAP.md` (backups table), before the layout below is final.

## Recommended layout (provisional — confirmed or revised after Phase 0)

If Phase 0 finds a factory UF2 bootloader, MCUboot replaces it, and only the Phase 0 backup can
undo that. If the bootloader's region or RRAM protection conflicts with upstream's table, the table
is redrawn with `/delete-node/`, as the nRF52 overlay does. Otherwise, keep upstream's
boot/slot0/slot1 **untouched** and only subdivide `storage_partition`, mirroring #329:

| Partition | Offset | Size | Notes |
|---|---|---|---|
| `boot_partition` | 0x000000 | 62 K | upstream; nRF52 MCUboot is ~40 K |
| `slot0_partition` | 0x010000 | 968 K | upstream; Sophon is ~169 K |
| `slot1_partition` | 0x102000 | 968 K | upstream; usable 964 K under swap-using-offset |
| `settings_partition` | 0x1F4000 | 8 K | replaces `storage_partition` |
| `reserved_partition` | 0x1F6000 | 28 K | kept erased for future use |

- **Upstream slots kept**: they're FPROTECT-friendly, and redefining them only adds drift.
  **FPROTECT** is the nRF Connect SDK library that write-protects MCUboot's own partition
  until the next reset. MCUboot sets an RRAMC protected region (`nrf_rramc.h`, region
  `CONFIG` READ/WRITE/EXECUTE bits) before jumping to the app, so neither the app nor code
  running in it can overwrite the bootloader. The library is **not in this workspace**: vanilla
  Zephyr/MCUboot never enables it, so the 62 K size is inherited from NCS, and Sophon pays only
  ~2 K of unused space for keeping it. That 62 K is probably the RRAMC region-size field's
  maximum, but this hasn't been checked against the nRF54LM20A datasheet. Keeping 62 K leaves
  room to add the protection later, by hand, as part of the ED25519/KMU hardening issue. The
  nRF52 builds don't protect MCUboot either (the BPROT/ACL equivalent is unused).
- **Slot size is free**: swap-using-offset moves only the sectors the image occupies.
- **No external SPI-NOR slot1**: RRAM already holds ~5.7× the image.
- **Settings on ZMS, not NVS**: NVS's emulated erase doubles RRAM wear. `config.c` uses only the
  settings API. The backend switch lands in Phase 2; Phase 1 fixes only the 8 K size.
- **Same RSA-2048 signing key** across the fleet. ED25519 with the KMU is a separate issue.

## Phase 1 work (the Phase 1 issue, branch `<N>-nrf54lm20a-partitions`)

1. **New** `hw/nrf54lm20a/mcuboot-partitions.overlay`: `/delete-node/ &storage_partition;`
   then add `settings_partition` and `reserved_partition` (`compatible = "zephyr,mapped-partition"`),
   commented in the house style.
2. `sysbuild/mcuboot.conf`: add a comment that it serves both MCUs, and why `REGULATOR=n` still
   applies.
3. `hw/nrf54lm20a/MEMORY-MAP.md`: the layout table, flashing via `west flash` (OpenOCD
   runner), recovery, and the UF2 situation from Phase 0. `hw/nrf54lm20a/README.md` gets
   a board summary, and the root `README.md` Boards table gets a row.
4. ChangeLog, In review, and an implementation-summary comment. Pause for consent.

No `build.sh` app build for this board yet. The app can't compile until Phase 3 (direct role) handles
`battery.c` and the LoRa overlay.

## Verification (needs the board)

Build Zephyr's `samples/subsys/mgmt/mcumgr/smp_svr` (BLE SMP) with this repo's overlay,
MCUboot config and key:

```bash
west build -p always -b xiao_nrf54lm20a/nrf54lm20a/cpuapp --sysbuild -d /tmp/smp54 \
  $ZEPHYR_BASE/samples/subsys/mgmt/mcumgr/smp_svr -- \
  -DEXTRA_CONF_FILE=overlay-bt.conf \
  -DSB_CONFIG_BOOT_SIGNATURE_KEY_FILE="\"$HOME/.sophon/keys/sophon-fw-rsa-2048.pem\"" \
  -DEXTRA_DTC_OVERLAY_FILE=<repo>/zephyr/sophon/hw/nrf54lm20a/mcuboot-partitions.overlay \
  -Dmcuboot_EXTRA_DTC_OVERLAY_FILE=<repo>/zephyr/sophon/hw/nrf54lm20a/mcuboot-partitions.overlay
```

1. **Build**: the partition table matches the table above, and the MCUboot `.hex` fits in 62 K
   (record its size).
2. **Flash** with `west flash -d /tmp/smp54`, **only after the Phase 0 backup is verified.** On
   `uart20`, look for `I: Starting bootloader`, then the app banner.
3. **OTA swap**: upload a version-bumped image over BLE, then `image test` and reset; it should
   boot the new version. Reset again without confirming and it should **revert**. Test and confirm
   once more and it should stick.
4. **nRF52 untouched**: `scripts/build.sh` output is byte-identical to the post-Step-R build.

If the board isn't to hand, the issue will say only steps 1 and 4 were done.

## Later issues (outlined only, cross-linked to this one)

- **Hardware design review**. Sources, neither committed: a CC BY-SA design doesn't belong in a
  repo with no LICENSE, the same rule as the backups. HARDWARE.md records the URL, revision and
  hash of each.
  - **Primary: KiCad project**
    [XIAO_nRF54LM20A_V1.0_SCH&PCB_260508.zip](https://files.seeedstudio.com/wiki/XIAO_nRF54LM20A/getting_start/RES/XIAO_nRF54LM20A_V1.0_SCH&PCB_260508.zip),
    SHA-256 `ca7f509f…f60ada`. It contains the root sheet plus six hierarchical sub-sheets,
    `.kicad_pcb`, `.kicad_pro` and `.step`. Every sheet's title block reads **rev V1.0, date
    2026-04-09**, which matches the PDF. Unlike the nRF52840 archives, the name and contents
    agree.
  - Secondary: the schematic PDF (same URL directory), SHA-256 `f877501a…260da3`, used only for
    reading the drawing.

  **Tooling gap, measured.** Running `scripts/kicad-netlist.py` on `03 Power.kicad_sch` works
  per sheet, but it prints power nets as `#PWR0xx` with no rail name and drops hierarchical labels.
  For example, U3's EN net ends at R19 with nothing past it. So the review's first task is one of
  two things: extend the script to name power symbols and join sub-sheets through their
  hierarchical labels, verified against the PDF on a few known nets; or install KiCad 10 and use
  `kicad-cli sch export netlist`. Recommendation: extend the script. It's already the repo's tool,
  and the nRF52 notes depend on it.

  First-pass findings, from the PDF plus the first netlist run, to be confirmed:
  - Pin map **matches** Zephyr's board files: D0 P1.00, D1 P1.31, D2 P1.30, D3 P1.29,
    D4 P1.03 (SDA), D5 P1.07 (SCL), D6/D7 P1.08/P1.09, D8–D10 P1.04/P1.05/P1.06 = `spi23`. The
    Wio-SX1262 therefore lands entirely on port P1. D4/D5 are `xiao_i2c` (`i2c22`), which must be
    disabled, as `i2c1` is on the nRF52.
  - IMU: LSM6DS3TR-C (U11) at 0x6A on P0.07/P0.08, INT1 P0.06, CS P3.12. It is powered from a
    **switched** `IMU&MIC_3V3` rail (a TPS22916 load switch, shared with the PDM mic). Which GPIO
    drives that switch's EN (presumably `power_en` P1.12) is the open question.
  - Power: nPM1300 (U2) on bit-banged I2C P1.17/P1.18, with its GPIO0/1 on P1.25/P1.26, and
    a TPS628438 buck (U1) making `VSYS_3V3`. The nPM1300's LED1 is the charge indicator in
    hardware. R36 (1 M) and R3 (249 K) are **not** a battery divider, as the PDF suggested.
    The netlist puts R36 on U1's EN (pulled up to VIN) and R3 on U1's MODE. Battery voltage
    therefore comes only from the nPM1300's ADC. U3 (the IMU/mic switch) has EN pulled down by
    R15 and driven through R19 from a net on another sheet, presumably P1.12. U6 switches VBUS,
    with EN from R41/R45.
  - Debug: as in Phase 0 step 2. The SAMD11 also has an `nRF54_RST_CTL` net.

  Also: **what powers the SAMD11** (`SAMD11_3V3`). If it runs from the battery, its idle
  draw counts against Sophon's budget. And **why the nRF54's USB D+/D− are left unconnected**:
  check the PCB for pads before treating native USB as unavailable.
  Still to cover: the VBUS/VBAT load path (the #319 counterpart), any P0.14-style hazard
  pin, quiescent draw, the NFC pins (P1.01/P1.02) against the XIAO header, and RF (chip antenna
  ANT2 with its matching network). The output is `hw/nrf54lm20a/HARDWARE.md`, with
  datasheets in `hw/nrf54lm20a/datasheets/`. It must land before Phase 3.
- **Phase 2 — build plumbing**: `build.sh` drives the nRF54LM20A from `hw/nrf54lm20a/`
  (ZMS and `CONFIG_NRF_RRAM_FILL_SKIP_IF_FILLED=y` in its `app-mcuboot.conf`). `flash-swd.sh` gets this MCU's memory map and OpenOCD config,
  and refuses a board still on the factory UF2 bootloader without `--force`.
- **Phase 3 — direct role, no LoRa radio** (new; its own issue). The full Sophon app on the
  XIAO nRF54LM20A Sense **with no Wio-SX1262 fitted**, running as the direct role: a BLE
  peripheral streaming the IMU to the iPhone, with config, OTA and confirm. That's the role
  `role.h` documents as "no radio → direct". It proves the whole app (MCUboot, BLE, IMU, settings,
  SMP) on the new MCU before any LoRa work.
  - **LoRa, without code changes:** `lora_link.c`/`role.c` need a `lora0` node to compile. The
    board overlay includes `boards/common/wio-sx1262.dtsi`, moved to `&xiao_spi`/`&xiao_d` now
    rather than in Phase 4, and keeps `zephyr,deferred-init`. With nothing fitted, `role.c`'s
    sync-word presence check fails (bounded waits, BUSY pulled down), and the board resolves to
    direct. That's the existing radio-less path (#303), unchanged. `xiao_i2c` (`i2c22`) is
    disabled, as `i2c1` is on the nRF52.
  - **Battery:** `battery.c` has an `#error` without a `vbatt` node. Give it a no-source path,
    guarded by `DT_NODE_EXISTS(vbatt)` and `charge_status`, that reports `PROTOCOL.md`'s existing
    `mv == 0` sentinel ("Not reported") with charge status unknown. **No protocol or iOS change.**
    The nPM1300 backend replaces it in Phase 4.
  - **IMU:** same `st,lsm6dsl`, on `i2c30` at 0x6A, INT1 P0.06. Its rail is a switched load
    switch (U3). The hardware review's IMU-power item **gates this phase**: confirm U3's EN is
    `power_en` P1.12, which the board brings up with `regulator-boot-on`. `prj.conf`'s IMU
    comments name nRF52 pins and become per-board notes.
  - **Per-board `.conf`:** the BLE TX power level (−4 dBm was chosen for the nRF52's antenna;
    re-measure on ANT2), and ZMS from Phase 2. `prj.conf` comments that name the nRF52840 (FICR,
    CDC ACM console, radio TX steps) move to the nRF52 board file or get reworded.
  - **Verify on hardware:** build both MCUs and confirm the nRF52 image is byte-identical. Flash
    over the onboard probe. The console must show the MCUboot banner, `role: direct`, and no init
    errors. In nRF Connect, the name and service UUID appear. The iOS app connects and plots IMU
    motion end to end, and Battery reads "Not reported". Run an OTA via `flash-ota.sh` with
    test/revert/confirm. Write a config record from the app and check it survives a reset (ZMS on
    RRAM).
- **Phase 4 — peripherals and LoRa**: building on Phase 3's board files. `battery.c`
  gets an nPM1300 backend (voltage, charge status) in place of the "Not reported" path.
  Fit a Wio-SX1262 and confirm the board resolves to sensor/gateway/transporter, checking
  the shared `&xiao_d` pin map on hardware, and run a LoRa link against an nRF52 board.
- **UF2-to-MCUboot migration app**: the nRF54LM20A counterpart of `sophon-installer/` (#294,
  `UF2-MIGRATION.md`). It's a one-shot UF2 that installs MCUboot plus signed Sophon, so boards
  migrate without a probe. It depends on Phase 0 (bootloader location, protection, UICR) and on
  Phase 1's final layout. Whether it is a build mode or a sibling app is decided there.
  Cross-link #294 and #362.
- **Production board design notes** (later, when a custom board is on the table). Build in what
  the XIAO's SAMD11 provides for free: SWD + reset on a probe footprint (e.g. Tag-Connect), a UART
  TX/RX test-pad pair for MCUboot logs, and nRF54 USB D+/D− wired for CDC ACM and charging. Use the
  XIAO V1.0 KiCad project as the reference design. No SAMD11 or level shifter.
- *Not planned:* MCUboot serial recovery over `uart20`. It only works through the XIAO's
  bridge, so it wouldn't carry to production hardware.
- **Phase 5 — iOS**: likely nothing, since `PROTOCOL.md` is board-independent. Confirm it.
