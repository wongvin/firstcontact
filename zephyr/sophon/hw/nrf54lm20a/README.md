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

Sophon has no `boards/` file for this board yet; Phase 3 adds one. The two
workarounds #370 needed (the Bluetooth clock nodes, and the RRAM write buffer for
writes during a BLE link) were removed in #379, because Zephyr v4.5.0 fixes both
upstream.

## Before touching one

- **Never connect with Zephyr's board OpenOCD config, `west flash` or
  `west debug` to a board whose contents you want.** On a locked part they
  mass-erase it automatically. Read with `openocd-readonly.cfg` first
  (MEMORY-MAP.md § SWD access).
- **A blank board relocks at every power-on.** Erase and write in one session.
- **Zephyr v4.5.0 or later.** Older board files leave an image's last partial
  16-byte line unwritten under `west flash`, and RRAM writes time out during a
  BLE link (MEMORY-MAP.md § Hazards). A read-back is still the proof that a
  write landed.
- **One SWD session at a time while USB is connected.** The SAMD11 drives the
  same nets as the back pads `SWDIO` / `SWCLK` / `RST`.
