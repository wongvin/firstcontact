#!/usr/bin/env python3
"""Build the migration UF2: installer at 0x27000, signed application at 0x085000.

    mkuf2.py --installer build/zephyr/zephyr.hex \
             --image ../sophon/build-mcuboot/sophon/zephyr/zephyr.signed.bin \
             -o sophon-migrate.uf2

WHY THIS EXISTS RATHER THAN uf2conv.py ALONE. uf2conv.py converts one input.
This file carries TWO disjoint regions -- which is all a UF2 is, a list of
(address, 256 bytes) blocks -- and merging two Intel-HEX files first means
reconciling their addressing records, since Zephyr's installer hex uses
extended-SEGMENT records (type 02) while objcopy emits extended-LINEAR ones
(type 04). Emitting the blocks directly skips that entirely.

It also puts the one size check that binds in the same place as the address it
checks against. See THE FIT CHECK below.

MCUboot is NOT here. It is linked into the installer as a const array; see
../CMakeLists.txt and UF2-MIGRATION.md, "Building the UF2".
"""

import argparse
import struct
import sys

UF2_MAGIC_START0 = 0x0A324655
UF2_MAGIC_START1 = 0x9E5D5157
UF2_MAGIC_END = 0x0AB16F30
UF2_FLAG_FAMILY_ID = 0x2000

# Read off a working Sophon UF2 rather than copied from a wiki: the Adafruit
# nRF52840 family. A wrong value here is rejected by the bootloader, which is
# the good failure -- it declines the file rather than writing it somewhere.
FAMILY_ID = 0xADA52840

PAYLOAD = 256

# From UF2-MIGRATION.md column C. Only the fixed addresses appear here.
STAGED_IMAGE = 0x085000
UF2_WINDOW_END = 0x0EC000
INSTALLER_BASE = 0x027000


def read_ihex(path):
    """Parse Intel-HEX into {addr: byte}. Data 00, EOF 01, base 02/04; skips 03/05."""
    mem, base = {}, 0
    with open(path) as f:
        for lineno, line in enumerate(f, 1):
            line = line.strip()
            if not line or not line.startswith(":"):
                continue
            raw = bytes.fromhex(line[1:])
            count, offset, rtype = raw[0], int.from_bytes(raw[1:3], "big"), raw[3]
            data = raw[4 : 4 + count]
            if (sum(raw) & 0xFF) != 0:
                sys.exit(f"{path}:{lineno}: bad checksum")
            if rtype == 0x00:
                for i, b in enumerate(data):
                    mem[base + offset + i] = b
            elif rtype == 0x01:
                break
            elif rtype == 0x02:
                base = int.from_bytes(data, "big") << 4
            elif rtype == 0x04:
                base = int.from_bytes(data, "big") << 16
            elif rtype in (0x03, 0x05):
                # Start Segment / Start Linear Address: the ELF entry point,
                # carried through by objcopy. Nothing to place in flash, and a
                # UF2 has nowhere to put it -- the reset vector at the image's
                # base is what the bootloader uses. Skip rather than reject.
                continue
            else:
                sys.exit(f"{path}:{lineno}: unsupported record type {rtype:#04x}")
    return mem


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--installer", required=True, help="installer zephyr.hex")
    ap.add_argument("--image", required=True, help="signed application .bin")
    ap.add_argument("-o", "--output", required=True)
    args = ap.parse_args()

    mem = read_ihex(args.installer)
    if not mem:
        sys.exit(f"error: {args.installer} contained no data records")

    lo, hi = min(mem), max(mem)
    if lo < INSTALLER_BASE:
        sys.exit(
            f"error: installer starts at {lo:#08x}, below the UF2 application\n"
            f"       window at {INSTALLER_BASE:#08x}. It was built for the wrong\n"
            f"       boot path -- build it WITHOUT the MCUboot overlays."
        )

    with open(args.image, "rb") as f:
        image = f.read()

    # --- THE FIT CHECK -------------------------------------------------------
    #
    # The staged image must fit between 0x085000 and the top of the UF2
    # application window. That ceiling is LOWER than the 480 KB slot0 the image
    # is eventually swapped into, so an image that fits the partition perfectly
    # well can still be undeliverable by this route. Invisible from the MCUboot
    # layout, which is where anyone would look -- hence checking it here, at the
    # only point that knows the file's true length.
    end = STAGED_IMAGE + len(image)
    usable = UF2_WINDOW_END - STAGED_IMAGE
    if end > UF2_WINDOW_END:
        sys.exit(
            f"error: signed image is {len(image):,} B and does not fit.\n"
            f"       staged at {STAGED_IMAGE:#08x}, it would end at {end:#08x},\n"
            f"       past the UF2 application window's {UF2_WINDOW_END:#08x}.\n"
            f"       This route allows {usable:,} B ({usable // 1024} KB), which is\n"
            f"       LESS than slot0's 480 KB. See UF2-MIGRATION.md."
        )

    if hi >= STAGED_IMAGE:
        sys.exit(
            f"error: installer occupies up to {hi:#08x}, overlapping the staged\n"
            f"       image at {STAGED_IMAGE:#08x}."
        )

    for i, b in enumerate(image):
        mem[STAGED_IMAGE + i] = b

    # --- emit ----------------------------------------------------------------
    chunks = []
    addrs = sorted(mem)
    i = 0
    while i < len(addrs):
        start = addrs[i]
        buf = bytearray()
        while i < len(addrs) and len(buf) < PAYLOAD and addrs[i] == start + len(buf):
            buf.append(mem[addrs[i]])
            i += 1
        chunks.append((start, bytes(buf)))

    with open(args.output, "wb") as f:
        for n, (addr, data) in enumerate(chunks):
            hdr = struct.pack(
                "<8I",
                UF2_MAGIC_START0,
                UF2_MAGIC_START1,
                UF2_FLAG_FAMILY_ID,
                addr,
                len(data),
                n,
                len(chunks),
                FAMILY_ID,
            )
            f.write(hdr + data.ljust(476, b"\x00") + struct.pack("<I", UF2_MAGIC_END))

    print(f"installer   {lo:#08x}-{hi:#08x}  {hi - lo + 1:,} B")
    print(f"image       {STAGED_IMAGE:#08x}-{end - 1:#08x}  {len(image):,} B")
    print(f"headroom    {UF2_WINDOW_END - end:,} B of {usable:,} B usable")
    print(f"wrote       {args.output}  {len(chunks)} blocks, {len(chunks) * 512:,} B")


if __name__ == "__main__":
    main()
