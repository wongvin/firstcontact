# Sophon UF2 → MCUboot installer (#294)

Migrates a board from the Adafruit UF2 bootloader to MCUboot **without a
probe**, from a UF2 file copied onto the mounted volume.

The design, the memory maps and the whole safety argument are in
[`../sophon/UF2-MIGRATION.md`](../sophon/UF2-MIGRATION.md). This README covers
only how to build and what the current build does.

## Status: survey only — this build writes nothing

**`CONFIG_FLASH` is not enabled**, so the absence of writes is a property of the
binary rather than a promise in a comment. The driver arrives with the first
milestone that actually erases something.

This is the third item of *Before any code*: confirm the merged UF2 flashes and
the installer **runs** before it is allowed to touch flash. What it reports:

- where it is running, and that nothing it will write lands in slot0 — which is
  why there is no `__ramfunc`
- the embedded MCUboot blob's size
- the staged application at `0x085000`: header magic, version, body size
- the trailer offsets it would write, **derived from the partition size** rather
  than from the image length
- how much of the trailer page is live Adafruit bootloader code

## Build

```bash
SOPHON_BOOT=mcuboot ../sophon/scripts/build.sh   # produces both payloads
scripts/build.sh                                 # then this
```

Output is `build/sophon-migrate.uf2`, carrying **two disjoint regions**:

| Region | Contents | How it gets there |
|---|---|---|
| `0x027000` | this installer, **with MCUboot linked inside it** | normal Zephyr link |
| `0x085000` | the signed Sophon application | merged by `scripts/mkuf2.py` |

Both payloads come from the Sophon app's MCUboot build and neither is built
here. That coupling is deliberate: #274's signing key means the bootloader and
the image it validates must be the matched pair that build produced, so building
a second MCUboot here would invite the two to drift.

### Why `0x085000` and not `0x084000`

`0x084000` is slot1's base. `CONFIG_BOOT_SWAP_USING_OFFSET` expects the staged
image **one sector higher**, and an image at the slot base is one MCUboot will
never find. `src/main.c` asserts the relationship at compile time rather than
restating the constant.

### Why `mkuf2.py` rather than `uf2conv.py`

`uf2conv.py` converts one input. This file carries two disjoint regions, and
merging two Intel-HEX files first means reconciling their addressing records —
Zephyr's installer hex uses extended-*segment* records while `objcopy` emits
extended-*linear* ones. Emitting UF2 blocks directly skips that.

It also puts **the one size check that binds** in the only place that knows the
file's true length: the staged image must fit between `0x085000` and the top of
the UF2 application window at `0x0EC000`, which is **412 KB** — *less* than the
480 KB slot0 it is eventually swapped into. An image that fits the partition can
still be undeliverable by this route, and that is invisible from the MCUboot
layout where anyone would look.

## Before putting this on a board

1. **Take a `uf2-sdv7` backup of the target first.** It is the only route back
   once the migration has begun, and `Sophon-4D88` does not have one (#270).
2. **`Sophon-86F0` runs MCUboot today**, so it cannot accept this UF2 until it
   is restored to the UF2 era over SWD. Rehearse there, not on the board without
   a backup.
