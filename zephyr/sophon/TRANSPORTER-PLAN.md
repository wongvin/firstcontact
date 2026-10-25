# Transporter: measuring LoRa bit errors

Design for #359, agreed on 2026-10-23. A board in the **transporter** role
(as in Star Trek) sends its own running image over LoRa with the payload CRC
off, and a gateway measures how many bits arrive wrong. LORA-PROTOCOL.md
§ Bit-error test is the live contract for the packet; PROTOCOL.md § LoRa BER
frame is the reference for the record. This records how it's measured and why.

## Context

Today a radio+IMU board is a **sensor** and streams motion over LoRa. The
gateway can count *lost* packets, but not *damaged* ones: the LoRa payload CRC
drops a damaged packet in the radio, before the firmware sees it. LQ says how
many packets arrive, not how clean the channel is.

Every board runs the same image, so a gateway already holds a perfect copy of
anything another board sends from its own flash. A transporter sends its image
(slot 0) with the payload CRC **off**. The gateway compares each received
packet bit by bit with its own slot 0 and reports the channel's **bit error
rate**, **damaged-packet %** and **lost-packet %**. The figures go to the
console and to the iOS app, which shows them and records them in the walk-test
CSV.

Decisions:
- a **new role** alongside the sensor, which stays as it is;
- **raw bit errors, CRC off**, not packet-level figures with the CRC on;
- output to the **console and the iOS app**.

## Image identity and extent

- **Only the image's valid bytes are sent.** The transporter and the gateway
  each read their **own** slot 0: from the MCUboot header through the body,
  `ih_hdr_size + ih_img_size` bytes, which both take from the image header at
  the start of slot 0. Not sent:
  - the rest of the 480 KB slot, which is erased `0xFF` and the same on every
    board;
  - the TLVs (hash and signature);
  - MCUboot's swap trailer at the slot's end, which differs between boards.
- **The loop:** the offset advances by n bytes per packet, mod the image length
  L. A packet that crosses the end carries the last bytes and then the first
  ones, so every payload byte is a real image byte and every packet is the same
  length. The gateway reads its reference the same way, mod its own L.
- **Identity is the image's SHA-256.** It covers the MCUboot header and body:
  exactly the bytes sent. The signature isn't covered, so a reproducible rebuild
  has the same hash even though RSA-PSS gives it a different signature. **Equal
  hashes mean equal bytes on air.** The firmware reads its own hash with
  the SHA-256 TLV after the image (bootutil/image.h layout).
- **The hash isn't sent.** Two things replace it:
  - **The app compares the hashes.** A **Check images** button reads both
    boards' slot-0 hash over SMP and shows Match, Mismatch, or Transporter not
    reachable. Run it at the bench before a walk.
  - **The gateway keeps a backstop, at no byte cost.** `hcrc` is seeded with
    the board's own hash. Matching images behave exactly as if it weren't
    seeded. On a mismatch every `hcrc` fails, no anchor ever forms, and every
    packet is unresolved, so the gateway flags **image mismatch suspected**
    rather than reporting a ~50% BER that looks like a terrible link.
- **No secrets go on air.** The private signing key never enters the image: it
  stays in `~/.sophon/keys/` and only imgtool uses it. MCUboot holds the public
  key, in its own partition, which isn't sent. Bonding keys live in the
  settings partition, and the app has no embedded secrets. The one exposure:
  the payload isn't encrypted, so anyone receiving on the channel can rebuild
  the firmware binary itself. That's code, not credentials, and it's accepted
  for a test role.
- **MCUboot builds only.** The code is behind `CONFIG_MCUBOOT_IMG_MANAGER`. A
  UF2 build can't run as a transporter and can't measure bit errors.

## Packet: format `11`, type `0x5C`

Format `11` was the slot LORA-PROTOCOL.md § Versioning reserved for a future
format.

| Offset | Size | Field |
|---|---|---|
| 0 | 1 | type `0x5C` |
| 1 | 2 | `tx_id`: low 16 bits of the FICR id, as a sensor's `sensor_id` |
| 3 | 2 | `pseq`: packet counter mod 2^16 |
| 5 | 3 | `offset`: u24 byte offset into the image |
| 8 | 1 | `hcrc`: CRC-8 (poly `0x07`, init 0), run over the board's own 32-byte SHA-256 and then bytes 0–7 |
| 9 | n | image bytes `(offset + i) mod L`, for i = 0 … n − 1 |

- **n is the image bytes a packet carries:** the packet length minus the 9 B
  header. **The BER counts all PL × 8 bits**, the header included.
- **Packet length is the preset's motion packet length**
  (`lora_preset_full_len`), so a test packet has the same airtime as a motion
  packet. At V6 that's PL = 60 B (8 + 13 × k, k = 4): n = 51 B of image and 480
  bits compared per packet.
- **Packets go out on the sensor's schedule**, one every k × 18.4 ms. Airtime,
  duty and packet length then match the motion link, so the BER applies to it
  directly, and the gateway's noise-floor gap timing (#336) keeps working.
- **CRC off** (`packet_crc_disable = true`), on the transporter only. With an
  explicit header the receiver takes CRC on or off from the packet's header, so
  the gateway's configuration doesn't change and motion packets stay
  CRC-checked. The LoRa header has its own check, so the length is always right.

## Header damage: every bit counts

Counting header bits only when `hcrc` passes would add guaranteed-zero bits
exactly when the link is good, and bias the BER low. So the gateway recovers the
true header. Every field is known or predictable:
- `type` is the constant `0x5C`;
- `tx_id` is the transporter being measured;
- `hcrc` is recomputed from the candidate header, seeded with the gateway's hash;
- `pseq` and `offset` are `(last_pseq + Δ) mod 2^16` and
  `(last_offset + Δ·n) mod L`, from the last packet whose `hcrc` passed: the
  **anchor**.

**Δ is the number of packets the transporter sent since the anchor.** Δ = 1 is
the very next packet; Δ = 3 means two were lost in between, so Δ − 1 is added to
`lost`.

- **`hcrc` passes:** the fast path. Δ comes from `pseq`, and the packet becomes
  the new anchor.
- **`hcrc` fails:** try Δ = 1 … ⌈elapsed ÷ period⌉ + 2, at most 64 (about
  4.7 s at V6). Build each candidate's whole expected packet (header and image
  bytes) and keep the one with the fewest differing bits. The packet is
  **repaired**, and all PL × 8 bits enter the BER. A repaired packet doesn't
  become the anchor.
- **Can't be repaired:** with no anchor in the last 5 s, or a best candidate
  more than 25% wrong (unrelated data is about 50%), the packet is
  **unresolved** and left out. The record carries the count, so any remaining
  bias is visible.
- **A damaged type byte:** a packet that fails `lora_codec_decode`, has the
  test packet's exact length, and arrives while a transporter is anchored is
  tried the same way. If that fails too, it counts as `bad`, as today.
- **Image mismatch suspected**, per window: at least 10 test packets, at least
  90% of them unresolved, and SNR average ≥ 0 dB. A link that clean can't
  explain that many failed headers.

## Pass duration

L = `ih_hdr_size + ih_img_size` = 219,788 B for 2.32.0: the MCUboot build's
`zephyr.bin`, which includes the 512 B header space. The signed file's extra
336 B are the TLVs (256 B signature, 32 B hash, 32 B key hash, 16 B of TLV
headers), which aren't sent. Airtime uses LORA-PROTOCOL.md § LoRa variables
with CRC = 0; the period is k × 18.4 ms.

V6: PL = 60, n = 51, packets = ⌈219,788 ÷ 51⌉ = 4,310. Tsym = 0.256 ms,
Tpre = 3.14 ms, Npl = 8 + ⌈(480 − 28 + 28) ÷ 28⌉ × 5 = 98, so airtime =
28.2 ms. Period 73.6 ms, so **one pass takes 317 s, about 5.3 min**, and then
the transporter starts again.

| Preset | n | Packets | Airtime | Period | One pass |
|---|---|---|---|---|---|
| V0 | 180 | 1,222 | 74.3 ms | 184.0 ms | 3.7 min |
| V1 / V5 / V6b | 129 | 1,704 | 56.4 / 100 / 100 ms | 184.0 ms | 5.2 min |
| V3 / V4 / V6 | 51 | 4,310 | 28.2 / 37.4 / 28.2 ms | 73.6 ms | 5.3 min |
| V3b | 25 | 8,792 | 18.0 ms | 36.8 ms | 5.4 min |
| V5b | 64 | 3,435 | 59.0 ms | 92.0 ms | 5.3 min |

The BER doesn't need a full pass. A 10 s window at V6 compares about 136
packets × 480 bits = 65,280 bits, so one error is 0.0015%; a 1 s window
compares about 6,500. A full pass covers all L × 8 = 1,758,304 image bits, plus
4,310 × 72 header bits.

LQ, by comparison, is per window and counts samples, so at V6 it moves in steps
of about 0.7%: one lost packet is 4 of about 543 samples.

## What "raw" means

These are the bits after the radio's own decoding, with only the CRC removed.

- **V4 is the only preset where the radio corrects errors.** It runs at CR 4/7,
  Hamming(7,4), which fixes one bit per 4-bit nibble, so its figure is the
  residual BER after correction.
- **Every other preset is CR 4/5:** one parity bit per nibble, which detects but
  corrects nothing, so the figure is the demodulated channel's BER.
- **The one exception:** the first 8 symbols (the LoRa header block) always go
  at 4/8. At SF7 that block holds only the 20-bit LoRa header. At SF8 (V5, V5b,
  V6b) it also carries the first nibble of the type byte: 4 of 480 bits.
- **What 4/7 can't buy:** it turns *damaged* packets into good ones when each
  codeword has at most one error. It does nothing for *lost* packets: a missed
  preamble, a failed LoRa header, a signal below sensitivity, a collision. Its
  best case is LQ = received ÷ sent, both measured at 4/5. A "fixable at 4/7"
  counter was considered and left out.

## Firmware

- **Role:** `SOPHON_CONFIG_ROLE_TRANSPORTER = 4` and `SOPHON_ROLE_TRANSPORTER`.
  It needs the radio only, and Auto never picks it. A transporter doesn't arm
  its IMU, as a forced gateway doesn't. Config status **bit 6, "can
  transport"**, is set on an MCUboot build that read its own image header; the
  app offers the role only then.
- **`src/lora_ber.c`:** the packet codec, the seeded CRC-8, the bit compare and
  the header repair. Plain C99 with no Zephyr headers, host-tested by
  `scripts/test-codec.sh` like `lora_codec.c`. The image is read through a
  callback, so the test can supply a fake one.
- **`src/lora_image.c`:** reads the running image's extent and hash, and serves
  reads mod L, for both the transporter and the gateway.
- **Transporter:** a thread beside the sensor's. It encodes, sends with
  `lora_send()` every k × 18.4 ms, and confirms the image on its first send, as
  a sensor does.
- **Gateway:** a type `0x5C` packet goes to the BER handler before
  `lora_codec_decode`. RSSI, SNR and the time of the last packet keep their
  shared accounting, so the LoRa Link record's RSSI, SNR, noise and heard
  figures stay right; its samples and missing stay 0.
- **Console**, per window when any test packet was heard:

  ```
  lora ber: tx 1A2B; 135 pkts (1 repaired, 0 unresolved), 2 lost; 3 damaged; 14 / 64800 bits = 0.0216%
  ```

- **LoRa BER characteristic** `C6560008-…`, read and notify, 20 bytes;
  PROTOCOL.md § LoRa BER frame. It's built in the same stats tick as the LoRa
  Link record, just before it, and carries the same `window` number so the app
  can pair the two.

## App

- **One LoRa link section, adapted to what the gateway hears** (from the boards
  it names: the locked sensor, the transporter heard). With a transporter, Bit
  error rate replaces Link quality as the headline and its chart (the last 30
  windows); the rows add the transporter's name, **Images**, damaged and lost
  packets, headers repaired / unresolved, and a **This session** row with
  running totals. Margin, RSSI, SNR, noise, last packet and age are shared. A
  sensor and a transporter heard together are flagged: one channel each.
- **Only what applies to the board's role:** a sensor or transporter has no
  Motion, Frames or transmit counters (it sends over LoRa), and points to its
  gateway instead; a gateway hearing only a transporter drops them too. An
  unknown role shows everything, as before.
- **Check images** reads the slot-0 hash of the gateway and of the transporter
  (found among discovered boards by its `Sophon-XXXX` name) over SMP, the same
  read the firmware updater uses (#357). It shows Match, Mismatch, or
  Transporter not reachable, with the time. The gateway's *mismatch suspected*
  flag overrides an older Match. With different images no header passes, so
  the gateway names the transporter from its headers, unverified (2.37.0);
  the check runs on that name.
- **A BER walk is gated on the check.** While a transporter is heard, Start
  walk-test recording needs a current Match; otherwise it is disabled with the
  reason.
- **Config:** a Transporter role, offered when status bit 6 is set.
- **Walk-test CSV, format 3:** `ber_packets`, `ber_damaged`, `ber_lost`,
  `ber_bit_errors`, `ber_bits`, `ber_repaired`, `ber_unresolved`,
  `ber_mismatch_suspected`, from the BER record with the row's `window`; empty
  otherwise. A `transporter` preamble line gives the latest image check.

## Verification

1. `scripts/test-codec.sh` runs the codec and BER host tests clean under
   ASan/UBSan.
2. The MCUboot and UF2 builds both build; the UF2 build leaves the transporter
   out.
3. **Bench, same image on both boards:** set one to Transporter from the app.
   Check images shows Match; the gateway's BER is about 0 at the desk, with no
   mismatch suspected.
4. **Weakened link** (transporter at −9 dBm, distance, obstruction): damaged
   packets, bit errors and repaired headers appear, `unresolved` stays near 0,
   and packets + lost matches what was sent.
5. **Image check:** a different image on the transporter shows Mismatch in the
   app, and the gateway raises *mismatch suspected* within a window. With the
   transporter off, Check images shows Not reachable.
6. **No regression:** back in the sensor role, LoRa Link LQ and the Motion
   stream are unchanged and motion packets are still CRC-checked.
7. **App:** the DEBUG self-check passes; a simulator screenshot of the section;
   deployed to the phone; a short recording's CSV has the `ber_*` columns;
   `swift-reviewer` on the `ios/` diff.
