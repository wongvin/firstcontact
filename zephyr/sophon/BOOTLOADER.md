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
| Update path | UF2, or BLE OTA via the SoftDevice | dual-slot with rollback, **MCUmgr SMP over BLE** (#271) |

Every board now runs MCUboot. The UF2 path stays supported, for boards that
haven't been migrated yet:

| Board | Hardware | Path | Migrated |
|---|---|---|---|
| `Sophon-86F0` | XIAO nRF52840 Sense Plus | MCUboot | by SWD probe |
| `Sophon-4D88` | XIAO nRF52840 Sense Plus | MCUboot | by UF2, with no probe (#294, #297) |
| `Sophon-01A7` | plain XIAO nRF52840, from the Wio-SX1262 kit | MCUboot | by SWD probe, from factory Meshtastic (#301) |

`Sophon-01A7` has **no IMU**: it runs the Sense image, the LSM6DSL fails to
initialise, and it sends the zero-axis fallback frames. Its bootloader identified
itself as a Sense (`XIAO-SENSE`, `Seeed_XIAO_nRF52840_Sense`) all the same, so
the bootloader is no way to tell the two models apart. Look for the IMU.

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
        -c "adapter speed 4000" -f target/nrf52.cfg -c "<commands>; exit"
```

What goes in `<commands>` depends on whether the core has to stop (#275):

| | `<commands>` |
|---|---|
| **Reading** — `dump_image`, `read_memory` | `init; …` |
| **Writing or running code** — erase, `flash write_image`, `verify_image` | `init; reset halt; …; reset run` |

The template here used to be `init; halt; …; reset run` for everything, which is
correct but not free: it stops the core for a read that never needed it, and
stopping the core strands a connected BLE link until the reset.

A healthy connection reports `SWD DPIDR 0x2ba01477` and
`Cortex-M4 r0p1 processor detected`.

### There is a debugger, and it has never been used (#279)

Every OpenOCD invocation in this document prints:

```
Info : starting gdb server for nrf52.cpu on 3333
```

and the Zephyr SDK ships `arm-zephyr-eabi-gdb`. So source-level debugging has
been available throughout #253 and #277 and was not used once:

```bash
~/zephyr-sdk-1.0.1/gnu/arm-zephyr-eabi/bin/arm-zephyr-eabi-gdb \
    build-mcuboot/sophon/zephyr/zephyr.elf \
    -ex "target extended-remote :3333"
```

Worth stating because of what was done instead. Asked how long MCUboot took to
boot, the answer reached for was sampling the program counter by hand over SWD —
which halts the CPU, perturbs the measurement, and strands the BLE link. A
breakpoint through the GDB server halts the core too, so it carries the **same**
hazard and the same rule: finish with `reset run`, never a bare `resume`. What it
does buy is symbols, a backtrace and a source line instead of a bare address.

`arm-zephyr-eabi-addr2line` is the cheaper tool for the common case — turning a
fault address from the console into a file and line without touching the target
at all.

### APPROTECT

`UICR APPROTECT` reads `0xFFFFFFFF` and `CTRL-AP APPROTECTSTATUS` reads `1`:
debug access is open, no recovery needed. Note that erasing UICR *sets* APPROTECT
to `0xFFFFFFFF`, so a mass erase cannot lock you out.

## Backup and recovery

The backup is the artefact that makes everything else reversible. **Take one
before migrating any board.**

```bash
openocd ... -c "init;
   dump_image flash-1MB.bin 0x00000000 0x100000;
   dump_image uicr-4KB.bin  0x10001000 0x1000;
   exit"
```

**Or with no probe at all (#297):**

```bash
cd ../sophon-dumper && scripts/build.sh
# double-tap reset, copy build/zephyr/zephyr.uf2 onto the volume, then:
uv run --with pyserial scripts/capture.py
```

~20 s, writes the same pair here, CRC-checked per chunk and per region. It costs
the board's **application**, which the dumper overwrites and which this repo can
rebuild; MBR, SoftDevice, storage, bootloader and UICR all come through
byte-perfect, verified against this SWD path on `86F0` before being trusted on a
board with no backup. Preparation only — restoring still needs the probe.

**No `halt`, and therefore no `reset run` (#275).** Both used to be here and neither
is needed: `dump_image` reads through the debug access port without stopping the
core, so there is nothing to resume, and the `reset run` only existed to undo the
`halt`. Dropping the pair changes what this command *costs*, not just its length —
a backup is now safe to take from a board that is up and serving a connection,
where the old form would have stranded the BLE link for the duration and reset the
board at the end.

Measured taking the `Sophon-86F0` MCUboot-era backup: 1 MB of flash plus 4 KB of
UICR in **25 s**, no halt, the board left exactly as it was found.

Keep `reset run` where a `halt` really is required — erase, write, and anything
else that runs code on the target. The rule is in Hazards below.

Both halves matter. UICR holds `NRFFW[0]` (the bootloader address the MBR jumps
to) and `PSELRESET` (what makes the reset button work); a mass erase clears them,
and without the backup the board has no bootloader pointer and a dead K1.

Backups live in **`~/.sophon/backups/`** — outside the repo, because a 1 MB image
derived from a CC BY-SA design does not belong in a public repo with no LICENSE.
That also means they are unreplicated; losing them and the probe together would
leave a board with no bootloader and no known-good image.

`~/.sophon/` holds everything about this board that cannot be regenerated —
`backups/` and, from #274, `keys/` for the firmware signing key. One directory
because both carry the same consequence: lose the backup and a bricked board stays
bricked, lose the key and no image can ever be signed for the bootloader a board
already carries. Its own `README.md` explains the contents to someone who finds it
without this repo (#287).

**Decided (#270): backups stay in `~/.sophon/`, and Time Machine replicates
them.** `tmutil isexcluded` reports `~/.sophon`, `backups/` and `keys/` all
**included**, so no second copy is kept by hand. The catch is timing: a new
backup is replicated only after the next Time Machine run with the destination
disk attached. **After taking a backup, run Time Machine**, or the newest era of
a board exists in one place until then.

**There are three backups of `Sophon-86F0`, one per era, and restoring the wrong
one undoes something silently.** The era is in the filename for exactly this
reason, and after #274 the key matters as much as the layout:

| Backup | What restoring it gives you |
|---|---|
| `…_uf2-sdv7_…` | Adafruit UF2 bootloader + S140 — **the MCUboot migration undone** |
| `…_mcuboot-demokey_…` | MCUboot trusting the **public demo key** — boots, but anyone can sign for it |
| `…_mcuboot-projectkey_…` | current state: MCUboot trusting `2133b06f…` |

Each is identifiable from its contents, not just its name:

```
uf2-sdv7          @0x3004 = 0x51b1e5db (SoftDevice)   @0xC000 = not an image header
mcuboot-demokey   @0x3004 = 0xf3bf8811 (absent)       slot0 KEYHASH fc5701dc…
mcuboot-projectkey                                    slot0 KEYHASH 2133b06f…
```

**`Sophon-01A7` has two backups, one per era.** The first is the board as it
shipped, taken before anything was written (#301). It is the only copy of that
factory state: a UF2 dumper can't capture a factory application, because it
overwrites that region to run. The second was taken after the migration (#270).

| Backup | What restoring it gives you |
|---|---|
| `Sophon-01A7_20261010T033822Z_uf2-sdv7-meshtastic_flash-1MB.bin` + `_uicr-4KB.bin` | the factory board: UF2 bootloader 0.6.1, S140 7.3.0, Meshtastic |
| `…_CURRENT.UF2` (+ `INFO_UF2.TXT`, `INDEX.HTM`) | the Meshtastic application only, copied off the bootloader drive; reinstalls by UF2 once the bootloader is back |
| `Sophon-01A7_20261010T040327Z_mcuboot-projectkey_flash-1MB.bin` + `_uicr-4KB.bin` | current state: MCUboot trusting `2133b06f…`, slot0 holding 2.8.0+0 |

The MCUboot-era pair was checked against its contents, not just its name:
`0xf3bf8811` at `0x3004` (no SoftDevice), and a valid image header in slot0 that
matches the flashed `zephyr.signed.hex` byte for byte. **Its UICR is identical
to the factory pair's**, as with `86F0`'s two eras, which confirms again that
migrating doesn't touch UICR.

Compare slot0 with the `.hex`, not the `.bin`. The build signs the two in
separate runs, and RSA signing is randomised, so they carry different but
equally valid signatures: the last 256 bytes of the image. A board flashed by
`flash-swd.sh` from the `.hex` therefore differs from the `.bin` in exactly
those bytes, which is expected, not corruption.

The `uf2-sdv7` and `mcuboot-demokey` pairs are kept rather than deleted: both are
genuine recoveries from a brick, and the demo-key pair is the only route back if a
project-key bootloader is ever flashed with a key that has been lost.

Restoring the `uf2-sdv7` pair produces a board that boots — **on the Adafruit UF2
bootloader, with the migration undone**. A genuine recovery from a brick, and not
a way back to a working MCUboot board. It differs from the MCUboot pairs in
**371,718 bytes, 35.4% of flash**.

### The backup *is* portable between boards (#297)

Measured 2026-10-08, `Sophon-86F0`'s SWD backup against `Sophon-4D88`'s UF2 dump:

| Region | |
|---|---|
| MBR | **identical** |
| SoftDevice | **identical** |
| application | differs — see below |
| storage | **identical** |
| UF2 bootloader | **identical** |
| UICR | **identical** |

**Every region that matters for recovery is byte-identical between two different
boards.** Nothing per-device lives in flash or UICR; board identity comes from
FICR, which is neither backed up nor writable — which is also why a board
restored from a sibling's image keeps its own name. Both carry the same
bootloader build, `0.9.2-29-g6a9a6a3` with S140 7.3.0.

**The application difference tells you nothing.** `86F0`'s backup holds its
September firmware and `4D88`'s dump holds the dumper that overwrote its
application, so they differ by construction. Whether two boards running the
*same* image would match there is still unmeasured, and does not matter: the
application is the one part this repo can regenerate.

So one board's backup is a usable recovery image for another. **Take each
board's own anyway** — it costs 20 seconds through the probe-free path and a
sibling's image silently substitutes that board's firmware for this one's.

**The one exception, by decision (#270): `Sophon-4D88` has no MCUboot-era
backup.** That 20-second probe-free path only exists while a board still has
its UF2 bootloader; `sophon-dumper` is a UF2 application, and 4D88 now runs
MCUboot. 4D88 has no probe attached, so its MCUboot-era recovery image is a
sibling's `mcuboot-projectkey` pair: `86F0`'s, or `01A7`'s, which is newer and
holds 2.8.0. Restoring either gives 4D88 the same MCUboot and the same key,
with that sibling's application. 4D88 keeps its own name, because identity
comes from FICR. An OTA then puts the current application back.

**The UICR halves are byte-identical across both eras** — the migration never
touched UICR. `NRFFW[0]` still reads `0x000F4000`, pointing at a region that is now
blank; harmless, because MCUboot runs from `0x0` and the MBR that would read that
pointer was overwritten, but it is a stale value that reads like a fact. That also
halves #270's open question about whether a backup is portable between boards:
only the flash image is in doubt.

### Verify with `cmp`, not `verify_image`

`verify_image` loads a CRC routine into target RAM, times out on 1 MB, and leaves
the CPU in a HardFault. Re-dump and compare on the host instead — which
re-tests read repeatability for free.

The re-dump half also **needs no halt** (#275), so it is the one verification step
that can be run against a board that is up and serving a connection. That is the
other half of why this approach is preferred, not merely a workaround for
`verify_image` timing out.

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

### The DFU transport (#271)

An earlier revision of this section said Sophon had **no** DFU transport, and
that the second slot therefore cost ~450 KB for a mechanism nothing could reach.
That is no longer true: `CONFIG_MCUMGR_TRANSPORT_BT` with `img_mgmt` and
`os_mgmt` makes slot1 fillable over the air, and `scripts/flash-ota.sh` wraps the
cycle.

Measured on `Sophon-86F0`: **190 KB uploaded in ~55 s** at the default 23-byte
ATT MTU, swap on reset in **~20 s**, and ~2 minutes for the whole scripted run.

Three things about it that are not obvious:

- **Reassembly is a precondition, not a tuning knob.** At a 23-byte MTU an ATT
  write carries 20 bytes and the 8-byte SMP header leaves 12 for the entire CBOR
  body — an upload request carrying `off`, `len`, a 32-byte `sha` and `data`
  cannot be encoded at all. `MCUMGR_GRP_OS_MCUMGR_PARAMS` is its other half: it
  is how the client learns it may write a packet larger than the MTU.
- **`SOC_FLASH_NRF_PARTIAL_ERASE` is what keeps the link alive.** A page erase
  blocks for 89,700 µs — 21% of the 420 ms supervision timeout — on each of ~46
  pages. Sliced at 3 ms it fits between connection events. The upload completing
  at all is that setting working.
- **One connection, and several commands.** `CONFIG_BT_MAX_CONN=1` while
  `flash-ota.sh` connects separately to scan, upload, mark, reset and verify. A
  backgrounded iOS app reclaims the board in the gap after the upload and the run
  fails partway. Force-quit it, do not merely disconnect.

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

### Device nodes renumber, and which node is which can swap

`/dev/cu.usbmodem<n>` is assigned at enumeration, so **it changes across a
reflash** — and not only the digits. Observed across one `flash-swd.sh` run: the
board moved `101 → 1101` while the probe moved `1102 → 102`, so a capture pinned
to the old board node was reading the *probe* and returned nothing at all.

A capture that fails this way is silent, not noisy: an empty log reads exactly
like a board that did not boot. Resolve the node fresh each time rather than
reusing one from a previous run, and identify the board by its USB product string
rather than by number:

```bash
ioreg -p IOUSB -l -w 0 | grep '"USB Product Name"'
#   "CDC ACM serial backend"   <- the board (Zephyr)
#   "Debug Probe _CMSIS_DAP_"  <- the probe (Raspberry Pi)
```

`tio` handles the re-enumeration *within* a session, which is why it is in the
Brewfile — but it cannot help if the node it was given has become a different
device.

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

## Image signing

MCUboot validates every image on boot against a public key **compiled into the
bootloader** (`autogen-pubkey.c`, generated by `imgtool getpub`), while `imgtool`
signs the application with the private half of the **same file**. One path, two
consumers — which is why the two images can never be flashed independently once
the key changes.

The key is resolved by `build.sh`, not hardcoded in committed config:

```
$SOPHON_SIGNING_KEY            if set -- an absolute path, for CI or another host
~/.sophon/keys/sophon-fw-rsa-2048.pem   otherwise
```

### Which key signed an image

The `KEYHASH` TLV is **SHA-256 of the DER PKCS#1 `RSAPublicKey`** — *not*
`SubjectPublicKeyInfo`, which is what most tooling emits by default and the first
thing tried here. Established by comparing both candidates against a real image:

```bash
openssl rsa -in <key>.pem -RSAPublicKey_out -outform DER | shasum -a 256
```

| Key | `KEYHASH` |
|---|---|
| project — `sophon-fw-rsa-2048.pem` | `2133b06f…710ed7e6` |
| MCUboot demo — **public, do not trust** | `fc5701dc…8cfa9994` |

Read the TLV out of a `.signed.bin`, or out of a region dumped off a board, and
compare. `build.sh` does this on every MCUboot build and warns if the key in use is
the demo one — **by fingerprint, not filename**, because a filename is a label
anyone can change.

### Changing the key means reflashing both images together

A new-key bootloader over an old-key application fails `BOOT_VALIDATE_SLOT0` and
the board stops booting. `flash-swd.sh` writes both in one session, which is why it
is the path for this.

`SB_CONFIG_BOOT_SIGNATURE_KEY_FILE` also accepts a comma-separated list where later
entries are verification-only, so a bootloader can trust two keys during a
transition. Not used here — with two boards the atomic reflash is simpler — but
recorded because it is not obvious the option exists.

### What rejection looks like

Demonstrated: a demo-key-signed application written into `slot0` under a
project-key bootloader. **The board's USB CDC ACM device stops enumerating
entirely**, because that device only exists while the Zephyr application runs. Two
`/dev/cu.usbmodem*` nodes become one — the probe's.

That absence is the signal, and it is easy to misread as a dead board. Confirmed
causal by restoring the project-signed image and watching the node return.

**The stronger evidence was not available**: MCUboot's own `uart0` console would
say why it refused, but that needs the probe's 3-pin UART connector attached, and
it was not. The proof here is the application never running plus the `KEYHASH` read
out of `slot0` — which together say *which* key was rejected, where a board simply
failing to boot would not.

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
SWD is what brought halting into the workflow.

#### It is the halt, not SWD access (#275)

An earlier revision of this section went one step further and said *diagnostic
reads are the dangerous case*. That was generalised from the operation which
produced the finding — sampling the program counter, which does require a halt —
and it is wrong about reads.

Measured against `Sophon-86F0` while it was connected to the iOS app and streaming
at ~54 Hz: a `dump_image` of `0x000000-0x084000`, **540,672 bytes in 13 seconds**,
with no `halted` in the OpenOCD output, no `reset run` afterwards, and the BLE link
still streaming throughout. `flash-swd.sh` already depends on this for its
SoftDevice probe at `0x3004`, which reads a word before any write.

| Operation | Halts the core? |
|---|---|
| `read_memory`, `dump_image` | **no** — safe against a live, connected board |
| `halt` — PC sampling, register inspection | **yes** — this is the hazard above |
| `flash erase_address`, `flash write_image`, `verify_image` | **yes** — they run code on the target |

The distinction is worth having precisely because the tempting moment is when you
want to know what a board is doing *without* disturbing it. Reading flash is that
tool, and it costs nothing.

### Never end an OpenOCD session between an erase and its write

Erasing and then writing in what *looks* like the natural way fails:

```
Error: timeout waiting for algorithm, a target reset is recommended
Error: Failed to write to nrf5 flash
```

OpenOCD writes flash by running a helper routine in target RAM, and a locked-up
core cannot run it. Same root cause as `verify_image` failing: **any OpenOCD
operation that runs code on the target needs the core in a sane state.**

**What locks the core up is the session ending, not the erase (#277).** OpenOCD
releases the core when it exits; a core released into blank flash double-faults,
and the next session finds it wedged. An earlier revision of this section drew the
wrong rule from that — *erase and write need separate sessions* — and the fix it
prescribed, `reset halt` between two invocations, worked by re-establishing a sane
core rather than by separating the operations.

Keep the core halted for one session and the situation never arises. Measured on
`Sophon-86F0`:

```
init; reset halt;
flash erase_address 0x00000000 0x000FC000;
flash write_image <mcuboot.hex>; flash write_image <app.signed.hex>;
reset run; exit
```

**27 s**, no timeout, both images verified on read-back, `slot1` confirmed blank
afterwards. This is what `flash-swd.sh` now does, and it is the same shape the
restore procedure above always used — which was the clue that the two-session rule
was not load-bearing.

**Erase the whole region, not only what you write.** `flash write_image erase`
also works in one session, and is 10 s rather than 27, but it erases only the
sectors it writes — so `slot1` keeps whatever was there. A stale image left in
`slot1` with a valid trailer is swapped in at the next boot, quietly replacing
what was just flashed. That has not bitten yet only because nothing has written
`slot1`; it becomes live with #271.

### Console capture must survive re-enumeration

The board suspends and re-enumerates its CDC ACM about 100 ms after boot. A held
file descriptor does **not** error — it goes quiet forever — so detecting the
loss needs an idle timeout, not an exception. Every capture that appeared to stop
at `advertising as Sophon-86F0` was this, not a board fault.

### Do not enable `CONFIG_PM_DEVICE_RUNTIME` to control one GPIO

From #268, but it bites here: runtime PM is a global policy. Enabling it changed
every device's lifecycle and stopped the LSM6DS3TR-C data-ready trigger firing,
while init still reported success. See [HARDWARE.md](HARDWARE.md).

## Building for each boot path

**MCUboot is the default** (#270). The default changed when the last board
migrated, which was the condition this section used to state.

```bash
scripts/build.sh                      # MCUboot via sysbuild (default)
SOPHON_BOOT=uf2 scripts/build.sh      # UF2, only for a board not yet migrated
scripts/flash-swd.sh                  # MCUboot boards, bootloader + app, by probe
scripts/flash-ota.sh                  # MCUboot boards, app only, over the air
scripts/flash-uf2.sh                  # UF2 boards
```

Separate build directories per mode (`build/`, `build-mcuboot/`) so both
artefacts coexist and neither reuses the other's CMake cache.

**MCUboot-only settings live in `swd/app-mcuboot.conf`, not `prj.conf`.** That
file holds MCUmgr/SMP, the image manager and the flash write path, and
`build.sh` adds it to MCUboot builds only. The image manager needs a
`slot0_partition`, which only the MCUboot partition overlay defines. From #271
until #306 those settings sat in `prj.conf`, and **every UF2 build failed to
compile**. Nobody noticed, because every board had migrated. Anything that only
makes sense under MCUboot goes in that file. **Build both modes before calling a
change verified** (§ Guards).

### What an MCUboot build produces

Sysbuild writes one directory per image. Anyone flashing by hand needs exactly
these:

| File | What it is | Used by |
|---|---|---|
| `build-mcuboot/mcuboot/zephyr/zephyr.hex` | MCUboot, linked at `0x0` | `flash-swd.sh` |
| `build-mcuboot/sophon/zephyr/zephyr.signed.hex` | the application, signed, linked at slot0 `0xC000` | `flash-swd.sh` |
| `build-mcuboot/sophon/zephyr/zephyr.signed.bin` | the same application as a raw image, for upload | `flash-ota.sh`, `sophon-installer` |
| `build-mcuboot/mcuboot/zephyr/zephyr.bin` | MCUboot as a raw image | `sophon-installer` |

The `.hex` and `.bin` of the application differ in their last 256 bytes. That's
the signature: they are signed in separate runs, and RSA signing is randomised.
Compare a board's slot0 with the `.hex` it was flashed from (§ Backup and
recovery, `Sophon-01A7`).

**Don't use `build-mcuboot/sophon/zephyr/zephyr.uf2`.** Sysbuild emits it, but
it is linked for slot0 at `0xC000`. Copied onto a board that still has the UF2
bootloader, that address is inside the SoftDevice. `flash-uf2.sh` never picks it up.

### Guards, and which are proven

| Guard | Status |
|---|---|
| Invalid `SOPHON_BOOT` rejected | verified |
| `flash-uf2.sh` refuses a UF2 image older than sources | verified |
| `flash-uf2.sh` refuses when the MCUboot build is newer, and names `flash-swd.sh` | verified |
| `flash-swd.sh` refuses a stale build (#277) | verified — caught a **true positive** on first use: `sysbuild/mcuboot.conf` had been edited 13 minutes after the build |
| `flash-swd.sh` reads both images back and compares before reporting success (#277) | verified — full run 33 s, both `MATCH` |
| `flash-swd.sh` catches an OpenOCD failure that prints no error text (#277) | verified against a stub; the previous `grep … && exit 1` did not |
| Both boot paths compile (#306): `scripts/build.sh` and `SOPHON_BOOT=uf2 scripts/build.sh` | verified, and part of `zephyr/CLAUDE.md`'s verification step, because the UF2 build broke silently from #271 to #306 |
| `flash-swd.sh` refuses a board with a SoftDevice at `0x3004` | verified (#301) on an untouched `Sophon-01A7`: it read `0x51b1e5db`, refused and exited 1, and a dump taken straight afterwards matched the backup byte for byte, so nothing was written |
| `flash-swd.sh` refuses when the SoftDevice magic can't be read (#301) | verified against a stub, with the erase replaced by a sentinel. The pre-fix script really did reach the erase. |

The SoftDevice guard is the important one: flashing MCUboot onto a UF2 board
destroys its bootloader *and* its SoftDevice. It was the last one left unverified,
and it was tested on a board whose factory image had already been backed up
over SWD.

### Migrating a board

**There are two ways, and the probe-based one is the default.**

#### By probe

1. **Back up** full flash and UICR, and verify with `cmp` against a re-dump.
2. `SOPHON_BOOT=mcuboot scripts/build.sh`
3. `scripts/flash-swd.sh`
4. Confirm it boots, advertises and accepts a connection — a program counter in
   the application region is *not* evidence that a central can connect.

#### By UF2, with no probe (#294)

A board can migrate **itself** from a file copied onto its mounted volume.
`Sophon-86F0` did on 2026-10-06, unattended.

```bash
SOPHON_BOOT=mcuboot scripts/build.sh          # both payloads
../sophon-installer/scripts/build.sh          # -> build/sophon-migrate.uf2
# double-tap reset, then copy the file onto /Volumes/XIAO-SENSE
```

The UF2 carries two disjoint regions: an installer at `0x27000` with MCUboot
linked inside it, and the signed application staged at `0x085000`. The installer
writes three small things — MCUboot to `0x0`, slot1's trailer, and a stub that
makes slot0 readable — then resets, and **MCUboot performs the 190 KB move**
with the same swap code every OTA uses. About 45 s end to end.

Design, and the pitfalls that shaped it, in
[UF2-MIGRATION.md](UF2-MIGRATION.md). Three things to know before using it:

- **It is a bootloader installer whose failure mode is losing the bootloader it
  is replacing.** The unrecoverable window is roughly 2 s, and the only way back
  from it is this chapter's SWD restore.
- **It still needs a backup first, and taking one needs the probe** — the
  contradiction #297 exists to remove.
- **An interrupted swap is untested.** The slot0 stub is deliberately not a true
  image, so an interruption leaves a header describing something that is not
  there. MCUboot restarts an interrupted swap by design; that path has not been
  exercised here.

Prefer the probe for a board already on the desk. This earns its place on boards
that cannot be held — which is the part of #270 that does not scale.

## Not established

- **Whether UF2 flashing works without the SoftDevice.** The restore test put
  everything back at once.
- **Whether iOS backs off reconnection after a long absence.** Suspected as a
  second factor in slow reconnects after a flash, never demonstrated.
- **Why the controller does not detect the dead link on resume.** It should time
  out within 420 ms on its next connection event and does not.
