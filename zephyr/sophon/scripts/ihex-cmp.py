#!/usr/bin/env python3
"""Compare Intel-HEX images against a flat dump of the same flash.

Written for #277, where `flash-swd.sh` wrote two images over SWD and then said
`done -- board reset and running` without reading anything back. This is the
read-back half.

Usage:
    ihex-cmp.py <dump.bin> <dump-base-addr> <file.hex> [file.hex ...]
    ihex-cmp.py --extent <file.hex> [file.hex ...]

`--extent` prints one decimal number: the byte after the highest address any of
the files defines, rounded up to a 4 KB page. It exists so a caller can size a
read-back from the images themselves rather than hardcoding a region that then
goes stale when the partition table moves.

`dump.bin` is a flat image read from the target starting at `dump-base-addr`
(hex or decimal). Every byte a `.hex` file *defines* is compared against the same
address in the dump; addresses the hex leaves undefined are ignored, which is
what makes this work against a dump of a whole region when the image fills only
part of it.

Exit status is 0 only if every defined byte of every file matches.

WHY NOT `verify_image`. It loads a CRC routine into target RAM, times out on
1 MB, and leaves the CPU in a HardFault -- see ../BOOTLOADER.md. A host-side
comparison has no such failure mode, and re-dumping re-tests read repeatability
for free.

WHY NOT `objcopy -I ihex -O binary` + `cmp`. That flattens sparse records by
padding the gaps, so the padding value becomes part of the comparison and an
image that simply does not define a region reads as a mismatch against whatever
is actually there. Comparing only defined bytes avoids inventing an expectation.

A NOTE ON WHAT A MATCH PROVES. It proves the bytes reached flash. It does not
prove the image is the one you meant to write: the build embeds a generated
timestamp (see ../CMakeLists.txt), so rebuilding identical source produces a
different image every time. Compare against the artefacts that were *written*,
never against a fresh build.
"""

import sys


def load_ihex(path):
    """Return {absolute_address: byte} for every byte the file defines."""
    mem, base = {}, 0
    with open(path) as fh:
        for lineno, line in enumerate(fh, 1):
            line = line.strip()
            if not line:
                continue
            if not line.startswith(":"):
                raise ValueError(f"{path}:{lineno}: not an Intel-HEX record")
            raw = bytes.fromhex(line[1:])
            count, addr, rectype = raw[0], (raw[1] << 8) | raw[2], raw[3]
            data = raw[4 : 4 + count]
            if (sum(raw[:-1]) + raw[-1]) & 0xFF:
                raise ValueError(f"{path}:{lineno}: checksum mismatch")
            if rectype == 0x00:                      # data
                for i, value in enumerate(data):
                    mem[base + addr + i] = value
            elif rectype == 0x01:                    # end of file
                break
            elif rectype == 0x04:                    # extended linear address
                base = ((data[0] << 8) | data[1]) << 16
            elif rectype == 0x02:                    # extended segment address
                base = ((data[0] << 8) | data[1]) << 4
            # 0x03/0x05 are start-address records: no payload in flash.
    return mem


def runs(addresses):
    """Collapse a sorted address list into (first, last) contiguous spans."""
    out, start = [], None
    prev = None
    for a in addresses:
        if start is None:
            start = prev = a
        elif a == prev + 1:
            prev = a
        else:
            out.append((start, prev))
            start = prev = a
    if start is not None:
        out.append((start, prev))
    return out


def compare(dump, dump_base, path):
    mem = load_ihex(path)
    if not mem:
        print(f"  {path}\n     ERROR: defines no bytes")
        return False

    lo, hi = min(mem), max(mem)
    end = dump_base + len(dump)
    print(f"  {path}")
    print(f"     0x{lo:06X}-0x{hi:06X}   {len(mem):,} bytes defined")

    outside = [a for a in mem if not (dump_base <= a < end)]
    if outside:
        print(f"     ERROR: {len(outside):,} bytes fall outside the dump "
              f"(0x{dump_base:06X}-0x{end:06X})")
        return False

    bad = sorted(a for a, v in mem.items() if dump[a - dump_base] != v)
    if not bad:
        print("     MATCH")
        return True

    print(f"     MISMATCH: {len(bad):,} of {len(mem):,} bytes differ")
    for first, last in runs(bad)[:8]:
        got, want = dump[first - dump_base], mem[first]
        print(f"       0x{first:06X}-0x{last:06X}  {last - first + 1:>6} bytes"
              f"   flash=0x{got:02x} image=0x{want:02x}")
    if len(runs(bad)) > 8:
        print(f"       ... and {len(runs(bad)) - 8} more spans")
    return False


PAGE = 4096


def main():
    if len(sys.argv) > 2 and sys.argv[1] == "--extent":
        highest = 0
        for path in sys.argv[2:]:
            mem = load_ihex(path)
            if mem:
                highest = max(highest, max(mem) + 1)
        if not highest:
            sys.exit("error: no bytes defined by any file")
        print(-(-highest // PAGE) * PAGE)
        return 0

    if len(sys.argv) < 4:
        sys.exit(__doc__.split("Usage:")[1].split("\n\n")[0].strip())

    dump_path, base_arg, hex_paths = sys.argv[1], sys.argv[2], sys.argv[3:]
    dump_base = int(base_arg, 0)
    with open(dump_path, "rb") as fh:
        dump = fh.read()

    print(f"dump: {len(dump):,} bytes at 0x{dump_base:06X}-"
          f"0x{dump_base + len(dump):06X}")

    ok = True
    for path in hex_paths:
        ok &= compare(dump, dump_base, path)
    print("all images match" if ok else "VERIFICATION FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
