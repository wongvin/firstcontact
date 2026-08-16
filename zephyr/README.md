# zephyr/ — embedded firmware

Zephyr RTOS applications, built against the shared toolchain at `~/zephyrproject`
(see its README for the toolchain install).

| App | Board | What it does |
|---|---|---|
| [`sophon/`](sophon/) | Seeed XIAO nRF52840 Sense Plus (`xiao_ble/nrf52840/sense`) | BLE peripheral streaming IMU motion to the iOS app at [`ios/Sophon/`](../ios/Sophon/) |

## Quick start

```bash
zephyr/sophon/scripts/build.sh     # venv + ZEPHYR_BASE + west build
zephyr/sophon/scripts/flash.sh     # double-tap reset first
minicom -D /dev/cu.usbmodem* -b 115200   # cu, NOT tty — see CLAUDE.md
```

Conventions, gotchas, and the verification bar are in [CLAUDE.md](CLAUDE.md).
The two that bite first:

- **`west` cannot run from inside this repo** — use the wrapper scripts, which set
  `ZEPHYR_BASE`.
- **Don't add `CONFIG_USB_DEVICE_STACK=y`** for the USB console; the board already
  enables the new USB stack, and adding the legacy one breaks the link.
