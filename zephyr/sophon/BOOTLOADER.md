# Bootloaders, flashing and recovery

What occupies flash, what starts the application, and how to put firmware on the
board without losing the ability to put firmware on the board.

Companion docs: each MCU's `HARDWARE.md` (below) is what the board *is*
(divider, charger, pin hazards); [PROTOCOL.md](PROTOCOL.md) is what it says on the air;
[README.md](README.md) is the day-to-day build and console.

**This file holds what is true on every MCU** (#373): the debugger, the backup
rules, MCUboot's configuration, the DFU transport, image signing, and the SWD
hazards. What occupies flash, the SWD pads, the backups of each board, the
consoles and how a board is migrated differ by MCU, and live beside it:

| MCU | Memory map, SWD, backups, consoles, migration | The board |
|---|---|---|
| nRF52840 | [hw/nrf52840/MEMORY-MAP.md](hw/nrf52840/MEMORY-MAP.md) | [hw/nrf52840/HARDWARE.md](hw/nrf52840/HARDWARE.md) |
| nRF54LM20A | [hw/nrf54lm20a/MEMORY-MAP.md](hw/nrf54lm20a/MEMORY-MAP.md) | [hw/nrf54lm20a/HARDWARE.md](hw/nrf54lm20a/HARDWARE.md) |

Established while implementing #253. Several sections record things that were
wrong on the first attempt — kept deliberately, because each produced a
plausible result rather than an error.

## SWD access

Test points, the OpenOCD invocation and the lock are per MCU:
[nRF52840](hw/nrf52840/MEMORY-MAP.md#swd-access) · [nRF54LM20A](hw/nrf54lm20a/MEMORY-MAP.md#swd-access).

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

## Backup and recovery

The backup is the artefact that makes everything else reversible. **Take one
before migrating any board.**

The dump commands, the backups of each board and how to restore them are per
MCU: [nRF52840](hw/nrf52840/MEMORY-MAP.md#backup-and-recovery) · [nRF54LM20A](hw/nrf54lm20a/MEMORY-MAP.md#backups).

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

Compare slot0 with the `.hex`, not the `.bin`. The build signs the two in
separate runs, and RSA signing is randomised, so they carry different but
equally valid signatures: the last 256 bytes of the image. A board flashed by
`flash-swd.sh` from the `.hex` therefore differs from the `.bin` in exactly
those bytes, which is expected, not corruption.

### Verify with `cmp`, not `verify_image`

`verify_image` loads a CRC routine into target RAM, times out on 1 MB, and leaves
the CPU in a HardFault. Re-dump and compare on the host instead — which
re-tests read repeatability for free.

The re-dump half also **needs no halt** (#275), so it is the one verification step
that can be run against a board that is up and serving a connection. That is the
other half of why this approach is preferred, not merely a workaround for
`verify_image` timing out.

## MCUboot on this board

Each MCU's partition table and why it is shaped that way:
[nRF52840](hw/nrf52840/MEMORY-MAP.md#mcuboot-on-this-board) · [nRF54LM20A](hw/nrf54lm20a/MEMORY-MAP.md#mcuboot-on-this-board).
What follows is the configuration every board shares.

### `sysbuild/mcuboot.conf`

MCUboot inherits the board's devicetree while being a minimal, single-threaded
build, and two nodes do not survive that. Both fail at **link** time, minutes
into a build, rather than at configure time — so neither is visible early.

**One needed redirecting, not removing.** The board's console is USB CDC ACM, so
`uart_console.c` links against a device MCUboot never instantiates:
`undefined reference to '__device_dts_ord_127'`. The first fix was
`CONFIG_CONSOLE=n` / `CONFIG_SERIAL=n`, which built and cost more than it saved —
see [The two consoles](hw/nrf52840/MEMORY-MAP.md#the-two-consoles). The console is now **on** and pointed
at `uart0` by `hw/nrf52840/mcuboot-console.overlay`.

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

### From the iPhone (#357)

The Sophon app runs the same cycle over the link it already holds, so nothing
has to be force-quit and the board need not come to the desk:

1. `scripts/airdrop-fw.sh` copies the latest MCUboot build to
   `build-mcuboot/sophon-<version>.sophonfw` and opens the AirDrop window. Pick
   the iPhone; it offers to open the file in Sophon, which keeps it (one image,
   the last received) after checking its header and SHA-256.
2. Any connected board advertising firmware older than the held image shows
   **Update to &lt;version&gt;** under Configuration, beside #346's warning when
   its Config frame is also older than the app reads. The comparison is the
   advertised major.minor, so an equal minor is never offered.
3. The app uploads with Nordic's iOSMcuManagerLibrary in **test-only** mode,
   resets the board, waits for the swap, and reads back slot 0: the new version,
   on trial, or the old one if it reverted.

A cancelled upload of the same image **resumes**: the board keeps the upload's
SHA-256 and offset in RAM and answers the next first chunk with how far it got
(`zephyr_img_mgmt.c`). A restart, or a different image, starts again at 0.

**The app never confirms.** The board keeps the image by its own rule, on its
first delivered frame or LoRa send, exactly as after `flash-ota.sh`. Before
uploading, the app refuses a board whose running image is still on trial, or
that has an update pending: in those states the library would confirm the
running image, or reset the board, on its own to free the spare slot.

nRF Connect Device Manager, built on the same library, refuses to upload below
an MTU of 73. That floor is in the library's `setMtu()`, which an MTU chosen by
hand goes through; the upload itself sends each packet at the board's
reassembly-buffer size (from MCUmgr parameters), split into writes of whatever
iOS negotiated, 20 bytes here. The app never sets an MTU.

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

Hazards of one MCU's flash or lock are in its own file:
[nRF52840](hw/nrf52840/MEMORY-MAP.md#hazards-all-confirmed-on-hardware) · [nRF54LM20A](hw/nrf54lm20a/MEMORY-MAP.md#hazards).

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

### Console capture must survive re-enumeration

The board suspends and re-enumerates its CDC ACM about 100 ms after boot. A held
file descriptor does **not** error — it goes quiet forever — so detecting the
loss needs an idle timeout, not an exception. Every capture that appeared to stop
at `advertising as Sophon-86F0` was this, not a board fault.

### Do not enable `CONFIG_PM_DEVICE_RUNTIME` to control one GPIO

From #268, but it bites here: runtime PM is a global policy. Enabling it changed
every device's lifecycle and stopped the LSM6DS3TR-C data-ready trigger firing,
while init still reported success. See [hw/nrf52840/HARDWARE.md](hw/nrf52840/HARDWARE.md).

## Building for each boot path

Migrating a board onto MCUboot is per MCU:
[nRF52840](hw/nrf52840/MEMORY-MAP.md#migrating-a-board) · [nRF54LM20A](hw/nrf54lm20a/MEMORY-MAP.md#migrating-a-board).

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

**MCUboot-only settings live in `mcuboot/app-mcuboot.conf`, not `prj.conf`.** That
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

## Not established

- **Whether iOS backs off reconnection after a long absence.** Suspected as a
  second factor in slow reconnects after a flash, never demonstrated.
- **Why the controller does not detect the dead link on resume.** It should time
  out within 420 ms on its next connection event and does not.
