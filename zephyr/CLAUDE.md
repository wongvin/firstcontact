# Zephyr target — conventions

Firmware for embedded boards, built with [Zephyr RTOS](https://zephyrproject.org).

- [`sophon/`](sophon/) — a BLE motion peripheral on a Seeed XIAO nRF52840 Sense
  Plus, paired with the iOS app at `ios/Sophon/`.
- [`sophon-dumper/`](sophon-dumper/) — reads a board's whole flash and UICR out
  over the USB console so a backup can be taken **without a probe** (#297). It
  writes nothing, and `CONFIG_FLASH` is absent so that is a property of the
  binary. Preparation only: restoring still needs SWD.
- [`sophon-installer/`](sophon-installer/) — a one-shot application that
  migrates a board from the Adafruit UF2 bootloader to MCUboot without a probe
  (#294). It is a sibling app rather than a build mode of `sophon/`, because it
  is always a plain UF2 application: a UF2 bootloader is the only thing that
  will accept it, and a build at slot0 would be nonsense. Design in
  [`sophon/UF2-MIGRATION.md`](sophon/UF2-MIGRATION.md).

## Workspace layout — freestanding, and not pinned

Apps here are **freestanding** in Zephyr's sense: they live outside any west
workspace and build against the shared toolchain at `~/zephyrproject`. Zephyr
documents three application types (repository / workspace / freestanding); this
is the third, and the docs' own diagram for it is `~/zephyrproject` next to a
separate app directory — exactly this shape.

This is a deliberate choice forced by the monorepo, not a default. The modern
convention for a standalone Zephyr project is **T2 topology**, where the app repo
carries a `west.yml` and `west init -m <repo>` builds a workspace around it. Both
ways of doing that here are worse:

- `west init -m <firstcontact>` clones **firstcontact a second time** inside the
  workspace — two working copies of a repo that also holds `webapp/` and `ios/`.
- `west init -l ~/repos/firstcontact` puts `.west/` next to the directory, making
  the workspace root `~/repos/` and scattering `zephyr/`, `modules/`,
  `bootloader/` among unrelated projects.

**Consequence worth knowing: this repo does not pin the Zephyr revision.** Apps
follow whatever `~/zephyrproject` is at, so a `west update` there can change the
firmware's dependencies with no record here. `sophon/CMakeLists.txt` guards the
minimum version and fails at *configure* time with a readable message. Expected
version is **>= 4.4**.

If CI or a second machine ever needs to build this, the migration path is to add
a `west.yml` and switch to T2. Nothing in the current layout blocks that.

## Building

Always via the app's wrapper script, never bare `west`:

```bash
zephyr/sophon/scripts/build.sh
```

**`west` cannot run from inside this repo.** It walks *up* from `$PWD` looking for
a `.west/` marker and finds nothing, so it errors out. The wrapper activates
`~/zephyrproject/.venv` and exports `ZEPHYR_BASE`, which is what makes a
freestanding app buildable from here. If you invoke `west` by hand you must do
both yourself.

Board names are hierarchical (hardware model v2): `xiao_ble/nrf52840/sense`, not
the older `xiao_ble_sense`. `west boards` lists them.

`sophon/scripts/build.sh` builds for **MCUboot by default** (#270); every board
runs it. `SOPHON_BOOT=uf2` builds a UF2 instead, for a board still on the
Adafruit bootloader. An MCUboot build needs the signing key in
`~/.sophon/keys/` (see `sophon/README.md`).

## Flashing and the console

```bash
zephyr/sophon/scripts/flash-ota.sh      # MCUboot boards, over BLE (the usual path)
zephyr/sophon/scripts/flash-swd.sh      # MCUboot boards, bootloader + app, by probe
```

Procedures, hazards and recovery are in
[`sophon/BOOTLOADER.md`](sophon/BOOTLOADER.md).

**A board still on the Adafruit UF2 bootloader** builds with `SOPHON_BOOT=uf2`
and flashes with `zephyr/sophon/scripts/flash-uf2.sh`. Double-tap reset first; the
bootloader mounts a volume. The script tries `west flash -r uf2` and falls back
to a plain `cp` of `build/zephyr/zephyr.uf2`, because the uf2 runner matches on a
board-id string that a given board revision may not report.

**The XIAO has no UART-to-USB bridge**, so USB CDC ACM is the only console:

```bash
minicom -D /dev/cu.usbmodem* -b 115200
```

**Use `/dev/cu.*`, not `/dev/tty.*`.** Both nodes appear for the same device. On
macOS `tty.*` is the dial-in device and blocks waiting for carrier detect, so
opening it against a CDC ACM peripheral fails with
`Device not configured`; `cu.*` is the call-out device and connects immediately.
This is a macOS distinction, not a Zephyr one, and the failure looks like a dead
board rather than a wrong device node.

Do **not** set `CONFIG_USB_DEVICE_STACK=y` to get that console. The board's own
defconfig (`boards/common/usb/Kconfig.cdc_acm_serial.defconfig`) already enables
the *new* USB stack (`USB_DEVICE_STACK_NEXT`), `CDC_ACM_SERIAL_INITIALIZE_AT_BOOT`,
and a 4000 ms `LOG_PROCESS_THREAD_STARTUP_DELAY_MS` so the boot banner survives
enumeration. Adding the legacy stack on top links both and fails at link time with
a duplicate `__device_dts_ord_*` symbol.

## Verifying

**A successful build is necessary but not sufficient.** Compiling proves syntax
and Kconfig consistency; it says nothing about whether the radio comes up, the
advertising payload fits in 31 bytes, or a peripheral is readable by a central.

Any firmware change is verified **on the physical board** before its issue moves
to In review:

1. Build clean **in both modes**, and confirm the artefacts exist:
   `scripts/build.sh` → `build-mcuboot/mcuboot/zephyr/zephyr.hex` and
   `build-mcuboot/sophon/zephyr/zephyr.signed.{hex,bin}`;
   `SOPHON_BOOT=uf2 scripts/build.sh` → `build/zephyr/zephyr.uf2`. No board
   uses the UF2 build day to day, so it can only stay working if every change
   builds it. It broke silently from #271 to #306. MCUboot-only Kconfig goes in
   `sophon/swd/app-mcuboot.conf`, never `prj.conf`.
2. Flash, then read the console for the boot banner and init errors.
3. For BLE work, confirm in **nRF Connect** (or any scanner) that the device
   appears with the expected name and service UUID. Several advertising mistakes
   surface only as a bare `-EINVAL` from `bt_le_adv_start()`.
4. For anything with a counterpart app, exercise the pair end-to-end.

If hardware is not to hand, say so explicitly in the issue rather than implying
the change was verified.

## Design records

`sophon/PROTOCOL.md` is the **live** wire contract, kept current.

`ios/Sophon/UPDATED-PLAN.md` is the **current** design record — the ATT MTU
budget, the connection-event capacity analysis, the batching/DLE arithmetic, and
why the app is freestanding. Read it before changing anything about frame sizes,
sample rates, or MTU.

`ios/Sophon/ORIGINAL-PLAN.md` is the **frozen** version of the same document as
approved before implementation. Where they disagree, the updated one is right;
the original is kept only as the record of what was originally intended.

Both live under `ios/` but carry analysis for **both** halves — the BLE capacity
derivation for this firmware is filed under the iOS target, which is not
guessable.
