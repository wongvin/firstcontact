# Migrating a board from UF2 to MCUboot without a probe

**Status: design, not built.** Nothing here has run on hardware. Figures are
marked as measured or derived throughout.

**#294 implements the design in this document and not the simpler alternative
below**, which needs a direct-XIP MCUboot and therefore a decision belonging to
#290.

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

### What the installer writes, and what it does not

It writes **two things**, neither of them large: MCUboot to `0x0`, and slot1's
trailer. It never writes slot0 — the 190 KB move into slot0 is done by MCUboot
itself on the next boot, using the same swap code every OTA uses. See *What
MCUboot does on its first boot* below.

That has a useful consequence. `slot0` is `0xC000–0x84000` and the installer at
`0x27000` sits **inside it** — but nothing the installer writes touches that
range, so it never overwrites itself and needs no `__ramfunc`. It is destroyed
later, by the swap, long after it has finished.

The application image is staged at `0x085000`, which is slot1 plus one sector —
the offset `CONFIG_BOOT_SWAP_USING_OFFSET` expects, explained below.

**Where it ends is not a fixed address.** The staged image is whatever that day's
`zephyr.signed.bin` happens to be — 190,516 B as this is written — so its upper
edge moves with every build, as does the top of the installer-plus-blob region
below it. Column B draws both as unlabelled edges for that reason; only
`0x027000`, `0x084000`, `0x085000` and `0x0EC000` are fixed. Nothing in the
design depends on where the image ends in any case: MCUboot finds the header at
`0x085000` and derives the trailer from the partition size, which is the point
argued at length under *Where the trailer actually lives*.

The end address is good for exactly one thing, and it is a check that does bind.
The staged image has to fit between `0x085000` and the top of the UF2
application window at `0x0EC000` — **421,888 B, or 412 KB**. That is less than
the 480 KB slot0 it is swapped into, so **this delivery route caps the image
below what the partition would hold**. Today's image uses under half of it, so
this is not a live constraint; it is a real one, and it is invisible from the
MCUboot layout alone. An image that fits slot0 comfortably could still be too
large to migrate this way.

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
         │                  │           │ ·· headroom ···· │           │                  │
         │                  │           ├──────────────────┤           │ slot1 "image-1"  │
         │                  │           │ staged app image │           │  (swapped out,   │
         │                  │           │  190 KB of 412   │           │   holds the old  │
         │ Application      │  0x085000 ├──────────────────┤           │   slot0 content) │
         │        788 KB    │  0x084000 ├──────────────────┤  0x084000 ├──────────────────┤
         │                  │           │ ·· unused ······ │           │ slot0 "image-0"  │
         │ Sophon @0x27000  │           ├──────────────────┤           │        480 KB    │
         │                  │           │ installer + blob │           │ signed Sophon    │
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

The staged image sits at `0x085000` rather than `0x084000` — slot1's base plus
one 4 KB sector — because that is where `CONFIG_BOOT_SWAP_USING_OFFSET` expects
to find it. Writing it to `0x084000` fails as "no bootable image" rather than as
anything that points at the cause.

The installer's own code at `0x27000` sits inside slot0 and is destroyed — but
not by anything the installer does. MCUboot's swap overwrites it on the next
boot, long after the installer has finished and reset.

**B is still layout A.** The board has not changed partitioning at that point —
the bootloader simply wrote an application and some data into the application
partition, which is the only thing it was ever asked to do.

### The bootloader never sees an address it could object to

Worth stating plainly, because it is the property that makes this design immune
to the bounds-check question above. **Every block in this UF2 targets the
application window** — `0x27000` for the installer and its MCUboot blob,
`0x085000` upward for the staged image, against a window of
`0x27000–0xEC000`.

Nothing in the file is addressed to `0x0`. To the bootloader, MCUboot is not a
bootloader at all; it is **payload bytes belonging to an application**, no
different from a lookup table. The installer supplies the destination later, at
runtime, long after the bootloader has handed over.

### Order is the whole safety argument

The full sequence, with the recovery position at each point:

| Step | Who does it | Time | Power loss here |
|---|---|---|---|
| 1. land installer at `0x27000` and the staged image at `0x085000` | UF2 bootloader | seconds | **recoverable** — nothing destroyed, re-copy the file |
| 2. erase `0xFB000–0xFC000` (slot1's trailer page), read it back | installer | one page | **bricked** if the erase took — this is where the window opens. A *blocked* erase changes nothing and is the one safe place to abort |
| 3. write MCUboot to `0x0` | installer | **~1.5 s** | **bricked**, SWD only |
| 4. write slot1's trailer: magic + `image_ok` | installer | µs | MCUboot is installed but finds nothing marked; it sits there. SWD only |
| 4b. erase storage `0xFC000–0x100000` *(optional)* | installer | ~0.4 s | same as 4 |
| 5. reset; MCUboot swaps slot1 into slot0 | MCUboot | ~20 s | **resumable** — an interrupted swap is restartable by design |

**The installer never copies 190 KB.** The application arrives through the UF2
bootloader's own proven path in step 1, and the one large move — step 5 — is
performed by MCUboot's swap code rather than by one-off installer code.

The unrecoverable window opens at step 2 and closes at step 4, and is dominated
by step 3's ~1.5 s. Step 2 leads deliberately: it is the only operation that can
tell the installer whether it is allowed to write the bootloader's region at all,
and a refusal there is harmless. *Is the installer allowed to erase it?* below
has the argument. Validating the MCUboot blob's hash before step 3 reduces what
remains to power loss alone, rather than power loss plus a corrupt payload.

### Where the numbers come from

Measured: MCUboot **40,176 B**, signed application **190,516 B**. Page erase
**89,700 µs**, which is Zephyr's own `FLASH_PAGE_ERASE_MAX_TIME_US` for this SoC.
The ~20 s swap is measured on `Sophon-86F0` during #271.

Derived: write time at the datasheet's 41 µs per 32-bit word. Step 3 is 12 page
erases plus 40 KB. Nothing is radio-synchronised because the installer runs no
BLE, so these are full-speed figures rather than the sliced ones an OTA sees.

## What MCUboot does on its first boot

The installer does **not** copy the application into slot0. It stages it in slot1
and sets the trailer, and MCUboot performs the move on its first boot using the
same swap code every OTA uses. That is the point: the 190 KB move is done by code
that is already proven, rather than by a one-off installer.

The obvious objection is that **slot0 holds no bootable image at that moment** —
it is whatever the old SoftDevice and application left behind. It turns out not
to matter, and the reason is in MCUboot's decision table.

### The primary slot does not participate in the decision

`boot_swap_tables[]` in `bootutil_public.c` decides the swap type purely from the
*secondary* slot's trailer. Every primary field is a wildcard:

```
magic_primary_slot     = BOOT_MAGIC_ANY      <- slot0's magic ignored
image_ok_primary_slot  = BOOT_FLAG_ANY       <- slot0's image_ok ignored
copy_done_primary_slot = BOOT_FLAG_ANY       <- slot0's copy_done ignored

magic_secondary_slot   = BOOT_MAGIC_GOOD     <- the only requirement
image_ok_secondary_slot = BOOT_FLAG_UNSET    -> BOOT_SWAP_TYPE_TEST
image_ok_secondary_slot = BOOT_FLAG_SET      -> BOOT_SWAP_TYPE_PERM
```

`boot_validated_swap_type()` then validates **only the secondary slot** before
upgrading. A blank, stale or corrupt primary is never consulted — which is the
same property that lets a normal OTA recover a board whose primary image was
damaged.

So a freshly-migrated board is not a special case to MCUboot. It is an ordinary
"secondary slot is marked, primary is irrelevant" boot.

### Which flag the installer should set, and why it is `PERM`

| `image_ok` in slot1 | swap type | what happens |
|---|---|---|
| **unset** | `TEST` | swaps in, then **reverts at the next reset** unless something confirms it |
| **set** | `PERM` | swaps in permanently, no revert |

**The installer sets `image_ok`, giving `PERM`.** `TEST` would be actively wrong
here: a revert means falling back to whatever is in slot0, and at this moment
slot0 holds the remains of a SoftDevice. There is nothing to revert *to*, so the
trial semantics that make rollback valuable during an OTA are a liability during
a migration.

This is also why the confirmation policy in `src/ble.c` does not apply to the
migration boot. It confirms an image that arrived **on trial**; an image that
arrived `PERM` is already confirmed, and `boot_is_img_confirmed()` short-circuits.

### The staging offset, which is easy to get silently wrong

`CONFIG_BOOT_SWAP_USING_OFFSET=y`, and under it a staged image does **not** begin
at slot1's base. `boot_get_state_secondary_offset()` returns one sector, so:

```
slot1 base            0x084000
staged image starts   0x085000      <- slot1 + one 4 KB sector
```

Writing the image to `0x084000` would leave MCUboot reading 4 KB into the wrong
place — a header mismatch, not a crash, so it fails as "no bootable image" rather
than as anything that points at the cause.

### The trailer is at the end of the SLOT, not the end of the image

Worth stating precisely, because the installer has to write it and the two
readings give different addresses. From `bootutil_misc.h`:

```c
boot_magic_off(fap)     = flash_area_get_size(fap) - BOOT_MAGIC_SZ
boot_image_ok_off(fap)  = ALIGN_DOWN(boot_magic_off(fap) - BOOT_MAX_ALIGN, BOOT_MAX_ALIGN)
boot_copy_done_off(fap) = boot_image_ok_off(fap) - BOOT_MAX_ALIGN
```

Every offset derives from `flash_area_get_size()` — the **partition's** size. The
image's length never appears. So for slot1 at `0x84000–0xFC000` the magic's 16
bytes end exactly at `0xFC000`, with `image_ok` and `copy_done` stepping down
above it, regardless of how large the staged image is.

Confirmed on hardware during #271: slot0's trailer was read at `0x83FC0`, the
last 64 bytes of the slot, while slot0's image ends near `0x35618` — nearly
300 KB of erased flash between the two.

Two things follow. The installer can compute the trailer address from the
partition alone, without knowing the payload size. And the trailer write cannot
corrupt the staged image, because they are nowhere near each other.

### The UF2 bootloader cannot write it

A flash write means erasing a 4 KB page, and the magic sits in the slot's final
16 bytes — so the page is **`0xFB000–0xFC000`**, which in layout A is inside the
Adafruit bootloader's own region at `0xF4000–0x100000`.

That is outside the application window, so the UF2 bootloader will not write it,
and it is the bootloader's own code besides. **The installer must write the
trailer**, and in doing so it destroys part of the bootloader it is replacing.

Not an incidental part of it. Read out of the `uf2-sdv7` backup, the bootloader's
vector table at `0xF4000` carries reset vector **`0x000FB2E1`** — its entry point
is at `0xFB2E0`, inside that page, and the page is 4063 of 4096 bytes of live
code. Erasing it does not damage the bootloader so much as decapitate it.

Whether the installer is *permitted* to erase it is a separate question, and the
answer decides whether this design works at all.

### Is the installer allowed to erase it?

Nothing stops a running application from erasing flash it does not occupy —
unless the region is hardware-protected. On the nRF52840 that mechanism is
**ACL**: eight configurable regions in the `NVMC` block starting at `0x4001E800`.
Two of its properties matter here. A write-protected region refuses erases as
well as writes, and **the configuration survives until reset** — so anything the
Adafruit bootloader locks before handing over stays locked underneath the
installer.

If it did lock itself, the installer could never write the trailer, and the
migration would fail at a step with no way back. So this was checked rather than
assumed.

**It does not lock itself.** Disassembled from the backup, the entire bootloader
region holds four references to the `0x4001E000` base, and every one is used at
offset `0x400` (`READY`), `0x504` (`CONFIG`) or `0x508` (`ERASEPAGE`) — ordinary
flash erase and write. Nothing reaches `0x800` or above, where `ACL[0]` begins,
and the SoftDevice region does not reference the base at all. The one candidate,
a pair of stores to offsets `0x800` and `0x804` at `0xF944C`, is addressed off
`0x40027000` — USBD, part of the nRF52840 USB errata workaround that also writes
`0x9375` to `0x4006EC00`.

That is consistent with observed behaviour: this bootloader can update itself,
which an ACL lock over its own region would prevent.

**Prove it at runtime anyway, by doing the erase first.** The above is reverse
engineering of a stripped binary, and being wrong about it costs a board. The
check and the work are the same operation — erase `0xFB000–0xFC000`, read it
back, continue only if it reads `0xFF`. A blocked erase changes nothing, so
aborting there leaves the board exactly as it was found.

The read-back only means something if it observes changed bits. ACL blocks a
write silently rather than faulting, so writing `0xFFFFFFFF` and reading
`0xFFFFFFFF` back would prove nothing; erasing a page that holds 4063 bytes of
code and seeing it come back empty is unambiguous.

**Leading with the erase costs nothing**, which is why it is ordered first:

- The unrecoverable window does not grow. It ran from the erase at `0x0` to the
  trailer write; it now runs from the trailer-page erase to the same trailer
  write. Either way it is two page-scale operations with MCUboot's ~1.5 s
  between them.
- Keeping the Adafruit bootloader intact past the MCUboot write buys nothing.
  It is entered by reset into the MBR at `0x0`, which forwards via
  `UICR.NRFFW[0]`. Once MCUboot owns `0x0`, reset runs MCUboot and the Adafruit
  bootloader is unreachable whether its bytes survive or not. **The recoverable
  period ends when `0x0` is first erased**, not when the bootloader is
  overwritten.

### What must be erased, and by whom

Neither region in question is reachable from the UF2 — both sit above `0xEC000`,
outside the application window — so this is installer work or nobody's.

**`0xFB000–0xFC000`, slot1's trailer page: erasing is mandatory.** The computed
addresses, from the offsets above against slot1 at `0x84000` size `0x78000`:

```
copy_done      0x0FBFE0
image_ok       0x0FBFE8
magic (16 B)   0x0FBFF0
slot1 ends     0x0FC000
```

All three fall in one 4 KB page. In layout A that page holds Adafruit bootloader
code, and **flash writes can only clear bits** — writing the magic over existing
code ANDs the two and yields neither. The page has to be erased first.

Erasing it also produces exactly the starting state the design wants: `image_ok`
and `copy_done` both read `0xFF` = `UNSET`. The installer then writes magic and
`image_ok`, giving magic `GOOD` / `image_ok` `SET` / `copy_done` `UNSET`, which is
the `PERM` row of the table above.

**`0xFC000–0x100000`, the storage partition: not required, and worth doing
anyway.** Nothing in the current build consumes it — no `SETTINGS`, no `NVS`, no
`ZMS`; only `CONFIG_FLASH_MAP`, which `img_mgmt` needs for the slots. So stale
Adafruit bootloader bytes sitting there harm nothing today.

They are a latent trap. The first time settings storage is enabled — bonding
keys were considered and declined in #274, so it is not hypothetical — it would
meet flash that is neither erased nor a valid structure. Erasing 4 pages while
the installer is already running costs ~0.4 s.

**The rest of slot1 does not need erasing.** MCUboot reads the header at the
staged offset and the trailer at the end; whatever lies between is ignored, and a
later OTA erases as it writes.

The full sequence, with recovery position at each point, is the table under
*Order is the whole safety argument* above.

## An alternative that is simpler, and not what #294 builds

There is a shorter version of all of this, and it is worth writing down because
it is better — just not available without a decision that belongs to another
issue.

**Place the app blob at `0x84000` itself, and let MCUboot run it where it lies.**

`0x84000` is not merely "above slot0" — it *is* `slot1`. A bootloader built with
`SB_CONFIG_MCUBOOT_MODE_DIRECT_XIP` "can boot from either partition and will
select one with higher application image version". So if the UF2 lands a
**slot1-linked** image there, the installed MCUboot finds it and executes it in
place. Nothing is copied anywhere.

What that removes:

| | Design above | Alternative |
|---|---|---|
| write MCUboot → `0x0` | ~1.5 s | ~1.5 s |
| write slot1 trailer | one page | **gone** — direct-XIP selects by version, not by trailer |
| MCUboot moves 190 KB into slot0 | ~20 s, once | **gone** — it runs where it lies |

**The margin is smaller than it first appears**, and it shrank while this
document was being written. The original design had the installer copying the
application itself, which the alternative removed entirely. Staging in slot1 and
letting MCUboot swap removes that too — so what the alternative now saves is a
trailer write and a **one-time ~20-second swap on first boot**.

Both designs share the properties that actually matter: the application arrives
through the UF2 bootloader's own proven path before anything irreversible
happens, the installer writes only ~40 KB plus a page, and neither needs
`__ramfunc` — Zephyr's `relocate_vector_table()` sets `SCB->VTOR` to the image's
own vector table (`CPU_CORTEX_M_HAS_VTOR=y` here), so an installer at `0x27000`
has already moved the interrupt vector off `0x0`. *Verified in source, not on
hardware.*

So the alternative buys 20 seconds, once, at the cost of a permanent bootloader
mode change. That is a much weaker trade than it looked before the swap-staging
idea, and it is worth recording that the weakening came from improving the main
design rather than from finding a flaw in the alternative.

### Why #294 does not build it

**It requires the installed MCUboot to be direct-XIP, permanently.** MCUboot's
mode is fixed in the binary at `0x0`, and nothing short of SWD replaces it. A
board migrated this way is direct-XIP for life.

That drags in the trade #271 already weighed and rejected: both direct-XIP modes
select `MCUBOOT_BOOTLOADER_NO_DOWNGRADE`, so the 2.4.0 → 2.3.0 revert
demonstrated there becomes impossible — going back means shipping a *higher*
version containing the old code. For a project whose OTA deliverable is "a bad
image reverts on its own", that trades the capability away.

It would also split the fleet: `Sophon-86F0` is swap-mode, migrated by probe; a
UF2-migrated board would be direct-XIP, while `build.sh` produces one kind of
image.

### The boundary worth recording, if it is ever adopted

Direct-XIP needs **no Sophon application source changes** — it is a bootloader
property plus a link address, and sysbuild generates the slot1 variant from the
same sources via `MCUBOOT_DIRECT_XIP_GENERATE_VARIANT`.

But the app image is **not** mode-agnostic. `CONFIG_MCUBOOT_BOOTLOADER_MODE_DIRECT_XIP`
is an app-side symbol, and `img_mgmt` compiles differently on it in eight places
across `img_mgmt.c` and `img_mgmt_state.c`, including the `state-write` path. It
also selects `MCUBOOT_BOOTLOADER_NO_DOWNGRADE`, which `img_mgmt` uses to reject
lower-version uploads.

So an app must be **built knowing which bootloader it will run under**. A
swap-mode image on a direct-XIP board reports swap semantics the bootloader will
not honour — marking images pending for a swap that never happens, and allowing
downgrades the bootloader will refuse. Silently wrong, in the way that is hardest
to notice.

**This alternative is the stronger design the day direct-XIP is adopted.** Until
then it is recorded, not built. See #290.

## What it leaves behind

**UICR is untouched.** `NRFFW[0]` still reads `0x000F4000`, pointing at the old
Adafruit bootloader region. Harmless — MCUboot runs from `0x0` and the MBR that
would read that pointer is gone — but it is a stale value that reads like a fact.
Exactly the state observed on `Sophon-86F0` after its probe-based migration.

**The Adafruit bootloader is destroyed in two stages.** Step 2 erases the single
page holding slot1's trailer, which falls inside the bootloader's
`0xF4000–0x100000` region and contains its reset vector's target; the swap in
step 5 then writes the old slot0 contents across the rest of slot1, including
what is left of it.

There is no going back to UF2 except by restoring a `uf2-sdv7` backup over SWD —
the same position a probe-migrated board is in.

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

The installer is a normal Zephyr application at `0x27000`, and the two pieces of
payload are handled differently because they differ by a factor of five.

**MCUboot's 40 KB is linked into the installer** as an ordinary `const` array.
Small enough that the linker does not care, it travels with the code that writes
it, and there is no second address to keep in step.

**The 190 KB application image is merged in as hex records at `0x085000`**, then
the merged hex is converted with `uf2conv.py`, which handles sparse input. The
result is one file carrying two disjoint regions — which is all a UF2 is.

Keeping the image out of the installer's own binary is not only about size: it is
the artefact most likely to change, and merging keeps it swappable without
rebuilding the installer. It is also the piece whose address is dictated by
MCUboot rather than chosen, so it is worth having it appear exactly once, in the
merge step, rather than buried in a linker script.

## Before any code

1. **Take a `uf2-sdv7` backup of the target board first.** It is the only route
   back once step 2 has taken, and `Sophon-4D88` does not have one (#270).
2. Rehearse on `Sophon-86F0`, which can be restored from either era — not on the
   board that has no backup.
3. Confirm the merged UF2 flashes and the installer *runs* before it is allowed
   to write anything. A build that reaches `main()` and prints its payload sizes
   proves the delivery half without risking the board.
