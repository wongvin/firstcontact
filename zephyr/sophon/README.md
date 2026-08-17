# Sophon — firmware

BLE peripheral on a **Seeed XIAO nRF52840 Sense Plus**, streaming IMU motion to
the iOS app at [`ios/Sophon/`](../../ios/Sophon/).

Named for Cixin Liu's proton-scale probe: it sits inside what it observes and
relays continuously to a distant receiver.

## Status

**Streaming motion (#209).** The board samples the on-board LSM6DS3TR-C at a
nominal **52 Hz**, paced by the sensor's data-ready interrupt, and notifies one
18-byte frame per sample. Accel is ±4 g in milli-g; gyro is ±250 dps in
centi-deg/s.

52 Hz rather than the plan's 50: the LSM6DSL's rate grid has no 50 Hz step, and
pacing off the sensor beats resampling it onto a timer that drifts against it.

**Measured, it runs at 54.2–54.4 Hz** — the ODR comes off an internal RC
oscillator and lands 4.6% above nominal on this board. Nothing is wrong; the nominal rate is
what the sensor was asked for, not what it delivers. **`t_ms` is the only
trustworthy timebase**, and anything integrating gyro must use it.
[`PROTOCOL.md`](PROTOCOL.md) has the full argument and the budget it stays inside.

If the IMU is absent or fails to start, the board **falls back to the #208
behaviour** — 1 Hz, axes zero — rather than going silent, so the link stays
verifiable and the failure is visible from the phone.

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
[00:00:04.000,000] <inf> sophon: Sophon starting
[00:00:04.005,000] <inf> sophon_imu: IMU streaming: accel +/-4 g, gyro +/-250 dps, ODR 52 Hz
[00:00:04.010,000] <inf> sophon_ble: advertising as Sophon-A3F2
```

A board with no working IMU says so and keeps going:

```
[00:00:04.005,000] <err> sophon_imu: LSM6DS3TR-C not ready -- check the sensor power rail
[00:00:04.005,000] <wrn> sophon: no IMU (-19); falling back to 1000 ms zero-filled frames
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
src/main.c      init, LED heartbeat, frame assembly + notify policy
src/ble.c/.h    bt_enable, advertising, GATT service, notify
src/imu.c/.h    LSM6DS3TR-C data-ready trigger, raw units -> wire units
src/ident.c/.h  FICR device id -> "Sophon-A3F2"
src/frame.h     the packed 18-byte wire frame
prj.conf        Kconfig; note what is deliberately NOT set
PROTOCOL.md     the wire contract shared with the iOS app
```

## Before changing the wire format or radio config

Read [`PROTOCOL.md`](PROTOCOL.md) for the live contract, and
[`ios/Sophon/UPDATED-PLAN.md`](../../ios/Sophon/UPDATED-PLAN.md) for the reasoning
behind it — the ATT MTU budget, the connection-event capacity analysis, and the
batching/DLE arithmetic. It explains why the frame is 18 bytes, why ~50 Hz, and
why the MTU is left at its default. Those choices are load-bearing and not obvious
from the code.

The sensor's full-scale ranges are load-bearing too, and in a way that is easy to
miss: **the gyro range is capped by the wire format**, not by the sensor. See
*Measurement ranges* in [`PROTOCOL.md`](PROTOCOL.md); `src/imu.c` asserts it at
compile time.

[`ORIGINAL-PLAN.md`](../../ios/Sophon/ORIGINAL-PLAN.md) beside it is the frozen
pre-implementation version of the same document, kept as the record of what was
approved. Where the two disagree, the updated one is right.
