# Sophon — firmware

BLE peripheral on a **Seeed XIAO nRF52840 Sense Plus**, streaming IMU motion to
the iOS app at [`ios/Sophon/`](../../ios/Sophon/).

Named for Cixin Liu's proton-scale probe: it sits inside what it observes and
relays continuously to a distant receiver.

## Status

**Skeleton (#208).** The transport works end to end — advertise, connect,
subscribe, notify — but the frame's six axis fields are zero and the notify rate
is 1 Hz. Real IMU data at 50 Hz is #209.

## Build

```bash
scripts/build.sh              # from anywhere; locates the app relative to itself
scripts/build.sh -t menuconfig
```

The wrapper activates `~/zephyrproject/.venv` and exports `ZEPHYR_BASE`, because
**`west` cannot resolve a workspace from inside this repo** — it walks *up* from
`$PWD` looking for `.west/`. Override the workspace or board if needed:

```bash
SOPHON_ZEPHYR_WORKSPACE=~/other-zephyr scripts/build.sh
SOPHON_BOARD=xiao_ble/nrf52840 scripts/build.sh
```

Requires Zephyr **>= 4.4**; `CMakeLists.txt` fails at configure time otherwise.

## Flash

Double-tap the reset button — a UF2 volume mounts — then:

```bash
scripts/flash.sh
```

It tries `west flash -r uf2` and falls back to copying `build/zephyr/zephyr.uf2`
onto the volume. The runner matches a board-id string; if the fallback is what
works, record the id the board actually reports here:

> **Observed board-id:** `nRF52840-SeeedXiaoSense-v1` — on a board reporting
> `Model: Seeed XIAO nRF52840 Sense Plus`, bootloader 0.9.2, volume
> `/Volumes/XIAO-SENSE`.
>
> **The uf2 runner does not match it.** `board.cmake` passes
> `--board-id=Seeed_XIAO_nRF52840_Sense`, so `west flash -r uf2` fails with
> `No matching UF2 partitions found` and the script's copy fallback is the path
> that actually works. Expect that, and expect macOS to report
> `could not copy extended attributes ... Device not configured` — the bootloader
> reboots the moment it has a complete image, so the volume disappears before the
> attributes can be written. The copy has already succeeded; the volume ejecting
> is the success signal. `flash.sh` passes `cp -X` and checks for the unmount
> rather than trusting `cp`'s exit status.

## Console

The XIAO has **no UART-to-USB bridge**, so USB CDC ACM is the only console:

```bash
minicom -D /dev/cu.usbmodem* -b 115200
```

Note `/dev/cu.*`, **not** `/dev/tty.*` — the `tty` node blocks on carrier detect
and fails with `Device not configured`.

Expect, a few seconds after boot (the board sets a 4000 ms log startup delay so
the banner survives USB enumeration):

```
*** Booting Zephyr OS build ... ***
[00:00:04.000,000] <inf> sophon: Sophon skeleton starting
[00:00:04.010,000] <inf> sophon_ble: advertising as Sophon-A3F2
```

On connect it logs the **negotiated ATT MTU** — expect `23`. That number is not
assumed anywhere; if it ever reads lower, `notify` starts failing with
`-EMSGSIZE` and this line is the explanation.

## What the LED means

Green (`led1`):

| Pattern | Meaning |
|---|---|
| Blinking ~2 Hz | Advertising, no central connected |
| Solid | Connected |
| Fast blink ~5 Hz | BLE init failed — check the console |

## Layout

```
src/main.c      init, LED heartbeat, 1 Hz notify loop
src/ble.c/.h    bt_enable, advertising, GATT service, notify
src/ident.c/.h  FICR device id -> "Sophon-A3F2"
src/frame.h     the packed 18-byte wire frame
prj.conf        Kconfig; note what is deliberately NOT set
PROTOCOL.md     the wire contract shared with the iOS app
```

## Before changing the wire format or radio config

Read [`PROTOCOL.md`](PROTOCOL.md) for the live contract, and
[`ios/Sophon/UPDATED-PLAN.md`](../../ios/Sophon/UPDATED-PLAN.md) for the reasoning
behind it — the ATT MTU budget, the connection-event capacity analysis, and the
batching/DLE arithmetic. It explains why the frame is 18 bytes, why 50 Hz, and why
the MTU is left at its default. Those choices are load-bearing and not obvious
from the code.

[`ORIGINAL-PLAN.md`](../../ios/Sophon/ORIGINAL-PLAN.md) beside it is the frozen
pre-implementation version of the same document, kept as the record of what was
approved. Where the two disagree, the updated one is right.
