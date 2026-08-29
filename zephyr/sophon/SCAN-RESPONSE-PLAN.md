# Sophon scan-response data — device type, versions, TX power

> **This is the approved plan, kept as the record of what was intended.** It is not
> updated to match the code. Where implementation contradicted it, a `> **Annotation**`
> block says so in place — the same treatment `ios/Sophon/UPDATED-PLAN.md` got when the
> 185-byte MTU figure turned out to be wrong.

## Context

A Sophon peripheral advertises flags, the 128-bit service UUID, and a friendly name
(`Sophon-4D88`). Nothing says which **board revision** or **firmware build** is on the
other end, nothing gives TX power, and nothing distinguishes one kind of Sophon from
another. With two boards now in play and #211 wanting several, "which one is running
what" has no answer short of plugging in USB and reading the console.

This adds a device type, a structure version, hardware and firmware versions, and TX
power — all to the **scan response**, all readable **before connecting**, which is the
property `UPDATED-PLAN.md` reserved this capacity for.

## Out of scope, deliberately

**No chip device ID.** `hwinfo_get_device_id()` returns 8 bytes — the Nordic SoC's
factory FICR DEVICEID, verified: `hwinfo_nrf.c` reads
`nrf_ficr_deviceid_get(NRF_FICR, 0/1)` into a `uint32_t id[2]`, byte-swaps each word,
caps the copy at 8 and returns the length written. It is the chip's permanent unique
identifier, not anything board-level, and broadcasting it continuously is not wanted.
None of those 8 bytes go on the air.

The friendly name stays FICR-derived — `ident.c` takes the **last two** of those 8
bytes, which the swap puts at the variable end. Reviewed and kept: it is a *friendly
name*, the truncation is deliberate, and the boards already broadcast stable random
static BLE addresses that cannot be hidden without pairing, which Sophon deliberately
does not do.

Reconsidered mid-design and declined again, so it does not come up a third time. Three
reasons it stays off the air:

- **It buys almost nothing.** The only problem it solves is a name-hash collision — two
  boards sharing the same last two FICR bytes, ~1/65536 across two boards, which
  `UPDATED-PLAN.md` already dismissed as "not a real risk at a handful of boards". For
  app-side keying, `peripheral.identifier` already provides a stable per-board handle.
- **It is a different *kind* of identifier than the BLE address.** The board is already
  trackable via its stable static random address, so the marginal tracking harm is near
  zero — but that address only means something inside BLE, whereas a factory-burned
  globally-unique chip ID is cross-referenceable outside it.
- **It costs the last of the headroom.** The full 8 bytes do not fit anywhere (12 B on
  air against 10 spare in the advertisement, 5 in the scan response). A 4-byte
  truncation appended to the scan-response structure would fit at 30 of 31 — and putting
  it in the *advertisement* instead would mean a second manufacturer-data structure,
  reintroducing the undefined merge behaviour this design deliberately removed.

**No motion withholding.** #230's original draft had the app refuse to display motion
from a peripheral whose GATT contract version it did not recognise. Set aside at the
user's direction. This is **display-only** apart from the connection-policy note below.
The misparse protection is still worth having and should stay filed rather than quietly
dropped.

## The structure

Everything lands in the scan response. The advertisement is untouched.

```
Advertisement — 21 of 31, 10 spare   (unchanged)
  flags                          1+1+1  =  3 B
  128-bit service UUID           1+1+16 = 18 B

Scan response — 26 of 31, 5 spare
  complete local name            1+1+11 = 13 B   "Sophon-4D88"
  TX power            (0x0A)     1+1+1  =  3 B   signed dBm, iOS parses this for free
  manufacturer data   (0xFF)     1+1    =  2 B
    SOPHON_COMPANY_ID                   =  2 B   0xFFFF
    SOPHON_SCAN_RSP_VERSION             =  1 B   0x01 — versions THIS structure
    SOPHON_DEVICE_TYPE                  =  2 B   0x0001 = Sophon
    SOPHON_HW_VERSION                   =  1 B   0x01 — board revision, by hand
    SOPHON_FW_VERSION_MAJOR             =  1 B   0x02 — APP_VERSION_MAJOR, from VERSION
    SOPHON_FW_VERSION_MINOR             =  1 B   0x00 — APP_VERSION_MINOR, from VERSION
                                       ────────
                                           26 B
```

Every field is an AD structure — one length byte, one type byte, then payload — which is
where each `1+1` comes from. Those two header bytes are written by the host when it
serialises the array, not stored in our buffers; Zephyr names the sum
`BT_DATA_SERIALIZED_SIZE(data_len)`, i.e. `data_len + 2`. Manufacturer data spends 2 more
on the company ID before any payload of its own, so 6 useful bytes cost 10.

The name row is its **longest** case. The hwinfo fallback name is plain `Sophon`, 5 bytes
shorter, putting the scan response at 21 of 31.

### Why one structure, in one packet

An earlier draft split this: device type in the advertisement, versions in the scan
response. That put **two** manufacturer-data structures on the air, both with company ID
`0xFFFF`, and nothing in the SDK says what a central does with that. iOS merges both
packets into one `advertisementData` dictionary with a single
`CBAdvertisementDataManufacturerDataKey` — one `Data`. It might concatenate, keep one, or
drop one. [`bleak`](https://github.com/hbldh/bleak) — the standard cross-platform Python BLE
client, the usual way to script a scan from a laptop — has the same shape, a dict keyed by
company ID, so two `0xFFFF` structures collide there too.

Collapsing to one structure **designs the unknown away** rather than scheduling a spike
to measure it. It also leaves the advertisement completely untouched at 21 of 31, so its
10 spare bytes stay available — where the split would have closed it at 30 of 31 with one
unusable byte.

The cost: these fields now arrive only if iOS requests and merges the scan response. That
demonstrably happens — the name lives there and both iPads display `Sophon-4D88` and
`Sophon-86F0` — and the consequence of missing it is a row reading `Not reported`, which
is benign.

**Connection policy, if it ever uses device type, must fail open.** Nothing uses the
field for policy today — it is display-only — so this is the rule for when something
does.

The decisive case is not a missed packet, it is the **simulator**: an iOS peripheral
cannot advertise manufacturer data at all, so a simulated Sophon has no device type,
ever. A policy that required a recognised type would refuse every simulator and break
#226 outright. Un-reflashed boards are the same — including both current boards until
they are flashed with this change.

So: absent or unrecognised device type means **connect anyway**. There is little lost by
doing so, because the scan is already filtered on the Sophon service UUID, so anything
reaching the app is a Sophon regardless; the field's real use is distinguishing *variants*
once more than one exists. Fail-open is correct here — the opposite of the motion case in
#230's original draft, where the safe default was to withhold. Worth stating plainly,
because the two rules point in opposite directions and the difference is whether a wrong
guess shows bad data or hides good hardware.

### TX power

Standard AD type `0x0A`, not a byte inside our manufacturer data. It costs 3 bytes rather
than 1, but iOS populates `CBAdvertisementDataTxPowerLevelKey` from it with no parsing of
ours, and nRF Connect or any other scanner shows it without knowing our format.

Zephyr cannot fill it in automatically here: `BT_LE_ADV_OPT_USE_TX_POWER` requires
`BT_LE_ADV_OPT_EXT_ADV`, and Sophon uses legacy advertising. So it is hand-built — but
from `CONFIG_BT_CTLR_TX_PWR_DBM` (currently `0`), the same symbol that sets the radio's
actual power, so the advertised value cannot drift from reality. Do not hardcode it.

> **Annotation (during implementation).** "Cannot drift" is too strong. It holds only
> while the configured value is a TX power the radio actually has. The nRF52840's steps
> are +8, +7, +6, +5, +4, +3, +2, 0, −4, −8, −12, −16, −20, −40 dBm;
> `hal_radio_tx_power_value()` rounds down to one of those while
> `CONFIG_BT_CTLR_TX_PWR_DBM` keeps the number that was requested — and the requested
> number is what gets advertised. Selecting −1 dBm transmits −4 and advertises −1. Since
> a central estimates distance as `TX power − RSSI`, that error reaches every scanner.
> `prj.conf` now lists the native steps and warns off the rest.
>
> Separately, the shipped default is **−4 dBm**, not the 0 dBm this plan assumed
> throughout — lowered after approval to reduce airtime ahead of #211, then walked back up
> over three measured rounds: −16 dBm lost frames beyond ~1 m, −8 dBm still lost them at
> desk range in line of sight, −4 dBm is clean. The free-space budget that suggested
> −16 dBm would reach 8-10 m was wrong by about an order of magnitude. Another figure in
> this project that measurement contradicted.

### What the scan-response version versions

**This structure's layout, and nothing else** — not the GATT contract, not the 18-byte
frame.

Paired with a rule that keeps it from needing frequent bumps: **fields are append-only
and never reordered.** Parsers read the offsets they know and ignore trailing bytes.
Appending a field needs no bump; only changing the meaning of an existing one does. Which
also means an *unrecognised* version is safe to parse — append-only guarantees the known
offsets still hold — so the app parses regardless and simply surfaces the version when it
is one it does not know.

## Changes

### Firmware — `zephyr/sophon/src/`

- **New `src/version.h`** — every value named, no literals at the use site. A separate
  header rather than `frame.h`, because `frame.h` is the *wire frame* contract; putting
  these there would imply the frame layout changes when a board revision does.

  ```c
  #include <zephyr/app_version.h>  /* generated from zephyr/sophon/VERSION */

  #define SOPHON_COMPANY_ID       0xFFFFU  /* reserved for internal/test use, not exclusive */
  #define SOPHON_SCAN_RSP_VERSION 0x01
  #define SOPHON_DEVICE_TYPE      0x0001U  /* Sophon motion peripheral */
  #define SOPHON_HW_VERSION       0x01     /* XIAO nRF52840 Sense Plus, rev 1 */
  #define SOPHON_FW_VERSION_MAJOR APP_VERSION_MAJOR  /* bump rule: see VERSION */
  #define SOPHON_FW_VERSION_MINOR APP_VERSION_MINOR

  #define SOPHON_MFG_DATA_SIZE 8

  struct sophon_mfg_data {
  	uint16_t company_id;
  	uint8_t  scan_rsp_version;
  	uint16_t device_type;
  	uint8_t  hw_version;
  	uint8_t  fw_version_major;
  	uint8_t  fw_version_minor;
  } __packed;
  ```

  Plus the two `BUILD_ASSERT`s `frame.h` already models — `sizeof(...) == SOPHON_MFG_DATA_SIZE`
  and the little-endian check — repeated rather than inherited, so the header stands alone.
  The struct is what makes the layout a single declaration instead of hand-placed offsets, and
  it is why the budget arithmetic reads `2 + 6`.

  **`company_id` must be first — that is the spec, not a preference.** The Core Spec Supplement
  defines AD type `0xFF` as *the first 2 octets are the Company Identifier, followed by
  additional manufacturer-specific data*. Zephyr's `samples/bluetooth/broadcaster` shows it
  literally: `static uint8_t mfg_data[] = { 0xff, 0xff, 0x00 };`. Put
  `SOPHON_SCAN_RSP_VERSION` first instead and every standard scanner would read `0x0101` as
  the company ID and misattribute the packet to some real member company. So the version byte
  is simply the first byte we *own* — which is the property we want anyway: it versions
  everything after the company ID, i.e. exactly the part we control.

  There is **no upstream symbol to reuse**: Zephyr's `assigned_numbers.h` defines only
  `BT_COMP_ID_LF` (`0x05f1`, the Linux Foundation) — nothing for `0xFFFF`.

  **`SOPHON_COMPANY_ID` cannot catch a byte-order mistake**, because `0xFFFF` reads the same
  either way. `SOPHON_DEVICE_TYPE` can — `0x0001` must appear as `01 00` — so it is the field
  to check on the wire, and the reason verification step 1 spells the bytes out. Worth a
  comment beside the define, since swapping in a real assigned company ID later would put
  live weight on an ordering nothing had ever tested.
- **`src/ble.c`** — two entries added to the `scan_rsp[]` array built in
  `start_advertising()`: the standard TX power field and one manufacturer-data field.
  `adv_data[]` is untouched. `scan_rsp[]` stays function-local rather than `static const`
  (unlike the neighbouring `adv_data[]`) because the name entry's length is only known at
  runtime — next bullet. Both new entries are rebuilt on each re-advertise, which is
  harmless.
- **Do not replace `strlen(device_name)` with a constant `11`.** The advertised name is not
  always 11 bytes: `ident.c:28-31` falls back to `strcpy(buf, "Sophon")` — 6 characters —
  when `hwinfo_get_device_id()` fails. A hardcoded 11 would broadcast the terminator plus 4
  bytes of uninitialised buffer on that path. `BT_DATA()` takes the octet count as an
  explicit third argument, so something must supply it; `strlen` is what keeps both paths
  correct. Worth a comment, because 11 *looks* invariant.
- **Update the byte-budget comment at `ble.c:86-90`** — it currently conflates the
  advertisement and scan-response budgets, which are separate 31-byte limits, and this
  change touches only the latter.
- **Add a `BUILD_ASSERT` on the scan-response budget.** An earlier draft of this plan said
  the size could not be derived at compile time. Wrong — Zephyr supplies the arithmetic in
  `<zephyr/bluetooth/data.h>` and `gap.h`: `BT_DATA_SERIALIZED_SIZE(data_len)` is
  `data_len + 2`, and `BT_GAP_ADV_MAX_ADV_DATA_LEN` is 31. Every payload length is a
  compile-time constant, and the name's *worst case* is one too — `SOPHON_NAME_MAX - 1`:

  ```c
  BUILD_ASSERT(BT_DATA_SERIALIZED_SIZE(SOPHON_NAME_MAX - 1) +  /* name, longest case */
             BT_DATA_SERIALIZED_SIZE(1) +                      /* TX power */
             BT_DATA_SERIALIZED_SIZE(2 + 6)                    /* company ID + payload */
             <= BT_GAP_ADV_MAX_ADV_DATA_LEN,
             "Sophon scan response exceeds the legacy 31-byte limit");
  ```

  This is not a second source of truth — it is built from the same constants the code hands
  to `BT_DATA()`. What genuinely does not work is `sizeof(scan_rsp)`: `struct bt_data` is
  `{type, data_len, *data}`, so it measures descriptors, not on-air bytes.
- **Log the exact on-air size** next to the existing `advertising as %s` line, via
  `bt_data_get_len(scan_rsp, ARRAY_SIZE(scan_rsp))` — a first-party helper used this way in
  Zephyr's own `peripheral_ead` sample. The `BUILD_ASSERT` bounds the worst case; this
  reports what the board actually sent, including the 21-byte fallback-name case, and turns
  a bare `-EINVAL` into a self-describing number.

- **New `zephyr/sophon/VERSION`** — Zephyr's standard app-version mechanism, five fields, the
  same shape as `$ZEPHYR_BASE/VERSION`:

  ```
  # Bump the minor for each flashed build. Bump the major and zero the minor
  # when cutting a sophon-fw-vN tag.
  VERSION_MAJOR = 2
  VERSION_MINOR = 0
  PATCHLEVEL = 0
  VERSION_TWEAK = 0
  EXTRAVERSION =
  ```

  All four numeric fields present: `version.cmake` validates each and the derived
  `math(EXPR ...)` needs them. Comments are safe — the parser regex-searches for
  `VERSION_MAJOR = ` and friends, so keep those exact tokens out of comment text.

  **`CMakeLists.txt` needs no change.** The guard is
  `if(EXISTS ${APPLICATION_SOURCE_DIR}/VERSION)` (`zephyr/CMakeLists.txt:713`), and
  `add_dependencies(zephyr_interface app_version_h)` puts the generated header on the include
  path by itself. `#include <zephyr/app_version.h>` then yields `APP_VERSION_MAJOR`,
  `APP_VERSION_MINOR`, `APP_VERSION_NUMBER` (`0x020000`) and `APP_VERSION_STRING` (`"2.0.0"`).

  Starting at **2.0** — #209 shipped as 1, this is the second generation.

  **Tag convention: `sophon-fw-v<major>`.** Prefixed because five projects share one tag
  namespace and the two tags in the repo today (`nordic-zephyr-ios-template`,
  `pre-vercel-migration`) are unprefixed labels rather than versions. Cut `sophon-fw-v2` when
  this lands.

  **The 255 ceiling needs no wrap logic.** `version.cmake` already `FATAL_ERROR`s above 255 with
  a readable message, and the response is to bump the major — which zeroes the minor anyway. The
  wrap discussed earlier was for an auto-incrementing counter; hand-bumping does not need it.

  Deliberately **not** enabling `CONFIG_APP_VERSION_SHELL` (which would add `app version` /
  `app build-version` commands via `subsys/shell/modules/app_version_service.c`) — Sophon runs
  no shell, and this change does not need one.

**Both version bytes are hand-maintained, and that is the rot risk.** Nothing on the board can
read its own hardware revision, and the standard Zephyr mechanism has no auto-increment — the
numbers are whatever the `VERSION` file literally says. A version byte nobody remembers to bump
is worse than none, because it asserts something stale as fact: this session alone found three
inherited "facts" that measurement contradicted.

Three mitigations, none of which make it automatic:

- **State the bump rule where the numbers live** — the comment at the top of `VERSION`, quoted
  above, and a line in `version.h` pointing at it.
- **Log `APP_VERSION_STRING` and a build timestamp in the boot banner**, beside the existing
  `advertising as %s`. This is the cheap one: a stale version becomes visible every time you
  flash and watch the console, rather than only over the air where nobody is looking. The
  timestamp answers the separate question the version cannot — *is this the build I just
  flashed* — and it costs no air bytes, so the scan response stays at 26 of 31.

  **Generate it, do not use `__DATE__` / `__TIME__`.** Those record when one translation unit
  was compiled, so an incremental build that does not touch that file prints a stale time —
  which is exactly the "asserts something stale as fact" failure this section exists to
  prevent, and worse than printing nothing because it would say *you did not flash the new
  build* when you did. Instead emit a generated header from CMake:

  ```cmake
  string(TIMESTAMP SOPHON_BUILD_TIME "%Y-%m-%dT%H:%M:%SZ" UTC)
  ```

  written by an `add_custom_command` marked to regenerate on **every** build, with the banner's
  source depending on it. Only the banner string varies between builds of identical source, so
  nothing in the firmware image's behaviour becomes irreproducible.
- **Keep both fields display-only.** A stale value then misinforms rather than misbehaves — no
  connection policy, no parsing decision, nothing downstream branches on them.

The other two fields cannot drift: TX power comes from `CONFIG_BT_CTLR_TX_PWR_DBM`, the same
symbol that sets the radio; device type is constant across all boards.

> **Annotation (during implementation).** See the TX power section above — the claim holds
> only for TX power levels native to the radio.

Recorded so it is not re-proposed: **git cannot supply these numbers through the standard
mechanism.** `APP_VERSION_MAJOR`/`_MINOR` are parsed only from the `VERSION` file's literal
text. Zephyr does expose one git-derived value, `APP_BUILD_VERSION` — but it is a *string*, and
`git.cmake`'s `git_describe()` hardcodes `--abbrev=12 --always` with no `--match` and no
`--long`, so in this monorepo it would describe against unrelated tags like
`pre-vercel-migration`. Automating the minor means leaving the standard mechanism, which was
weighed and declined.

### App — `ios/Sophon/Sophon/`

- **`BLE/SophonProtocol.swift`** — inside the existing `nonisolated enum` (load-bearing:
  CB delegate callbacks are nonisolated under `SWIFT_DEFAULT_ACTOR_ISOLATION =
  MainActor`): `static let companyID`, `knownScanRspVersion`, `knownDeviceType`, and a
  `minWireSize` — named the same way `TxStats.wireSize` and the three `…UUID` constants
  already are, so nothing reads a literal at a use site on this side either. Plus a
  `static func` parser taking `Data` and returning a small `Sendable` value type. Mirrors
  how `TxStats.init?(_:)` already validates a wire payload by length.

  Each constant's value must be traceable to `version.h` in a comment, the way the file's
  header already says any change here needs the same change on the firmware side — two
  copies of these numbers now exist and nothing but that note connects them.

  **The parser must tolerate trailing bytes** — require a minimum length, check the
  company ID, read known offsets, ignore the rest. Requiring an exact length turns the
  append-only rule into a parse failure the first time anything is appended.

  **iOS hands back all 7 bytes, `bleak` hands back 5.** `CBAdvertisementDataManufacturerDataKey`
  is the *whole* structure, company ID included, so Swift reads the company ID at offset 0 and
  the version at offset 2. `bleak` instead keys a dict by company ID and strips it, which is
  why verification step 1 expects 5 bytes, not 7. Same wire bytes, two different views —
  worth stating so the two figures do not read as a contradiction, and so nobody "fixes" the
  Swift offsets to match the Python.
- **`BLE/SophonHub.swift`** — read `CBAdvertisementDataManufacturerDataKey` and parse it
  *before* the `Task { @MainActor }` hop, alongside the existing name read at `:184`,
  since the `[String: Any]` dictionary is not `Sendable`. Also read
  `CBAdvertisementDataTxPowerLevelKey` (an `NSNumber`) there — it is a **signed** dBm
  value; reading it unsigned would render −8 as 248. Feed **both** the create path
  (`:199`, via the initialiser) and the update path (`:190-197`) — the create is usually
  the only callback, so handling only the update would drop the one packet that carried
  it.
- **`BLE/SophonDevice.swift`** — store the parsed fields, defaulting to a sentinel meaning
  *"never observed"*. **Latch**: write only when well-formed data is present, mirroring
  the `displayName` guard, so a callback without the structure cannot blank a good value.
  **Exclude from `resetLinkStats()`** — its lifetime is the advertisement, not the
  session. That file documents this exact bug biting once with `attMTU` (`:295-299`), and
  there the reset at least had `beginSession()` to recover it.
- **`ContentView.swift`** — `Hardware`, `Firmware` and `TX power` rows in `linkSection`,
  shown **unconditionally** including at the sentinel. Neighbouring RSSI and ATT MTU rows
  use `if let` and vanish when nil, which is wrong for a field whose absence is meaningful
  — the argument `framesSection` already makes.

  Sentinel reads **`Not reported`**: the app knows what it observed, not what the
  peripheral is. Every simulator reads this way permanently, so it must not be styled as a
  fault. Surface scan-response version and device type only when unrecognised — otherwise
  noise.

### Docs

- **`PROTOCOL.md`** — the fields, company ID, layout, current values, the append-only
  rule, and the revised scan-response budget. It documents the advertisement/scan-response
  split explicitly today, which this change extends.
- Add a simulator-divergence row: **an iOS peripheral cannot advertise manufacturer data
  at all** (`startAdvertising` honours only LocalName and ServiceUUIDs, confirmed against
  the SDK), so a simulator can never carry any of this. Extend the comment at
  `SophonPeripheral.swift:294-305` so nobody later tries to "fix" it with a key iOS
  ignores.
- **Commit this plan as `zephyr/sophon/SCAN-RESPONSE-PLAN.md`** — the same treatment
  `ORIGINAL-PLAN.md` / `SIMULATOR-PLAN.md` / `UPDATED-PLAN.md` already get in
  `ios/Sophon/`. Placed under `zephyr/sophon/` rather than beside those three because the
  change is firmware-led and it extends `PROTOCOL.md`, which lives there; say the word if
  you would rather it sat with the others.

  Two conventions carry over from those files. It goes in **as approved**, minus the
  `🆕 Latest changes` iteration callout, which is scaffolding for reviewing the draft and
  not part of the record. And per the ChangeLog's note on `ORIGINAL-PLAN.md` and
  `SIMULATOR-PLAN.md`, it is then **frozen** — a plan that rewrites itself to match the
  code stops being evidence of anything. Corrections go in `PROTOCOL.md`, or as annotations
  the way `UPDATED-PLAN.md` was handled when the 185-byte MTU turned out to be wrong.

  Worth keeping precisely because the reasoning here is mostly *rejected* alternatives —
  the two-structure split, the chip device ID (twice), the constant `11`, extended
  advertising — and none of that survives in the diff.
- **Issue #230** describes the deferred motion-withholding design, not this. Rewrite its
  body to match what is being built and file the misparse protection separately, so a good
  idea is parked rather than lost.

## Verification

1. **Content, from a scanner that is not our app** — confirms the firmware independently.
   Two options, and **neither needs installing anything by default**:

   - **nRF Connect on the iPhone** (already to hand, already cited in the TX-power section):
     read the manufacturer data and the TX power row directly.
   - **`bleak` on the Mac**, *if* you want it scripted: `manufacturer_data[0xFFFF]` should
     read `01 01 00 01 02 00` (version, device type little-endian, hw `01`, fw `02 00`) and `.tx_power`
     should read `0`. Note it is **not installed and not used anywhere in this repo** — it
     would be a `pip install` and a scratch script, not a committed dependency. An earlier
     draft of this plan assumed it was available; it is not.

   **Neither can prove *which packet* carried a field.** Both are CoreBluetooth-backed on
   Apple hardware, and CoreBluetooth merges the advertisement and the scan response into one
   `advertisementData` dictionary before anyone sees it — the same merge this design works
   around. Separating them on air would need `btmon` on a Linux host or an nRF Sniffer.
   That is fine, because the split does not need on-air proof: the fields are in the
   `scan_rsp[]` array by construction, and step 2 checks the size from the firmware side.
   The check that matters here is the **byte order** — `01 00`, not `00 01`.

   A board connected to an iPad is invisible to other scanners, so free one first.
2. **Byte budget** — now checked three ways: the `BUILD_ASSERT` fails the *build* if the
   worst case exceeds 31, the boot banner logs the actual figure (expect `26`), and
   `bt_le_adv_start()` would still return `-EINVAL` as the backstop. 26 of 31, 5 spare.
3. **Each field tracks the source it claims to** — cheap to prove, and worth proving because
   both claims are load-bearing:
   - **TX power** — rebuild once with a different `CONFIG_BT_CTLR_TX_PWR_*` and confirm the
     advertised value follows.
   - **Firmware version** — bump `VERSION_MINOR` to 1, rebuild, confirm the advertised bytes
     read `02 01`, then put it back. Use the **minor**: it proves the second byte is wired to
     its own source rather than both tracking one value, which bumping the major would not
     distinguish. It also confirms `<zephyr/app_version.h>` is generated at all — if the
     `VERSION` file were mislocated, Zephyr simply skips generating the header and the build
     fails on the missing include, which is the desired failure.

4. **Both boards** — `Sophon-4D88` and `Sophon-86F0`, identical values.
5. **App vs board** — Hardware, Firmware and TX power rows populate, before and after
   connecting. TX power should arrive via `CBAdvertisementDataTxPowerLevelKey` with no
   parsing of ours.
6. **App vs simulator** — all three read `Not reported`, nothing styled as an error.
7. **Trailing-byte tolerance** — temporarily append a byte in the firmware and confirm the
   app still parses. This is the forward-compatibility rule the append-only design rests
   on; worth proving once rather than assuming.
8. **Simulator screenshot** read, per `ios/CLAUDE.md`, since `ContentView` changes.

## Process

Branch `230-scan-rsp-data`, ChangeLog entry, In review plus consent before commit. Spans
`zephyr/sophon/` and `ios/Sophon/` — one `sophon:` issue, one branch, per the convention.

`SCAN-RESPONSE-PLAN.md` lands in the **first** commit on the branch, before the code, so the
record is of what was approved rather than what was reconstructed afterwards.
