# sophon: configure role and LoRa parameters from the app

Plan saved on 2026-10-17 and not yet approved for implementation; tracked as #329. The design record for setting a board's role and LoRa parameters from the app.

## Context

Today a board's role and its LoRa parameters are fixed when it is built or when it boots:
- **Role** is auto-detected at boot (`src/role.c:143-174`):
  - no radio → direct;
  - radio and an IMU → sensor;
  - radio, no IMU → gateway.
- **LoRa parameters** are Kconfig constants: `SOPHON_LORA_PRESET` (V6), `SOPHON_LORA_FREQ_HZ`, `SOPHON_LORA_PEER_ID` (`Kconfig:6-26`).

The field tests (FIELD-TEST.md) need the **same hardware in different roles**. The unit in the vehicle (a Sense Plus + Wio-SX1262) is the **transmitter** in scenario 1 and the **receiver** in scenario 2. The unit carried on foot or kept in the building (a base XIAO + Wio) does the opposite. Today that means swapping boards or reflashing.

**Goal:** the Sophon app configures a connected board, the board stores the setting, and it takes effect on the next reboot. Two use cases:
1. **Role override:** Auto (default), direct, sensor or gateway, so a unit can play either end, within what its hardware can do.
2. **LoRa parameters:** preset, frequency, TX power and peer, without a rebuild.

**Decided:**
- **Storage: flash**, through Zephyr's settings subsystem on NVS, in an 8 KB `settings_partition` carved from the existing 16 KB storage area; the other 8 KB is reserved. It survives power-off and OTA updates.
  - Retention RAM, as the original idea proposed, is lost whenever power drops, for example each time a power pack is unplugged. So it's used only for the boot-loop guard (§ Lockout analysis), where losing it at power-off is harmless.
- **A sensor needs an IMU.** A board with a radio but no IMU can be a gateway or direct, never a sensor. This matches boot-time detection, which already turns a sensor whose IMU fails into a gateway, and keeps every sensor's motion real.
- **MCUboot boards only.** Sophon doesn't use the UF2 build.
- **The app also scans for sensors** and lists them separately, never auto-connecting to them.

## What "Auto" means

**Auto is the absence of an override.** The board chooses its role at every boot from the hardware it finds, exactly as it does today (`src/role.c:143-174`):

| Radio (Wio-SX1262) answers | IMU starts | Auto chooses |
|---|---|---|
| no | either | **direct**: streams its own motion over BLE |
| yes | yes | **sensor**: sends its motion over LoRa |
| yes | no | **gateway**: relays a sensor's motion to the app |

Auto is the default for every board, the value **Restore defaults** returns to, and the fallback when a stored role no longer suits the hardware. Because it re-detects at each boot, an Auto board follows hardware changes: fit a Wio and it becomes a sensor or gateway; remove it and it becomes direct. The three other values **override** detection and stay fixed until changed.

## What exists to build on

- **Storage:** `storage_partition` at **0xFC000, 16 KB** (four 4 KB pages) in the MCUboot layout (`swd/mcuboot-partitions.overlay`). Nothing uses it, so it can be split before anything does. The UF2 installer already erases 0xFC000 so settings find it clean (`sophon-installer/src/main.c:494-512`), and `flash-swd.sh` leaves it alone so settings survive a reflash.
- **Settings not enabled yet:** no `CONFIG_SETTINGS` or NVS. The flash stack is in `swd/app-mcuboot.conf:51-66`, including `SOC_FLASH_NRF_PARTIAL_ERASE`.
- **`lora_preset_get(id)`** (`lora_presets.c:25-28`) already does a bounds-checked runtime lookup.
- **LoRa values in `lora_link.c`:**
  - the preset pointer is set once at start (`:523`);
  - the frequency is read directly from the macro (`:60`, `:544`);
  - the peer id is already a runtime variable (`:230`).
- **Flash writes go off the system workqueue** through `sophon_slow_work_submit()` (`src/slow_work.c`, #318). The image confirm already does this (`ble.c:491-528`).
- **GATT:** `C6560001`–`06`. No characteristic is writable today, and **the app never writes** to a board. `C6560007` is unused. The ATT MTU is 23, so a write carries at most 20 bytes.
- **The app scans** only for the Sophon service (`SophonHub.swift:376-379`). A sensor advertises the SMP UUID and its name instead (`ble.c:239-251`), though it still serves the full GATT table once connected.
- **Headroom:** the app image is 205 KiB of 476 KiB (43%), and RAM is 49 KiB of 256 KiB.

## Config characteristic (`C6560007`, read and write-with-response)

**Write, 12 bytes, version 1:**

| Off | Type | Field | Values |
|---|---|---|---|
| 0 | u8 | `version` | 1 |
| 1 | u8 | `role` | 0 auto (default: no override, § What "Auto" means) · 1 direct · 2 sensor · 3 gateway |
| 2 | u8 | `preset` | 0–8 (V0…V6b) · 0xFF = build default |
| 3 | i8 | `tx_dbm` | −9…+22 · 0x7F = the preset's own |
| 4 | u32 | `freq_hz` | 0 = build default · else 902 250 000…927 750 000, so a 500 kHz channel stays inside 902–928 MHz |
| 8 | u16 | `peer_id` | 0 = lock onto the first sensor heard |
| 10 | u8 | `flags` | bit 0 `restart` (reboot after saving) · bit 1 `defaults` (erase the stored config) |
| 11 | u8 | reserved | 0 |

**Validation:** an out-of-range field returns ATT error `0x13` (value not allowed), and a wrong length returns `0x0D`. Nothing is stored unless every field is valid. Roles the hardware can't support are rejected too, also with `0x13`: **sensor** on a board with no IMU, and **sensor** or **gateway** on a board with no radio. The firmware knows both from boot.

**Read, 20 bytes:**
- **Stored (10 bytes):** `role`, `preset`, `tx_dbm`, `freq_hz` and `peer_id`, as saved.
- **Active (9 bytes):** `role` as **resolved** (direct, sensor or gateway), `preset`, `tx_dbm`, `freq_hz`, and `peer_id`, which is the sensor locked onto if the setting is 0.
- **Status (1 byte):**
  - bit 0 radio present;
  - bit 1 IMU present;
  - bit 2 **restart pending**: stored ≠ active;
  - bit 3 role forced (not auto);
  - bit 4 config loaded from flash (clear = defaults);
  - bit 5 boot-loop guard tripped: stored config ignored this boot.

The read is all the app needs to show what's running, what will run after a restart, and why a forced role didn't take.

## Lockout analysis

Could a stored config stop the app from reaching the board?

| Stored config | App can still reach it? |
|---|---|
| Role **sensor** | yes: it advertises SMP and its name, which the Sensors scan finds |
| Role **gateway** or **direct** | yes: the Sophon service is advertised as now |
| Preset, frequency, TX power or peer that breaks the LoRa link | yes: they affect LoRa only, never Bluetooth |
| A role the hardware no longer supports (Wio removed, IMU dead) | yes: falls back to Auto at boot |
| A corrupt or out-of-range record | yes: validated on load; invalid means defaults |
| **A config that triggers a firmware bug and crashes at boot** | **no**: a crash loop, with Bluetooth never up, so OTA can't help either |

A valid config never locks the app out, so **Restore defaults belongs in the app**. The crash loop is the only lockout, and the boot-loop guard handles it automatically. If even that fails, erase the partition over SWD (`openocd … flash erase_address 0xFC000 0x2000`, the settings partition only); see BOOTLOADER.md.

## Firmware

- **`src/config.c/.h` (new):**
  - `struct sophon_config`, with defaults taken from Kconfig.
  - A settings handler under `sophon/cfg`, loaded **before IMU init**.
  - `sophon_config_validate()`.
  - Saving through `sophon_slow_work_submit()`, never on the BT RX thread.
  - For `restart`: wait for the save, then `sys_reboot()` about 500 ms later, so the write response goes out first.
- **Restore defaults from the app:** the write's `defaults` flag erases the stored record (`settings_delete`), and with `restart` the board boots on Auto and the Kconfig LoRa values.
- **Boot-loop guard, the one use of retention:** a counter in the nRF52840's `GPREGRET2` retained register, set through `nrf_power_gpregret_set()`.
  - **At boot:** increment the counter. If it has reached **3**, three boots in a row failed to come up, so **ignore the stored config for this boot**. Run on defaults, set a status bit, and log it. The record isn't erased, so the app can show what was stored before restoring defaults.
  - **Once healthy:** clear the counter 10 s after advertising starts, the point at which the app can reach the board.
  - The register survives a reset but not power-off, so a power cycle also starts the count afresh. That's harmless: a crash loop repeats on its own within seconds.
  - MCUboot doesn't use `GPREGRET2` in this build (no serial recovery or boot-mode retention), so it's free.
- **Role resolution:** `sophon_role_detect(imu_ok)` becomes `sophon_role_resolve(override, imu_ok)`, which runs `radio_present()` as now.
  - **Auto:** today's table, unchanged.
  - **Forced direct:** always applies. `device_init(lora_dev)` is skipped even if a radio is present.
  - **Forced gateway:** needs the radio. **Forced sensor:** needs the radio **and** the IMU. Writes asking for anything else are rejected, so a stored role is always one the board supported when it was set. If the hardware has since changed (a Wio removed, or an IMU that fails to start), the board falls back to **Auto** at boot, sets status bit 3, and logs why.
  - **Forced gateway on a Sense Plus:** `main.c` **skips `sophon_imu_init()`**. Otherwise local IMU frames would mix into the relayed stream, with a second `seq` space.
- **LoRa parameters at runtime:**
  - `lora_preset_selected()` reads the config's preset, falling back to `CONFIG_SOPHON_LORA_PRESET`. Drop its `BUILD_ASSERT` in favour of `lora_preset_get()`'s bounds check.
  - `configure()` (`lora_link.c:57-73`) takes the frequency, and the TX power override if set, from the config.
  - `peer_id` starts from the config.
  - Bandwidth stays fixed at 500 kHz, which FCC §15.247 requires without frequency hopping.
- **`ble.c`:** add Config `C6560007`, readable in every role and writable with a response, and the write handler. Advertising doesn't change.
- **Build:** `CONFIG_SETTINGS`, `SETTINGS_NVS` and `NVS` go in `swd/app-mcuboot.conf`, beside the flash stack already there. Settings use the new `settings_partition` (chosen as `zephyr,settings-partition`). Set `CONFIG_SETTINGS_NVS_SECTOR_COUNT=2` (§ Storage sizing).

### Storage sizing

**Split the 16 KB storage area in two.** In `swd/mcuboot-partitions.overlay`, replace the single `storage_partition` with:

| Partition | Address | Size | Use |
|---|---|---|---|
| `settings_partition` (`zephyr,settings-partition`) | 0xFC000 | 8 KB, 2 sectors | settings: the config record |
| `reserved_partition` | 0xFE000 | 8 KB, 2 sectors | **unassigned**, kept erased, for a future use |

**NVS in 2 sectors.** The settings NVS backend (`subsys/settings/src/settings_nvs.c:418-435`) uses a sector size of `SETTINGS_NVS_SECTOR_SIZE_MULT` (default 1) × the flash page, which is **4 KB** on the nRF52840. It adds sectors up to `SETTINGS_NVS_SECTOR_COUNT`, stopping at the partition's size; set it to **2** to match the partition. Two is NVS's minimum: one sector in use, one kept empty for garbage collection.

| | |
|---|---|
| Usable | 1 sector, 4 KB |
| One config record | about 10 B of value, the `sophon/cfg` key, and an 8 B allocation-table entry per write, so roughly 30–40 B |
| Saves before each garbage collection | about 100 |
| Wear | a sector is erased only at garbage collection, about every 100 saves, alternating between the two. At the nRF52840's rated 10,000 erase cycles per page, that's about two million config saves |
| Sharing | nothing else uses settings: no Bluetooth bonding (`BT_SETTINGS` off). A future small setting, such as a stored peer list, still fits |

**Why split now:** once boards hold a config, moving or resizing the settings area means migrating it. Carving off the reserved half now costs nothing, since one sector holds about 100 config saves. Candidate uses for it later: a Zephyr crash-dump partition, to read the cause of a crash loop; or an on-board ring of LoRa Link records, about 65 minutes, for field tests while no phone is connected.

**Other code that knows the area:**
- the installer's step 5b (`sophon-installer/src/main.c:494-512`) erases all 16 KB at 0xFC000 on migration. That's still right, since it clears both partitions; update its comment and `STORAGE_BASE` naming;
- `flash-swd.sh` leaves 0xFC000–0xFFFFF alone, so a stored config survives an SWD reflash; an OTA update never touches it;
- BOOTLOADER.md's memory map gains the two rows in place of `storage`.
- **VERSION** bump, and a ChangeLog entry.

## App

- **Discovery** (`SophonHub.swift`):
  - Scan for `[serviceUUID, smpServiceUUID]`.
  - A board advertising the Sophon service is listed exactly as now.
  - A `Sophon-` board advertising **only SMP** is a **sensor**: listed in a separate "Sensors" section, never auto-connected, connected only on tap and released when its screen closes.
- **`SophonHub+Config.swift` (new), following `SophonHub+LoRaLink.swift`:**
  - Add `C6560007` to the explicit characteristic list (`:704-710`) and the switch (`:745-786`).
  - An `offersConfig` latch.
  - Read at session start.
  - `writeValue(.withResponse)`, plus the app's first `didWriteValueFor` handler, mapping ATT `0x13` and `0x0D` to readable messages.
- **`SophonProtocol.swift`:** `ConfigState` (read) and `ConfigRequest` (write, with `encoded`). A DEBUG `checkConfig()` uses hand-transcribed vectors from PROTOCOL.md and covers range rejects and the length rules.
- **UI:** a **Configuration** section in `DeviceDetailView`, after `linkSection` and gated on `offersConfig`, showing **Active** against **After restart**. An **Edit** form, the app's first `Form` and `.sheet`, offers:
  - **Role:** Auto (default) / Direct / Sensor / Gateway, offering only what the board's hardware supports (from status bits 0–1). Shows what Auto picks on this board, and warns that a board set to Sensor will move to the Sensors list.
  - **Preset:** a picker with each preset's SF, latency and range, taken from LORA-PROTOCOL.md.
  - **Frequency** in MHz; **TX power**, under Advanced; **Peer:** any, or a specific `Sophon-XXXX`.
  - **Save** and **Save and restart**, with a confirmation.
  - **Restore defaults.**
- **Keeping both ends in step:** a LoRa link needs the same **SF and frequency** at both ends. The gateway decodes any CR, k or format. When a gateway's stored preset or frequency differs from what it's hearing, the app says "the sensor must match", and offers to open the sensor.
- **After a restart:** a restart arrives as a disconnect and the app reconnects (`SophonHub.swift:607-652`). The app re-reads Config after `beginSession()` to confirm what's active. A board that comes back as a sensor reappears under Sensors.

## Docs

- **PROTOCOL.md:** § Config frame (both layouts, validation, the restart semantics); `C6560007` added to the UUID table.
- **LORA-PROTOCOL.md:** § Roles, the override and which roles each kind of board supports; parameters at runtime.
- **README.md:** § Roles and § The radio link.
- **FIELD-TEST.md:** configuring both units from the app for each scenario:

| Scenario | Vehicle unit (Sense Plus + Wio) | Other unit |
|---|---|---|
| 1 | Auto (a sensor) | any board with a Wio, as gateway (a base XIAO on Auto is one) |
| 2 | **Gateway** (IMU skipped) | **a Sense Plus + Wio as sensor** (e.g. 4D88 on a Wio carrier); a base XIAO can't be a sensor |

- **Recovery** (README and BOOTLOADER.md): **Restore defaults** in the app; the automatic boot-loop guard; and, as a last resort, erasing the settings partition (0xFC000, 8 KB) over SWD. Settings survive OTA and SWD reflashing.
- **Security note:** config writes are unauthenticated, like SMP today: anyone in range could reconfigure a board. Recorded, not fixed here.

## Workflow

1. File the issue `sophon: configure role and LoRa parameters from the app`, with a `### Requirements` checklist, on Project 1. Branch `<N>-device-config`, In progress, Start date.
2. Save this plan as `zephyr/sophon/CONFIG-PLAN.md`, the design record, as with LORA-PLAN.md.
3. Firmware first, verified over SWD and the console; then the app; then the docs. In review with a summary, and pause for consent.

## Verification

1. **Builds:** the MCUboot build is clean; record the flash and RAM increase. `test-codec.sh` still passes.
2. **Persistence:**
   - write a config, then power-cycle (not just reset): it's still active;
   - OTA a new build: it's kept;
   - **Restore defaults** from the app, then restart: Auto and the Kconfig values are back, and status bit 4 is clear;
   - **boot-loop guard:** a temporary test build that faults at boot when a marker setting is present. After three crashes the board boots on defaults, status bit 5 is set, the app reaches it, and Restore defaults clears the marker. The test build is then discarded;
   - an invalid write (preset 9, frequency 900 MHz, wrong length) returns the ATT error and stores nothing.
3. **Roles on hardware:**
   - **86F0 (Sense Plus) forced to gateway:** the IMU isn't initialised, the console logs the role, relayed motion from the other unit is continuous with no `seq` interleaving, and the LoRa Link record arrives.
   - **A second Sense Plus as sensor** while 86F0 is the gateway: LQ 100% and about 54 Hz in the app; the image confirms after an OTA.
   - **0FAA (base XIAO) asked for sensor:** rejected with ATT `0x13`, and nothing stored.
   - **A stored sensor role on a Sense Plus with its Wio removed:** boots as Auto (so direct), status bit 3 set, cause logged.
4. **LoRa parameters:**
   - change both ends to another preset and frequency from the app: link restored, and the record shows the new preset;
   - change only one end: the app shows the mismatch warning, and the link drops as expected.
5. **App:**
   - a sensor appears under Sensors and is never auto-connected;
   - editing it and pressing Save and restart brings it back under Sensors with its new settings;
   - DEBUG `checkConfig()` passes at launch;
   - swift-reviewer runs on the diff;
   - simulator screenshot, then the iPhone on both units.
6. **Field rehearsal:** with two Sense Plus + Wio units, and no hardware swaps, switch between scenarios 1 and 2 from the app alone.
