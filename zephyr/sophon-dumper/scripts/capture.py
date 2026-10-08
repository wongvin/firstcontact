#!/usr/bin/env python3
"""Capture a flash dump from a board running the #297 dumper, and verify it.

    uv run --with pyserial scripts/capture.py [--port /dev/cu.usbmodemXXX]

Writes the pair `~/.sophon/backups/<name>_<UTC>_<era>_{flash-1MB,uicr-4KB}.bin`,
in the shape BOOTLOADER.md already documents for SWD backups, so the two are
interchangeable at restore time.

WHY IT VERIFIES TWICE. Each data line carries a CRC32 of its own bytes, and each
region ends with a CRC32 over everything in it including the runs the board
skipped. The per-line check catches a corrupted line; the per-region check is
what catches a WRONG SKIP COUNT, which a per-line check cannot see because the
skipped bytes were never sent. A backup that cannot be verified is not a backup,
and this is the only integrity signal there is -- nothing can be re-read after
the board has been migrated.

The dumper repeats every 5 s, so this waits for the next BEGIN rather than
needing to be started first.
"""

import argparse
import binascii
import datetime
import glob
import pathlib
import sys

BACKUPS = pathlib.Path.home() / ".sophon" / "backups"


def pick_port():
    ports = sorted(glob.glob("/dev/cu.usbmodem*"))
    if not ports:
        sys.exit("error: no /dev/cu.usbmodem* found -- is the board attached?")
    return ports


def identify_era(flash):
    """Which era this image is, by content rather than by filename.

    The markers are BOOTLOADER.md's: a SoftDevice at 0x3004 means the board was
    still on the Adafruit bootloader, and the KEYHASH in slot0 says which key a
    migrated board trusts. Restoring the wrong era undoes something silently,
    which is why the era goes in the filename.
    """
    sd = int.from_bytes(flash[0x3004:0x3008], "little")
    if sd == 0x51B1E5DB:
        return "uf2-sdv7"
    known = {
        bytes.fromhex("2133b06f220b1c88dc8166327c3c5661f2b5f6f47f47f9371103679f710ed7e6"):
            "mcuboot-projectkey",
        bytes.fromhex("fc5701dc6135e1323847bdc40f04d2e5bee5833b23c29f93593d00018cfa9994"):
            "mcuboot-demokey",
    }
    for h, era in known.items():
        if h in flash[0xC000:0x84000]:
            return era
    return "mcuboot-unknown"


def lines(ser):
    """Yield text lines, reading in BLOCKS rather than per byte.

    pyserial's readline() reads one byte at a time through the OS, which cannot
    keep up with the dumper: the tty buffer overflows and whole lines vanish.
    That failure is silent in the data -- a dropped line looks like a jump in
    the offset field, which is why every line carries its offset and why this
    script checks it. Observed on the first run: the stream skipped from 0x480
    to 0xfc0, fifteen chunks gone with no error from the serial layer.
    """
    pending = b""
    while True:
        chunk = ser.read(max(1, ser.in_waiting))
        if not chunk:
            if pending:
                yield pending.decode("ascii", "replace").strip()
                pending = b""
            continue
        pending += chunk
        while b"\n" in pending:
            raw, pending = pending.split(b"\n", 1)
            yield raw.decode("ascii", "replace").strip()


class Desync(Exception):
    """The stream did not make sense. Wait for the next cycle and try again."""


def read_dump(ser):
    """Read one complete BEGIN..END, returning {region: bytes} and the name.

    THE DUMPER BROADCASTS ON A LOOP, so the first marker seen is usually the
    middle of a cycle, and the tty hands over whatever was buffered before the
    port was opened. Both show up as an offset that does not follow the last
    one. Rather than trust a partial dump, this raises and lets the caller wait
    for the next BEGIN -- the board will send another in a few seconds.
    """
    regions, dev_id = {}, None
    buf, base, size, chunk = None, 0, 0, 0
    region = None
    started = False

    for ln in lines(ser):

        if "SOPHON-DUMP v1 BEGIN" in ln:
            started, regions, dev_id = True, {}, None
            continue
        if not started:
            continue
        if "SOPHON-DUMP v1 END" in ln:
            return regions, dev_id

        f = ln.split()
        if not f:
            continue
        if f[0] == "id" and len(f) == 2:
            dev_id = f[1]
        elif f[0] == "b" and len(f) == 5:
            region, base, size, chunk = f[1], int(f[2], 16), int(f[3], 16), int(f[4])
            buf = bytearray()
            print(f"  {region}: {size:,} B from 0x{base:08x}", file=sys.stderr)
        elif f[0] == "d" and len(f) == 4 and buf is not None:
            off, data, want = int(f[1], 16), bytes.fromhex(f[2]), int(f[3], 16)
            if off != len(buf):
                raise Desync(f"{region} offset gap: line says {off:#x}, have {len(buf):#x}")
            got = binascii.crc32(data) & 0xFFFFFFFF
            if got != want:
                raise Desync(f"{region} chunk at {off:#x} failed CRC "
                             f"({got:08x} != {want:08x})")
            buf += data
        elif f[0] == "z" and len(f) == 3 and buf is not None:
            off, runs = int(f[1], 16), int(f[2])
            if off != len(buf):
                raise Desync(f"{region} offset gap at skip: {off:#x} != {len(buf):#x}")
            buf += b"\xff" * (runs * chunk)
        elif f[0] == "e" and len(f) == 3 and buf is not None:
            want = int(f[2], 16)
            if len(buf) != size:
                raise Desync(f"{region} is {len(buf):,} B, expected {size:,}")
            got = binascii.crc32(bytes(buf)) & 0xFFFFFFFF
            if got != want:
                raise Desync(f"{region} REGION CRC MISMATCH ({got:08x} != {want:08x}) -- "
                         "a wrong skip count looks exactly like this")
            print(f"  {region}: CRC32 {got:08x} OK", file=sys.stderr)
            regions[f[1]] = bytes(buf)
            buf = None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", help="serial port; default: try each /dev/cu.usbmodem*")
    ap.add_argument("--timeout", type=float, default=90.0)
    ap.add_argument("--out", default=str(BACKUPS))
    ap.add_argument("--raw", action="store_true",
                    help="write plain flash.bin/uicr.bin and skip the Sophon "
                         "naming and era detection entirely")
    args = ap.parse_args()

    try:
        import serial
    except ImportError:
        sys.exit("error: pyserial missing -- run via:\n"
                 "       uv run --with pyserial scripts/capture.py")

    ports = [args.port] if args.port else pick_port()
    for port in ports:
        print(f"==> listening on {port} (the dumper repeats every 5 s)", file=sys.stderr)
        try:
            ser = serial.Serial(port, 115200, timeout=0.2)
        except Exception as e:
            print(f"    cannot open: {e}", file=sys.stderr)
            continue
        with ser:
            ser.reset_input_buffer()
            regions, dev_id = None, None
            for attempt in range(1, 5):
                try:
                    regions, dev_id = read_dump(ser)
                    break
                except Desync as e:
                    print(f"    attempt {attempt}: {e}", file=sys.stderr)
                    print("    resyncing on the next cycle", file=sys.stderr)
        if regions:
            break
    else:
        sys.exit("error: no dump seen. Is the dumper UF2 actually running?")

    if "flash" not in regions or "uicr" not in regions:
        sys.exit(f"error: incomplete dump, got {sorted(regions)}")

    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    # --- EVERYTHING BELOW IS SOPHON-SPECIFIC ------------------------------
    #
    # The capture and verification above are generic: a device id, two regions,
    # CRCs. The naming convention, the era detection and ~/.sophon/backups are
    # this project's conventions and would have to be stripped before the tool
    # is published (#298). --raw skips the lot and is what a generic caller
    # wants: two binaries, named after the regions, in a directory you chose.
    if args.raw:
        for region in sorted(regions):
            path = out / f"{region}.bin"
            if path.exists():
                sys.exit(f"error: {path} exists; refusing to overwrite")
            path.write_bytes(regions[region])
            print(f"wrote {path}  ({len(regions[region]):,} B)")
        print(f"\ndevice id: {dev_id}")
        return

    era = identify_era(regions["flash"])
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    # Sophon names a board by the last two bytes of the device id; see
    # zephyr/sophon/src/ident.c, which does the same derivation on the board.
    name = f"Sophon-{dev_id[-4:].upper()}" if dev_id else "unknown"

    for region, suffix in (("flash", "flash-1MB"), ("uicr", "uicr-4KB")):
        path = out / f"{name}_{stamp}_{era}_{suffix}.bin"
        if path.exists():
            sys.exit(f"error: {path} exists; refusing to overwrite a backup")
        path.write_bytes(regions[region])
        print(f"wrote {path}  ({len(regions[region]):,} B)")

    print(f"\ndevice id: {dev_id}")
    print(f"era detected from contents: {era}")
    print("NOTE: the application region is the dumper, not the board's original "
          "firmware.\n      Everything else is intact. See src/main.c.")


if __name__ == "__main__":
    main()
