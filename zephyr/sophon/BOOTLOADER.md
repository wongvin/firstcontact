# Bootloaders, flashing and recovery

What occupies flash, what starts the application, and how to put firmware on the
board without losing the ability to put firmware on the board.

Companion docs: [HARDWARE.md](HARDWARE.md) is what the board *is* (divider,
charger, pin hazards); [PROTOCOL.md](PROTOCOL.md) is what it says on the air;
[README.md](README.md) is the day-to-day build and console.

Established while implementing #253. Several sections record things that were
wrong on the first attempt — kept deliberately, because each produced a
plausible result rather than an error.

## The two boot paths

| | UF2 (stock) | MCUboot (#253) |
|---|---|---|
| Bootloader | Adafruit UF2, at the **top** of flash | MCUboot, at the **bottom** |
| Entered by | double-tapping reset (K1) | nothing — it *is* the reset vector |
| Flashing | copy `.uf2` to a mounted volume | SWD, via `scripts/flash-swd.sh` |
| Recovery | double-tap, always available | **SWD only** |
| App space | 788 KB | 480 KB (two slots) |
| Also present | Nordic MBR + SoftDevice S140 v7.3.0 | neither — overwritten |
| Update path | UF2, or BLE OTA via the SoftDevice | dual-slot with rollback, **no transport yet** |

The boards have diverged and both paths are supported during the transition:

| Board | Path |
|---|---|
| `Sophon-86F0` | MCUboot / SWD |
| `Sophon-4D88` | UF2 (not migrated) |

## Memory maps

Not to a shared scale; each column is internally proportional only.

```
        A: ADAFRUIT UF2 (stock)      B: MCUBOOT  ...OFFSET=n      C: MCUBOOT  ...OFFSET=y
                                        (swap via scratch)         (swap in place, in use)

0x100000 ┌──────────────────┐  0x100000 ┌──────────────────┐  0x100000 ┌──────────────────┐
         │ UF2 bootloader   │           │ storage    16 KB │           │ storage    16 KB │
         │ Adafruit   48 KB │  0x0FC000 ├──────────────────┤  0x0FC000 ├──────────────────┤
0x0F4000 ├──────────────────┤           │ scratch   120 KB │           │                  │
         │ Storage    32 KB │           │ swap workspace   │           │ slot1 "image-1"  │
0x0EC000 ├──────────────────┤  0x0DE000 ├──────────────────┤           │        480 KB    │
         │                  │           │ slot1 "image-1"  │           │ DFU target       │
         │ Application      │           │        420 KB    │           │ image at +4 KB   │
         │        788 KB    │           │ DFU target       │           │ (empty)          │
         │                  │           │ (empty)          │  0x084000 ├──────────────────┤
         │ Sophon @0x27000  │  0x075000 ├──────────────────┤           │ slot0 "image-0"  │
         │                  │           │ slot0 "image-0"  │           │        480 KB    │
         │                  │           │        420 KB    │           │ signed Sophon    │
0x027000 ├──────────────────┤           │ signed Sophon    │           │ 169 KB   (34.7%) │
         │ SoftDevice S140  │  0x00C000 ├──────────────────┤  0x00C000 ├──────────────────┤
         │ v7.3.0    152 KB │           │ mcuboot    48 KB │           │ mcuboot    48 KB │
0x001000 ├──────────────────┤           │ 39.2 KB  (79.8%) │           │ 39.2 KB  (79.8%) │
         │ Nordic MBR  4 KB │           │                  │           │                  │
0x000000 └──────────────────┘  0x000000 └──────────────────┘  0x000000 └──────────────────┘
```

**Column C is what runs today.** Column B is what an earlier revision built: the
partition table was copied from Zephyr's `nrf52840dk` layout, which is written
for swap-using-scratch, while sysbuild actually selects
`CONFIG_BOOT_SWAP_USING_OFFSET=y`. That allocated 120 KB nothing ever touched,
and the cost came straight off the slots.

Reading across: A → B/C loses the SoftDevice and halves the application space
(the second slot is not overhead, it is the ability to fail an update and get
the old image back), and turns recovery from a button press into a debug probe.

### Where the stock layout comes from

`nordic/nrf52840_partition_uf2_sdv7.dtsi`, pulled in by `xiao_ble_common.dtsi` —
**not** the board directory, which is why grepping `boards/seeed/xiao_ble/`
finds nothing. Its `0x27000` boundary is exactly where the SoftDevice ends.

## The Nordic SoftDevice

A precompiled, closed-source Bluetooth stack from Nordic, from the nRF5 SDK era
that predates Zephyr. It runs on the same core as the application but is walled
off: it owns the low region of flash, reserves RAM, takes `RADIO`, `TIMER0`,
`RTC0`, `CCM`, `AAR`, `ECB` and some SWIs outright, and is called through **SVC**
instructions so the application never links against its symbols.

It ships with the **MBR** — ~4 KB at `0x0` that owns the real reset vector and
jumps to a bootloader whose address it reads from `UICR NRFFW[0]`.

**S140 v7.3.0 was genuinely present on this board**, confirmed by the info-struct
magic `0x51B1E5DB` at `0x3004` and a declared size of `0x27000`. An earlier
revision of the overlay comment claimed the region was empty padding; it was not.

**Sophon never called it.** Zephyr runs its own controller — the boot log's
`manufacturer 0x05f1` is the Linux Foundation, not Nordic's `0x0059`. The
SoftDevice was there for the Adafruit bootloader's BLE OTA path. MCUboot has
overwritten it, so that path is gone too.

## SWD access

### Test points

All four are on **B.Cu (the back)**, a 2×2 grid at 2.54 mm pitch. Positions are
design/top-view coordinates on a 20.96 × 17.78 mm board — **left/right mirrors
when you look at the back**.

| | Net | From left edge | From top edge |
|---|---|---|---|
| **TP1** | GND | 16.51 mm | 10.16 mm |
| **TP2** | RESET (P0.18) | 16.51 mm | 7.62 mm |
| **TP3** | SWDCLK | 19.05 mm | 10.16 mm |
| **TP5** | SWDIO | 19.05 mm | 7.62 mm |

There is no TP4 and no 3V3 test point. Derived from the KiCad netlist with
[`scripts/kicad-netlist.py`](scripts/kicad-netlist.py), not by probing pads.

**K1** is the reset button — `BUTTON-4P`, on the front, shorting `RESET` to GND.
It shares a net with TP2. `UICR PSELRESET` reads `0x12` (pin 18), which is what
makes P0.18 the hardware reset input; a mass erase clears that, so K1 stops
working until UICR is restored.

### TP2 is not needed

The Raspberry Pi Debug Probe's 3-pin debug connector carries only SWCLK, GND and
SWDIO — there is no reset line to attach. It does not matter:

| Capability | Mechanism | Needs nRESET? |
|---|---|---|
| Connect, halt, read | SWD | No |
| Reset | `cortex_m reset_config sysresetreq` | No |
| Mass erase + unlock | CTRL-AP, IDR `0x02880000` | No |
| Restore UICR | writable flash bank at `0x10001000` | No |

nRESET would add only connect-under-reset, which CTRL-AP supersedes on this chip
— `nrf52_recover` erases and unlocks a part that will not halt at all.

### OpenOCD

Ships with the Zephyr SDK; no extra host tooling needed.

```
binary   ~/zephyr-sdk-1.0.1/hosttools/opt/openocd/bin/openocd
scripts  ~/zephyr-sdk-1.0.1/hosttools/opt/openocd/share/openocd/scripts
```

`scripts/flash-swd.sh` wraps this. By hand:

```bash
openocd -s "$SCRIPTS" -f interface/cmsis-dap.cfg -c "transport select swd" \
        -c "adapter speed 4000" -f target/nrf52.cfg -c "init; halt; ...; reset run; exit"
```

A healthy connection reports `SWD DPIDR 0x2ba01477` and
`Cortex-M4 r0p1 processor detected`.

### APPROTECT

`UICR APPROTECT` reads `0xFFFFFFFF` and `CTRL-AP APPROTECTSTATUS` reads `1`:
debug access is open, no recovery needed. Note that erasing UICR *sets* APPROTECT
to `0xFFFFFFFF`, so a mass erase cannot lock you out.

## Backup and recovery

The backup is the artefact that makes everything else reversible. **Take one
before migrating any board.**

```bash
openocd ... -c "init; halt;
   dump_image flash-1MB.bin 0x00000000 0x100000;
   dump_image uicr-4KB.bin  0x10001000 0x1000;
   reset run; exit"
```

Both halves matter. UICR holds `NRFFW[0]` (the bootloader address the MBR jumps
to) and `PSELRESET` (what makes the reset button work); a mass erase clears them,
and without the backup the board has no bootloader pointer and a dead K1.

Backups live in `~/sophon-flash-backups/` — **outside the repo**, because a
1 MB image derived from a CC BY-SA design does not belong in a public repo with
no LICENSE. That also means they are unreplicated; losing them and the probe
together would leave a board with no bootloader and no known-good image.

### Verify with `cmp`, not `verify_image`

`verify_image` loads a CRC routine into target RAM, times out on 1 MB, and leaves
the CPU in a HardFault. Re-dump and compare on the host instead — which
re-tests read repeatability for free.

### Restoring

```bash
openocd ... -c "init; reset halt;
   flash write_image erase flash-1MB.bin 0x00000000 bin;
   flash write_image       uicr-4KB.bin  0x10001000 bin;
   reset run; exit"
```

Roughly 50 s including the erase, 27 s onto an already-blank chip.

### Full recovery from a locked or unresponsive board

```bash
openocd ... -c "init; nrf52_recover; exit"     # mass erase + unlock
# then restore as above
```

`nrf52_recover` leaves the CPU in lockup (`clearing lockup after double fault`)
because it is executing blank flash. Expected, not a fault.

**Both paths are demonstrated, not assumed** — the full mass-erase-and-restore
cycle was run and produced a byte-identical chip that booted and mounted
`XIAO-SENSE`.

## MCUboot on this board

### The board defines no partitions

A sysbuild with MCUboot fails at configure time with `required nodelabel not
found: slot0_partition`, because the XIAO ships with a UF2 bootloader and needs
none. Both overlays live in `swd/`.

**`mcuboot-partitions.overlay`** deletes the four stock partitions and defines
`boot_partition`, `slot0_partition`, `slot1_partition`, `storage_partition`.
Deleting `boot_partition` is the consequential one — that is the Adafruit
bootloader's region.

**`app-slot0.overlay`** points the *application* at slot0. It must be separate:
the partition table is shared by both images, but the `zephyr,code-partition`
choice is not. MCUboot's own `app.overlay` points itself at `boot_partition`, and
application overlays are applied after it — so a `chosen` in the shared file
would override MCUboot's own choice and build a bootloader expecting to run from
slot 0.

### `sysbuild/mcuboot.conf`

MCUboot inherits the board's devicetree while being a minimal, single-threaded
build, and two nodes do not survive that. Both fail at **link** time, minutes
into a build, rather than at configure time — so neither is visible early.

**One needed redirecting, not removing.** The board's console is USB CDC ACM, so
`uart_console.c` links against a device MCUboot never instantiates:
`undefined reference to '__device_dts_ord_127'`. The first fix was
`CONFIG_CONSOLE=n` / `CONFIG_SERIAL=n`, which built and cost more than it saved —
see [The two consoles](#the-two-consoles). The console is now **on** and pointed
at `uart0` by `swd/mcuboot-console.overlay`.

**One genuinely has to go.** `regulator-fixed`, the IMU's power rail, calls
`k_usleep`, which does not exist under `CONFIG_MULTITHREADING=n`:
`undefined reference to 'z_impl_k_usleep'`. Hence `CONFIG_REGULATOR=n`.

So the file sets:

| | |
|---|---|
| `CONFIG_CONSOLE=y`, `CONFIG_SERIAL=y`, `CONFIG_UART_CONSOLE=y` | console on, over a plain UARTE |
| `CONFIG_LOG=y`, `CONFIG_LOG_BACKEND_UART=y` | route MCUboot's `BOOT_LOG_*` to it |
| `CONFIG_MCUBOOT_LOG_LEVEL_INF=y` | the level that yields the boot narration below |
| `CONFIG_REGULATOR=n` | the `k_usleep` link failure above |
| `CONFIG_MCUBOOT_SERIAL=n` | serial recovery needs the very USB stack this build omits |

### Swap mode and slot sizing

sysbuild selects `CONFIG_BOOT_SWAP_USING_OFFSET=y`, which swaps in place and
**needs no scratch partition**. Its constraints instead:

- the incoming image is written at `slot1 + one sector`, so slot1's usable
  capacity is 4 KB less than its size;
- all sectors in both slots must be the same size — satisfied here, the nRF52840
  has uniform 4 KB pages.

### What MCUboot does not give us yet

Sophon has **no DFU transport** — no MCUmgr, no SMP over BLE. slot1 can only be
filled over SWD, which is also how slot0 is flashed directly. Until a transport
exists, the dual-slot layout costs ~450 KB of application space for a mechanism
nothing can reach. The alternative is `CONFIG_SINGLE_APPLICATION_SLOT`, which
keeps image validation and drops the update path.

### Why the application cannot simply stay at 0x27000

An MCUboot image is `header ‖ vectors ‖ code ‖ signature TLVs`, and the header is
512 bytes — so vectors sit at `slot_start + 0x200`. Slots must be 4096-byte page
aligned, and `0x27000 − 0x200` is not, so with a 512-byte header the vector table
can never land on a page boundary. Setting `CONFIG_ROM_START_OFFSET=0x1000` and
slot0 to `0x26000` *would* put vectors exactly at `0x27000` — it is not
impossible, just wasteful.

The image is also RSA-2048 signed, so an unsigned UF2-built image is rejected
regardless of address; `imgtool` only prepends a header and cannot relocate a
vector table.

The real reason is capacity: at `0x27000` slot0 would be 788 KB and there would
be nowhere for slot1.

## The two consoles

There are two, on separate cables, and they carry different things.

| | Device | Carries | Rate |
|---|---|---|---|
| Board USB | `CDC ACM serial backend` / Zephyr Project | the **application** | irrelevant — see below |
| Probe UART | Debug Probe's second interface | **MCUboot** | 115200 8N1, and it matters |

Node names are **not stable** — macOS renumbers `cu.usbmodem*` on re-enumeration,
so a script that hardcodes one will silently read the wrong device or fail
outright. Discover them, do not assume. And use `cu.*`, never `tty.*`: on macOS
`tty.*` blocks waiting for carrier detect and fails against a CDC ACM peripheral
with `Device not configured`.

### Serial paths

Three cables reach this board, and only two of them carry characters.

**1 — Application console, over the board's own USB.** The nRF52840 has a
native USB device peripheral; there is no UART-to-USB bridge anywhere on the
board, so the MCU *is* the USB device.

    nRF52840 (U1)  USBD
        D+   pin AD6 --[ R11 ]-- USB_D+ --+
        D-   pin AD4 --[ R10 ]-- USB_D- --+-- USB1 (USB-C) == cable ==> Mac
        VBUS pin AD2 --------------------+                              |
                                                                        v
                          "CDC ACM serial backend" / "Zephyr Project"
                          VID 0x2fe3  PID 0x0004
                                     /dev/cu.usbmodem<N>

`R10`/`R11` are series termination, not level shifting. The console is a CDC ACM
instance that `boards/common/usb/cdc_acm_serial.dtsi` makes `zephyr,console`.

**2 — MCUboot console, over the probe's UART.** A plain UARTE, no USB stack
involved. Note the crossover: the probe's TX goes to the board's RX.

    nRF52840 (U1)  UARTE0
        P1.11 (B19) TX --> pad D6 (U4 pin 7) ---- wire ----> probe UART RX
        P1.12 (B17) RX <-- pad D7 (U4 pin 8) <--- wire ----- probe UART TX
        GND ------------------------------------ wire ----- probe GND
                                                              |
                                        Debug Probe == USB ==> Mac
                                                              |
                                                              v
                                                    /dev/cu.usbmodem<M>

**3 — SWD, which is not a serial path.** The probe's other USB interface.

    Debug Probe  CMSIS-DAP -- 3-pin -- TP5 -> SWDIO  (U1 AC24)
                                       TP3 -> SWDCLK (U1 AA24)
                                       TP1 -> GND

It carries debug transactions, not console output. It *could* carry a console —
via RTT, which rides these same wires and needs no extra pins, or via SWO, which
needs a pin the 3-pin connector does not have — but neither is enabled.

### Why the bootloader could not use path 1

**MCUboot does not bring up the USB stack**, so building it against the board's
default console fails at *link* time, minutes in:

    undefined reference to `__device_dts_ord_127'

The first response was to switch MCUboot's console off entirely, and that cost
more than it saved: the bootloader logged nothing, so its stage of the boot was
invisible. Asked how long MCUboot took, the only remaining tool was sampling the
program counter over SWD — which halts the CPU, perturbs the very measurement it
is taking, and strands the BLE link.

`uart0` needs no USB stack. It is a plain UARTE on **P1.11 (TX, pad D6)** and
**P1.12 (RX, pad D7)**, already `status = "okay"` in the board devicetree, and
reachable from the Debug Probe's UART connector. `swd/mcuboot-console.overlay`
points MCUboot's console there; the application is untouched. Cost: **992 bytes**.

What it prints:

    *** Using Zephyr OS build v4.4.0-10953-gda0718ca0d52 ***
    I: Starting bootloader
    I: Primary image: magic=unset, swap_type=0x1, copy_done=0x3, image_ok=0x3
    I: Secondary image: magic=unset, swap_type=0x1, copy_done=0x3, image_ok=0x3
    I: Boot source: none
    I: Bootloader chainload address offset: 0xc000
    I: Image version: v2.0.0
    I: Jumping to the first image slot

`magic=unset` on the primary image means slot0 carries no image trailer, so
MCUboot treats it as permanently resident rather than on trial. That is why
nothing has ever reverted, and it is the state #270's swap-and-revert test has to
change.

### Baud: decorative on one, load-bearing on the other

For **CDC ACM the settings do not matter**. Zephyr records what the host sends —
`usbd_cdc_acm.c` parses `SET_LINE_CODING` into a `uart_config` — but there is no
physical UART behind it and the wire is USB at 12 Mbit/s. Baud, parity and stop
bits are a legacy negotiation the device politely stores.

For **`uart0` they are real**: 115200 8N1, no flow control, and both ends must
agree. Get it wrong and you get high-bit garbage rather than silence.

One host-side trap, which produced exactly that garbage here: **calling `stty`
and then opening the port is unreliable on macOS**, because the open can reset
line settings. Set the rate with `termios` on the already-open descriptor
instead. The symptom looks like a wiring fault and is not one.

### Timestamps are available for 3.8 KB, and deliberately not enabled

MCUboot logs through Zephyr's logging with `CONFIG_LOG_MODE_MINIMAL=y`, which
drops timestamps and formatting — hence `I: Starting bootloader` rather than
`[00:00:00.123,456] <inf> mcuboot: ...`. Switching to
`CONFIG_LOG_MODE_IMMEDIATE` adds them, and it is a pure config change; it builds
and fits.

| | Flash | of 48 KB |
|---|---|---|
| `LOG_MODE_MINIMAL` (current) | 40,176 B | 81.7% |
| `LOG_MODE_IMMEDIATE` + timestamps | 43,972 B | 89.5% |

**Left at MINIMAL.** The 3,796 bytes are not the point; the headroom is. MCUboot
is the one image where running out of room is expensive — it is what recovers
everything else, and growing its partition means moving `slot0` and reflashing
both images. What timestamps would add is narrow: the log is already ordered and
already answers the questions that arise. The one thing they would give is
MCUboot's boot duration, which is measurable once by other means rather than
being paid for on every line forever.

## Hazards, all confirmed on hardware

### Never end an SWD session with `resume`

**This is the most expensive thing in this document.** Always `reset run`.

Halting the CPU stops Zephyr's link-layer controller *and* its timers. No
supervision timeout can fire locally, so a connected peer times out at 420 ms
while the board notices nothing. On resume the board still believes the dead
connection is live: it does not advertise, refuses new centrals
(`CONFIG_BT_MAX_CONN=1`), and the LED stays solid. Only a reset recovers it.

Demonstrated deliberately: a 30-second halt with no flashing and no image change
left the board unreachable for over a minute; a reset restored connection in
115 ms.

This is why the symptom correlates with MCUboot without MCUboot being at fault —
SWD is what brought halting into the workflow. It also means **diagnostic reads
are the dangerous case**, because resuming feels less disruptive than resetting.

### Erase and write need separate OpenOCD sessions

Erasing leaves the core executing blank flash, which locks up on a double fault.
OpenOCD writes flash by running a helper routine in target RAM, which a locked-up
core cannot do:

```
Error: timeout waiting for algorithm, a target reset is recommended
Error: Failed to write to nrf5 flash
```

`reset halt` between the erase and the write fixes it. Same root cause as
`verify_image` failing: **any OpenOCD operation that runs code on the target
needs the core in a sane state.**

### Console capture must survive re-enumeration

The board suspends and re-enumerates its CDC ACM about 100 ms after boot. A held
file descriptor does **not** error — it goes quiet forever — so detecting the
loss needs an idle timeout, not an exception. Every capture that appeared to stop
at `advertising as Sophon-86F0` was this, not a board fault.

### Do not enable `CONFIG_PM_DEVICE_RUNTIME` to control one GPIO

From #268, but it bites here: runtime PM is a global policy. Enabling it changed
every device's lifecycle and stopped the LSM6DS3TR-C data-ready trigger firing,
while init still reported success. See [HARDWARE.md](HARDWARE.md).

## The transition

Both paths are supported until every board has migrated.

```bash
scripts/build.sh                      # UF2 — the current default
SOPHON_BOOT=mcuboot scripts/build.sh  # MCUboot via sysbuild
scripts/flash.sh                      # UF2 boards
scripts/flash-swd.sh                  # MCUboot boards
```

Separate build directories per mode (`build/`, `build-mcuboot/`) so both
artefacts coexist and neither reuses the other's CMake cache.

**Flip the default when the last board migrates** — that is the condition, not a
date.

### Guards, and which are proven

| Guard | Status |
|---|---|
| Invalid `SOPHON_BOOT` rejected | verified |
| `flash.sh` refuses a UF2 image older than sources | verified |
| `flash.sh` refuses when the MCUboot build is newer, and names `flash-swd.sh` | verified |
| `flash-swd.sh` refuses a board with a SoftDevice at `0x3004` | **not verified** — needs a UF2 board attached |

That last one is the important one and the one still untested: flashing MCUboot
onto `4D88` would destroy its bootloader *and* its SoftDevice, and there is no
backup of that board.

### Migrating a board

1. **Back up** full flash and UICR, and verify with `cmp` against a re-dump.
2. `SOPHON_BOOT=mcuboot scripts/build.sh`
3. `scripts/flash-swd.sh`
4. Confirm it boots, advertises and accepts a connection — a program counter in
   the application region is *not* evidence that a central can connect.

## Not established

- **Whether the backup is portable between boards.** The SoftDevice and
  bootloader are identical binaries, UICR holds the same values, and BLE identity
  comes from FICR rather than flash — so it probably is. Untested. Back up each
  board anyway.
- **Whether UF2 flashing works without the SoftDevice.** The restore test put
  everything back at once.
- **Whether iOS backs off reconnection after a long absence.** Suspected as a
  second factor in slow reconnects after a flash, never demonstrated.
- **Why the controller does not detect the dead link on resume.** It should time
  out within 420 ms on its next connection event and does not.
