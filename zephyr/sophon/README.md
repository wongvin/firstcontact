# Sophon — firmware

BLE peripheral on a **Seeed XIAO nRF52840 Sense Plus**, streaming IMU motion to
the iOS app at [`ios/Sophon/`](../../ios/Sophon/). With a **Wio-SX1262** LoRa
board fitted, the same image becomes a long-range relay instead: a **sensor**
sends its motion over 915 MHz LoRa to a **gateway**, which serves it to the app
over the same BLE protocol (#303). See [§ Roles](#roles-direct-sensor-gateway-303).

Named for Cixin Liu's proton-scale probe: it sits inside what it observes and
relays continuously to a distant receiver.

## The board

**Seeed XIAO nRF52840 Sense Plus.** Everything established about its battery
sensing — the divider, the enable pin's hazard, the charger, what the hardware
can and cannot report, and how to read the schematic — is in
[HARDWARE.md](HARDWARE.md).

Two things from there worth knowing before touching this app:

- **Use the KiCad sources, not the PDF.** The wiki's `…SCH_PCB_v1.1.zip` contains
  a **v1.0** schematic, and it disagrees with v1.1 about a resistor that scales
  every battery reading. #268 shipped the wrong value on the strength of it.
- **P0.14 must be held low.** It looks like a power-saving enable; releasing it
  can push P0.31 to its 3.6 V limit.

HARDWARE.md also covers the other two boards a relay uses:
- the **Seeed Studio XIAO nRF52840** (formerly XIAO BLE: no IMU, no microphone),
  the gateway board;
- the **Wio-SX1262 for XIAO** carrier and module, the LoRa radio: its pin map,
  module facts and antenna warning.

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

## Roles: direct, sensor, gateway (#303)

**One image runs on every board.** At boot it works out its role from what is
attached:

| Radio (Wio-SX1262) | IMU | Role | What it does |
|---|---|---|---|
| no | either | **direct** | the BLE peripheral above, unchanged |
| yes | yes | **sensor** | sends every sample over LoRa; advertises only its name and SMP |
| yes | no | **gateway** | receives LoRa and serves the sensor's frames to the app over BLE |

- **Radio presence** is checked before the SX1262 driver starts (`src/role.c`).
  The loramac-node driver's BUSY wait has no timeout, so a board with no Wio
  would hang in it. Instead, the `lora0` node is `zephyr,deferred-init`, and the
  driver starts only after the chip answers a raw SPI read of its sync-word
  register.
- **The role is logged twice:** at boot, and again 10 s later, because the boot
  burst often loses lines on the USB console:
  ```
  <inf> sophon_role: radio check: sync word 0x1424 -> SX126x present
  <inf> sophon_role: role: sensor (radio yes, IMU yes)
  ```
- **The app sees no difference.** A gateway passes the sensor's 18-byte frames
  through unchanged, with the sensor's `seq` and `t_ms`, and serves the sensor's
  battery. The sensor leaves the Sophon service UUID out of its advertising, so
  the app never lists it. Behind a gateway, the app's **LoRa link** section
  shows the radio link itself (#309).
- **The role can be overridden from the app** (#329). Auto, the default, is the
  table above, run at every boot; see § Configuring a board.
- **Image confirmation:** a direct board and a gateway confirm a trial image on
  their first delivered BLE frame. A sensor, which has no subscriber, confirms
  on its first completed LoRa send.
- **A board accepts one connection.** With Sophon open on several phones or
  iPads, one of them will hold the board and the others won't see it. Close
  the app on the devices you aren't using, and always before `flash-ota.sh`.

### Configuring a board (#329)

The app's **Configuration** section shows a board's role and LoRa settings: what
it runs now, and what it will run after a restart. **Edit…** changes them:

- **Role:** Auto (detect from hardware at boot, the default), direct, sensor or
  gateway, offering only roles the board's hardware supports.
- **LoRa:** preset, frequency (902.25–927.75 MHz), peer, and a TX power override.
- **Save** stores the setting; **Save and restart** applies it now; **Restore
  defaults** erases it and restarts as Auto.

The board keeps the setting in flash (`settings_partition`, 0xFC000), through
power-off, OTA and SWD reflashing. A board set to **sensor** stops advertising
the Sophon service. The app lists it under **Sensors** and connects to it only
when tapped, so it doesn't hold the board's one connection.

**If a stored config crashes the board at boot**, the boot-loop guard runs it on
defaults after three failed boots in a row, so the app can reach it to restore
defaults. As a last resort, erase the settings partition over SWD:

```bash
openocd -f interface/cmsis-dap.cfg -c "transport select swd" -f target/nrf52.cfg \
  -c "init; halt; flash erase_address 0xFC000 0x2000; reset; exit"
```

Wire layouts: PROTOCOL.md § Config frame. Design: CONFIG-PLAN.md.

### The radio link

915 MHz, 500 kHz bandwidth, one fixed channel. The air rate is a **preset** from
`src/lora_presets.c`, chosen at build time with `CONFIG_SOPHON_LORA_PRESET`. The
default, **V6**, is SF7, CR 4/5, 4 samples per packet, +22 dBm (#321), and it
stands until the walk test chooses one (#313). Both boards are built from
the same image, so they always agree. The other options are
`CONFIG_SOPHON_LORA_FREQ_HZ` and `CONFIG_SOPHON_LORA_PEER_ID` (0 = lock onto the
first sensor heard). All are in the app's `Kconfig`.

**Each can also be set per board from the app** (#329), along with the role.
The board stores the setting and applies it when it restarts; see § Configuring
a board.

Both ends log their link every 10 s:

```
<inf> sophon_lora: preset V6: SF7 BW500 CR4/5 k=4 v2 +22 dBm, 915.000 MHz; full packet 60 B = 29 ms on air
<inf> sophon_lora: lora tx: 134 pkts, 536 samples, 0 send errors, 0 dropped (queue)          # sensor
<inf> sophon_lora: lora rx: 134 pkts, 0 bad, 0 wrong peer; 536 samples, 0 missing, LQ 100.0%; RSSI avg -6 min -6, SNR avg 12 min 12; 0 DIO1 recoveries total   # gateway
```

**`DIO1 recoveries`** counts the gateway recovering a lost radio interrupt.
loramac-node's glue can miss a DIO1 edge, which would leave the gateway deaf
for good, so a watchdog clears it (HARDWARE.md and LORA-UPDATED-PLAN.md have
the details). A rising count is worth investigating, but the link survives it.

**Always fit the antenna before a radio-equipped board powers up.** A sensor
transmits as soon as it boots.

### Not yet

- **Walk-test mode,** which rotates through the presets for field comparison:
  planned in #313, with the walk itself. The app's recorder and
  `scripts/walktest-report.py` already exist.
- **Measured latency:** #314. Computed figures are in LORA-UPDATED-PLAN.md
  § Variants.
- **Frequency hopping and a downlink:** #304.

### nRF54LM20A port (in progress)

Sophon is being ported to the Seeed XIAO nRF54LM20A Sense (#368).
[NRF54LM20A-PLAN.md](NRF54LM20A-PLAN.md) is the **frozen** plan as approved.

### Where the LoRa design lives

| Document | What it is |
|---|---|
| [LORA-PROTOCOL.md](LORA-PROTOCOL.md) | the **live contract** between sensor and gateway: packet formats, presets, roles, how the gateway maps onto PROTOCOL.md |
| [LORA-UPDATED-PLAN.md](LORA-UPDATED-PLAN.md) | the **current design record**: airtime, variants, levers for range and latency, the walk test, and every change from the original |
| [LORA-PLAN.md](LORA-PLAN.md) | the **frozen** plan as approved |
| [PROTOCOL.md](PROTOCOL.md) § LoRa Link frame | the app-facing link-stats record (#309) |

Host test for the packet codec, with no hardware needed:

```bash
scripts/test-codec.sh
```

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
SOPHON_BOARD=xiao_ble/nrf52840/sense scripts/build.sh   # the default
```

The plain `xiao_ble/nrf52840` target **does not build**: `src/imu.c` needs the
Sense devicetree's LSM6DSL node. The Sense image runs on a plain XIAO nRF52840
anyway. The IMU fails to initialise and the board sends zero-axis frames, as
`Sophon-01A7` does (#301).

Requires Zephyr **>= 4.4**; `CMakeLists.txt` fails at configure time otherwise.

### Editor support — clangd, not CMake Tools (#279)

A build already writes `compile_commands.json`, so C completion and
go-to-definition need nothing installed — `clangd` ships with Xcode
(`xcrun -f clangd`). Point it at a build:

```bash
ln -sf build-mcuboot/sophon/compile_commands.json compile_commands.json
#  or: build/compile_commands.json for the UF2 build
```

The symlink is gitignored; it names whichever build you are working in.

[`.clangd`](.clangd) drops three GCC-only flags that Apple clang does not
recognise. Without it every file opens with three driver errors before any code
is analysed, which looks like a broken setup and is not. Verified with
`clangd --check=src/ble.c`: no driver errors and **no diagnostics about this
code**. `--check` still reports ~10 "errors" from clangd's own refactoring
machinery failing on Zephyr macros — those are not about the source.

**Do not point the VS Code CMake Tools extension at this directory.** It writes a
`cmake.sourceDirectory` into `.vscode/settings.json` and then tries to configure
the app standalone, which cannot work: `west` can only resolve the workspace
through `scripts/build.sh`. That setting is machine-specific as well, carrying an
absolute home path, which is why `.vscode/` is gitignored.

Formatting follows Zephyr's own style, copied to
[`zephyr/.clang-format`](../.clang-format), and **`src/` is clean under it** (#280):

```bash
# check
"$(xcrun -f clang-format)" --style=file --dry-run --Werror src/*.c src/*.h
# apply
"$(xcrun -f clang-format)" --style=file -i src/*.c src/*.h
```

Adopting it moved 176 of 1998 lines, and the rebuilt binary was **byte-identical
apart from the three characters of the build timestamp** — formatting does not
reach codegen, which is worth knowing before reformatting firmware again.

## Flash

```bash
scripts/build.sh                      # MCUboot via sysbuild (the default, #270)
scripts/flash-ota.sh                  # app only, over the air (#271)
scripts/airdrop-fw.sh                 # app only, over the air from the iPhone (#357)
scripts/flash-swd.sh                  # bootloader + app, over a CMSIS-DAP probe

SOPHON_BOOT=uf2 scripts/build.sh      # UF2, only for a board not yet migrated
scripts/flash-uf2.sh                  #   double-tap reset first; a volume mounts
```

**Every board runs MCUboot**: `Sophon-86F0`, `Sophon-4D88` and `Sophon-01A7`.
The UF2 build is there for a board that arrives on the Adafruit bootloader, which
then migrates by `sophon-installer` or `flash-swd.sh`. Both of those consume the
MCUboot build.

**An MCUboot build needs the signing key**: `~/.sophon/keys/sophon-fw-rsa-2048.pem`,
or an absolute path in `SOPHON_SIGNING_KEY`. Without it the build stops with an
error. A UF2 build needs no key.

Which path a board takes, the memory maps, the backup and recovery procedure, and
the hazards of working over SWD are all in [BOOTLOADER.md](BOOTLOADER.md).

The one worth knowing before you touch a probe: **never end an SWD session with
`resume` — always `reset run`.** Resuming after a halt leaves the BLE stack
believing a connection the peer abandoned is still live, and only a reset
recovers it.

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
> is the success signal. `flash-uf2.sh` passes `cp -X` and checks for the unmount
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
src/main.c           init, role order, LED heartbeat, frame assembly, notify + relay queue
src/ble.c/.h         bt_enable, advertising (per role), GATT service, notify, LoRa Link
src/imu.c/.h         LSM6DS3TR-C data-ready trigger, raw units -> wire units
src/battery.c/.h     divider sampling, VBUS detection
src/ident.c/.h       FICR device id -> "Sophon-A3F2" (and the sensor id)
src/frame.h          the packed 18-byte wire frame
src/role.c/.h        radio presence check, runtime role (#303)
src/lora_link.c/.h   sensor TX thread, gateway RX + DIO1 watchdog, link stats (#303)
src/lora_codec.c/.h  LoRa packet v1/v2 encode/decode; plain C, host-tested (#303)
src/lora_presets.c/.h  air-rate presets V0-V6b (#303)
Kconfig              app options: LoRa preset, frequency, peer id
app.overlay          battery divider, Wio-SX1262 node on spi2
prj.conf             Kconfig; note what is deliberately NOT set
swd/app-mcuboot.conf MCUboot-only Kconfig (MCUmgr, image manager) (#306)
tests/lora_codec/    host test for the codec (scripts/test-codec.sh)
PROTOCOL.md          the wire contract shared with the iOS app
LORA-PROTOCOL.md     the sensor <-> gateway LoRa contract
```

## Before changing the wire format or radio config

**For the LoRa link,** read [`LORA-PROTOCOL.md`](LORA-PROTOCOL.md), the live
contract, and [`LORA-UPDATED-PLAN.md`](LORA-UPDATED-PLAN.md), the reasoning:
airtime, presets, and why the sensor sends v2 packets at SF7/500 kHz. The rest of
this section is about the BLE side.

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
