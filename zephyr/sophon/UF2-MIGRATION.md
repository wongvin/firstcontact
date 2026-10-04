# Migrating a board from UF2 to MCUboot without a probe

**Status: design, not built.** Nothing here has run on hardware. Figures are
marked as measured or derived throughout.

Companion to [BOOTLOADER.md](BOOTLOADER.md), which documents the two boot paths
and the probe-based migration that already works.

## The problem

Adopting MCUboot currently requires a CMSIS-DAP probe, four test pads on the back
of the board, and physical possession — `scripts/flash-swd.sh`, established in
#253. That is fine for a board on the desk. It does not scale to a board in a
case, at distance, or to several at once, and it is the reason #270 still lists
`Sophon-4D88` as un-migrated.

The question this document answers: **can a board migrate itself, from a UF2 file
copied onto a mounted volume?**

## Why the obvious version does not work

The tempting answer is a UF2 whose blocks simply target `0x0` for MCUboot and
`0xC000` for the application. The UF2 format carries a target address per block,
so nothing in the *format* forbids it.

The bootloader does, and the reason is architectural rather than a policy that
might be configured away.

**It is running on the thing you want to replace.** The MBR at `0x0` forwards
interrupts and provides the SoftDevice calls the bootloader uses. Erasing it
mid-transfer stops the USB stack performing the transfer — the board would lose
the connection it is being flashed over, partway through replacing its own
bootloader.

Adafruit's own self-update path exists and works, but through MBR commands
(`SD_MBR_COMMAND_COPY_BL` / `COPY_SD`) which replace the SoftDevice or the
bootloader. **They cannot replace the MBR**, because the MBR is the code doing the
copying.

Adafruit's handler is also understood to bounds-check each block against its
application window and silently drop anything outside, which would be a second
reason. It is a weaker one and worth stating precisely: **it is not what makes the
direct approach fail, and it has no bearing on the design below.** Even a
bootloader that cheerfully accepted a block addressed to `0x0` could not survive
erasing the page it depends on.

## The design: an installer that is just an application

The way around all of it is to stop fighting the bootloader. An **ordinary Zephyr
application**, delivered as a normal UF2 to the normal application address, is
something the bootloader accepts without complaint. Once it runs it owns the
chip and can write anywhere.

It carries MCUboot and the real application as embedded blobs, installs them, and
resets.

### The trap: self-overwrite

MCUboot's `slot0` is `0xC000–0x84000`. An application flashed at `0x27000` sits
**inside it**. Writing slot0 would destroy the installer mid-write, and destroy
the payload it is reading from.

Solved by putting the payload *above* slot0, where no write touches it:

Columns **A** and **C** are the stock and current layouts from
[BOOTLOADER.md](BOOTLOADER.md). **B** is what this design adds: the same board as
A, with the UF2's contents landed in the application partition. Not to a shared
scale; each column is internally proportional only.

```
        A: BEFORE (stock UF2)        B: WHAT THE UF2 LANDS        C: AFTER (MCUboot)
                                        (still layout A)             (what C produces)

0x100000 ┌──────────────────┐  0x100000 ┌──────────────────┐  0x100000 ┌──────────────────┐
         │ UF2 bootloader   │           │ UF2 bootloader   │           │ storage    16 KB │
         │ Adafruit   48 KB │           │ Adafruit   48 KB │  0x0FC000 ├──────────────────┤
0x0F4000 ├──────────────────┤  0x0F4000 ├──────────────────┤           │                  │
         │ Storage    32 KB │           │ Storage    32 KB │           │ slot1 "image-1"  │
0x0EC000 ├──────────────────┤  0x0EC000 ├──────────────────┤           │        480 KB    │
         │                  │  0x0BC834 │ ·· unused ······ │           │                  │
         │                  │           ├──────────────────┤           │ (payload lived   │
         │                  │           │ app blob  190 KB │           │  here; erased by │
         │                  │  0x08E000 ├──────────────────┤           │  step 3)         │
         │ Application      │           │ MCUboot blob 40KB│           │                  │
         │        788 KB    │  0x084000 ├──────────────────┤  0x084000 ├──────────────────┤
         │                  │           │ ·· unused ······ │           │ slot0 "image-0"  │
         │ Sophon @0x27000  │           ├──────────────────┤           │        480 KB    │
         │                  │           │ installer code   │           │ signed Sophon    │
0x027000 ├──────────────────┤  0x027000 ├──────────────────┤           │                  │
         │ SoftDevice S140  │           │ SoftDevice S140  │  0x00C000 ├──────────────────┤
         │ v7.3.0    152 KB │           │ v7.3.0    152 KB │           │ mcuboot    48 KB │
0x001000 ├──────────────────┤  0x001000 ├──────────────────┤           │                  │
         │ Nordic MBR  4 KB │           │ Nordic MBR  4 KB │           │                  │
0x000000 └──────────────────┘  0x000000 └──────────────────┘  0x000000 └──────────────────┘
```

**Read B against C at `0x084000`.** That address is the whole design. In C it is
the slot0 ceiling; in B it is where the payload begins. Everything the installer
writes happens *below* that line, so the blobs it is reading from are never in
the path of a write.

`0x084000` and not some round number above it: it is the **first address not in
slot0**, which is the only constraint there is. An earlier revision put the
payload at `0x088000`, leaving a 16 KB gap that defended against nothing — both
are page-aligned, both clear storage, and the payload ends 254 KB below slot1's
trailer either way. An arbitrary address in a memory map reads like it means
something, and this one did not.

The installer's own code at `0x27000` is not so lucky: it sits inside slot0 and
is destroyed by step 1. That is why the write routine runs from RAM.

**B is still layout A.** The board has not changed partitioning at that point —
the bootloader simply wrote an application and some data into the application
partition, which is the only thing it was ever asked to do.

### The bootloader never sees an address it could object to

Worth stating plainly, because it is the property that makes this design immune
to the bounds-check question above. **Every block in this UF2 targets the
application window** — `0x27000` for the installer, `0x84000–0xBC834` for the
payload, against a window of `0x27000–0xEC000`.

Nothing in the file is addressed to `0x0`. To the bootloader, MCUboot is not a
bootloader at all; it is **payload bytes belonging to an application**, no
different from a lookup table. The installer supplies the destination later, at
runtime, long after the bootloader has handed over.

An earlier revision of this document called the bounds-check the assumption the
whole approach rested on. That was wrong twice over: it does not apply here, and
it was never what killed the direct version either.

The installer's write routine runs from RAM (`__ramfunc`;
`ARCH_HAS_RAMFUNC_SUPPORT` is selected for ARM) with interrupts disabled, so it
survives erasing the flash it was linked into.

### Order is the whole safety argument

| Step | Flash time | If power is lost here |
|---|---|---|
| 1. erase `0xC000–0x84000`, write app | ~12.7 s | **recoverable** — MBR, SoftDevice and Adafruit bootloader are all still intact, so double-tap reset still mounts the volume |
| 2. erase `0x0–0xC000`, write MCUboot | **~1.5 s** | **bricked** — nothing at `0x0`, SWD only |
| 3. erase slot1, clearing the payload | ~10.8 s | harmless — MCUboot is installed and boots |

**Application first, MCUboot last.** Everything before step 2 leaves a board that
can still be rescued over USB; the unrecoverable window is about **1.5 seconds**.

Reversing the order would widen that window to the full ~25 seconds for no gain.

Validating the MCUboot blob's hash *before* step 2 reduces what remains to power
loss alone, rather than power loss plus a corrupt payload.

### Where the numbers come from

Measured: MCUboot **40,176 B**, signed application **190,516 B**. Page erase
**89,700 µs**, which is Zephyr's own `FLASH_PAGE_ERASE_MAX_TIME_US` for this SoC.

Derived: write time at the datasheet's 41 µs per 32-bit word. Step 1 is 120 page
erases plus 190 KB written; step 2 is 12 page erases plus 40 KB; step 3 is 120
page erases. Nothing is radio-synchronised because the installer runs no BLE, so
these are full-speed figures rather than the sliced ones an OTA sees.

## What it leaves behind

**UICR is untouched.** `NRFFW[0]` still reads `0x000F4000`, pointing at the old
Adafruit bootloader region. Harmless — MCUboot runs from `0x0` and the MBR that
would read that pointer is gone — but it is a stale value that reads like a fact.
Exactly the state observed on `Sophon-86F0` after its probe-based migration.

**The Adafruit bootloader is erased** by step 3, since `0xF4000` falls inside
slot1. There is no going back to UF2 except by restoring a `uf2-sdv7` backup over
SWD, which is the same position a probe-migrated board is in.

## Whether to build it

**Not for `Sophon-4D88`.** There is a probe, and `flash-swd.sh` is proven and
verifies its own writes.

It is worth building if the goal is *"MCUboot adoption is a firmware update, not a
site visit"* — a board in a case, at distance, or several at once. That is the
only way #270 scales past boards that can be physically held.

Weigh it honestly: this is a **bootloader installer whose failure mode is losing
the bootloader it is replacing**, written to avoid a procedure that already works.
It should be built deliberately or not at all.

## Building the UF2

The installer is a normal Zephyr application at `0x27000`. The payload is not
part of its image and should not be linked into it — forcing a 230 KB blob
through the linker at a fixed high address means fighting `FLASH_LOAD_SIZE` for
no benefit.

Simpler: build the installer, then **merge the blobs in as hex records** at
`0x84000` and `0x8E000`, and convert the merged hex to UF2. `uf2conv.py` handles
sparse input, so the result is one file carrying two disjoint regions — which is
all a UF2 is.

That also keeps the payload swappable without rebuilding the installer.

## Before any code

1. **Take a `uf2-sdv7` backup of the target board first.** It is the only route
   back from a failed step 2, and `Sophon-4D88` does not have one (#270).
2. Rehearse on `Sophon-86F0`, which can be restored from either era — not on the
   board that has no backup.
3. Confirm the merged UF2 flashes and the installer *runs* before it is allowed
   to write anything. A build that reaches `main()` and prints its payload sizes
   proves the delivery half without risking the board.
