# Sophon flash dumper (#297)

Reads a board's whole flash and UICR out over the USB console, **with no
probe**, so a backup can be taken before migrating it with
[`../sophon-installer/`](../sophon-installer/).

This closes the contradiction #294 left behind: a probe-free migration whose
first instruction was *"attach a probe"*.

## It writes nothing

`CONFIG_FLASH` is not enabled, so that is a property of the binary rather than a
promise in a comment. nRF52840 flash and UICR are memory mapped; a read is a
pointer dereference.

## Use

```bash
scripts/build.sh                       # -> build/zephyr/zephyr.uf2
# double-tap reset, copy that file onto the board's volume, then:
uv run --with pyserial scripts/capture.py
```

The dumper broadcasts on a 5-second loop, so `capture.py` can be started
whenever — it waits for a whole cycle.

| | |
|---|---|
| default | writes the pair into `~/.sophon/backups/`, named as BOOTLOADER.md documents |
| `--raw` | writes plain `flash.bin` and `uicr.bin`, no naming convention, no era detection |

## What it cannot save

The dumper is itself delivered as a UF2, so the bootloader writes it to
`0x27000` and **the original application there is gone** before a byte is read.
Everything else survives, which is the whole reason this works:

| Region | |
|---|---|
| MBR `0x0–0x1000` | below the dumper |
| SoftDevice `0x1000–0x27000` | below, ending just under it |
| application `0x27000–` | **clobbered** — and the one part rebuildable from this repo |
| storage, bootloader `0x0EC000–0x100000` | above |
| UICR | a different region entirely |

So the dump is a **recovery image, not a snapshot**. It restores a board to a
working bootloader with a broken application, which a UF2 copy then fixes.

## Preparation, not recovery

Restoring MBR, SoftDevice or bootloader means writing outside the UF2
application window, and is unreachable once the bootloader is gone — which is
the failure case. **SWD remains the restore path.** The gain is that the probe
is no longer needed to *take* the safety net, only to use it.

## Verification is the point

A backup that cannot be verified is not a backup, and nothing can be re-read
after a board has been migrated. So every line carries its offset and a CRC32 of
its own bytes, and every region ends with a CRC32 over **everything in it,
including the runs the board skipped as erased**. The per-line check catches a
corrupted line; the per-region check is what catches a wrong skip count, which
the per-line check cannot see because those bytes were never sent.

Validated against ground truth before being trusted: `Sophon-86F0` restored to
`uf2-sdv7` over SWD, dumped through this path, and compared — MBR, SoftDevice,
storage, bootloader and UICR all byte-identical, with differences confined to
the dumper's own footprint.

## Pacing is not optional

`printk` on CDC ACM goes through `uart_poll_out()`, which **discards** when its
ring is full rather than blocking. There is no flow control anywhere in that
path. Unpaced, this dropped fifteen consecutive chunks at the same offset on
every run, and the serial layer reported nothing.
