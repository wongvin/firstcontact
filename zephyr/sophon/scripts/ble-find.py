#!/usr/bin/env python3
"""Resolve a Sophon board's BLE address for the tools that need one.

Usage:
    ble-find.py [name-substring] [--timeout SECONDS] [--verbose]

Prints one address on stdout and nothing else, so it can be captured:

    ADDR="$(ble-find.py)"

Exit status is 1 if nothing matched, 2 if more than one board did -- a caller
should not have to guess which board it just flashed.

WHY THIS EXISTS. `smpmgr --ble` documents its argument as "the Bluetooth address
to connect to", which on Linux is a MAC. **On macOS it is not.** CoreBluetooth
never exposes a peripheral's MAC; it hands out a UUID that identifies the device
*to this host only*:

    962CDEDA-816E-594C-042F-9A9211304CB5     what --ble wants here
    EC:C6:E9:14:26:2A                        the board's own BLE identity

Those are the same board. The UUID differs on another Mac, and is not stable
across a macOS reinstall, so it cannot be written into a config file or a script
-- it has to be discovered each time. Hence this.

WHAT IT MATCHES. The advertised local name, case-insensitively, defaulting to
"sophon". It deliberately does **not** filter on the MCUmgr SMP service UUID,
which would be the obvious thing: Sophon advertises only its own service
(`c6560001-...`), because the advertisement is full. The SMP service exists in
the GATT table and is found after connecting.

A BOARD THAT IS CONNECTED DOES NOT ADVERTISE. `CONFIG_BT_MAX_CONN=1`, so a board
serving the iOS app is invisible here and this exits 1 -- which reads as "no
board" and is really "board busy". The two are indistinguishable over the air;
see PROTOCOL.md.
"""

import asyncio
import sys

DEFAULT_NAME = "sophon"
DEFAULT_TIMEOUT = 8.0


async def find(substring, timeout, verbose):
    try:
        from bleak import BleakScanner
    except ImportError:
        sys.exit(
            "error: bleak is not available.\n"
            "       run via:  uv run --with bleak python ble-find.py"
        )

    found = {}
    for device, adv in (await BleakScanner.discover(timeout=timeout, return_adv=True)).values():
        name = adv.local_name or device.name or ""
        if substring in name.lower():
            found[device.address] = (name, adv.rssi)

    if verbose:
        for addr, (name, rssi) in found.items():
            print(f"  {name}  {addr}  rssi={rssi}", file=sys.stderr)

    if not found:
        print(
            f"error: no advertising device matching '{substring}'.\n"
            "       A CONNECTED board does not advertise -- if the iOS app holds it,\n"
            "       disconnect there first. Nothing on air distinguishes 'busy' from\n"
            "       'absent'.",
            file=sys.stderr,
        )
        return 1

    if len(found) > 1:
        print(f"error: {len(found)} boards match '{substring}':", file=sys.stderr)
        for addr, (name, rssi) in found.items():
            print(f"         {name}  {addr}  rssi={rssi}", file=sys.stderr)
        print("       narrow it with a longer substring, e.g. the 4-hex suffix.", file=sys.stderr)
        return 2

    print(next(iter(found)))
    return 0


def main():
    args = [a for a in sys.argv[1:]]
    verbose = "--verbose" in args
    args = [a for a in args if a != "--verbose"]

    timeout = DEFAULT_TIMEOUT
    if "--timeout" in args:
        i = args.index("--timeout")
        timeout = float(args[i + 1])
        del args[i : i + 2]

    substring = (args[0] if args else DEFAULT_NAME).lower()
    return asyncio.run(find(substring, timeout, verbose))


if __name__ == "__main__":
    sys.exit(main())
