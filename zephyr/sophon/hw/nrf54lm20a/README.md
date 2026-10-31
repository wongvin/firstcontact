# XIAO nRF54LM20A Sense

Sophon's second MCU, being ported in #368 (plan:
[NRF54LM20A-PLAN.md](../../NRF54LM20A-PLAN.md)). This directory holds
everything that would be wrong on the nRF52840; the rest of `zephyr/sophon/`
is shared (`zephyr/CLAUDE.md` § Shared vs per-MCU files).

| | |
|---|---|
| Board | Seeed XIAO nRF54LM20A Sense, KiCad V1.0 |
| Zephyr target | `xiao_nrf54lm20a/nrf54lm20a/cpuapp` |
| SoC | nRF54LM20A: Cortex-M33, 2036 KB RRAM, 512 KB RAM |
| Probe and console | onboard SAMD11 on the USB-C (CMSIS-DAP + `uart20` bridge); the nRF54 has no USB |
| Boot | MCUboot only; there is no UF2 path |
| Status | factory backup and lock findings (#369); MCUboot layout (#370); the app waits for Phases 2–3 |

## Files

| File | |
|---|---|
| [HARDWARE.md](HARDWARE.md) | the board: sources, identity, USB, the SAMD11, power rails, factory state |
| [MEMORY-MAP.md](MEMORY-MAP.md) | RRAM, the lock, SWD, backups, MCUboot's layout, console, hazards |
| [mcuboot-partitions.overlay](mcuboot-partitions.overlay) | MCUboot's partition table, applied to both images |
| [openocd-readonly.cfg](openocd-readonly.cfg) | OpenOCD that cannot erase or write: use it on any board whose contents matter |

Also per-board, in Zephyr's own place:
[../../boards/xiao_nrf54lm20a_nrf54lm20a_cpuapp.overlay](../../boards/xiao_nrf54lm20a_nrf54lm20a_cpuapp.overlay),
which enables the clock nodes Bluetooth needs (#375), and
[../../boards/xiao_nrf54lm20a_nrf54lm20a_cpuapp.conf](../../boards/xiao_nrf54lm20a_nrf54lm20a_cpuapp.conf),
which sizes the RRAM write buffer so writes complete while a BLE link is up
(#377).

## Before touching one

- **Never connect with Zephyr's board OpenOCD config, `west flash` or
  `west debug` to a board whose contents you want.** On a locked part they
  mass-erase it automatically. Read with `openocd-readonly.cfg` first
  (MEMORY-MAP.md § SWD access).
- **A blank board relocks at every power-on.** Erase and write in one session.
- **Read back after every flash.** `west flash` can leave an image's last
  partial 16-byte line unwritten, which MCUboot then rejects
  (MEMORY-MAP.md § Hazards, #377).
- **One SWD session at a time while USB is connected.** The SAMD11 drives the
  same nets as the back pads `SWDIO` / `SWCLK` / `RST`.
