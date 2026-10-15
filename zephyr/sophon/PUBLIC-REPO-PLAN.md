# sophon: publish as its own open-source repository (#327)

Plan for #327, saved on 2026-10-14 and not yet approved for implementation. The design record for the public spin-off; it stays in this repository and is not exported.

## Context

Sophon (three Zephyr apps, an iOS app, a LoRa relay, and its hardware and protocol docs) is self-contained but lives in this monorepo, which is public with **no `LICENSE`**: visible to everyone, licensed to no one. The goal is a **new public repo, `wongvin/sophon`**, under an open-source licence, that the public carries on.

**Decided:**
- **This repo keeps its Sophon work.** The two copies continue **independently**; nothing flows either way.
- **Licensing:** **MIT** for all code, **CC BY 4.0** for docs.
- **History:** the public repo starts with a **fresh initial commit**, a cleaned import of the tree.
- **After the spin-off, this repo becomes private.** So the public repo must stand alone: no links into this repo, and its `#NNN` references explained as belonging to the original private repo.

From exploration, the starting point:
- **Nothing secret** is tracked or ever was.
- **What needs work:**
  - personal identifiers;
  - about a dozen cross-tree links and two sibling build dependencies;
  - monorepo workflow text;
  - the public-project scaffolding (licences, README, CI, contribution files).

**This plan is saved in this repo** as `zephyr/sophon/PUBLIC-REPO-PLAN.md`, a design record like `LORA-PLAN.md`. It is **not** exported: it stays here and goes private with the repo.

## Workflow

1. Branch `327-sophon-public` here. Status → In progress, Start date = today. Update #327's body with the decisions above.
2. Save this plan as `zephyr/sophon/PUBLIC-REPO-PLAN.md`, first thing on the branch.
3. Build the export tree in a working copy outside this repo, `~/repos/sophon`, following "Export" below. Nothing is pushed yet.
4. Run the audit gate and the local verification. **Pause:** you review the exported tree before anything goes public, including **the flagged issue-reference rewrites**, each shown next to its original.
5. On your OK: create `wongvin/sophon` (public), push the initial commit, confirm CI.
6. This repo's PR: the pointer docs, the plan, ChangeLog. The usual In review → consent → ship.
7. **Separate, explicit consent:** make this repo private.

Steps 5 and 7 are outward-facing and hard to undo, so each gets its own go-ahead. Plan approval doesn't cover them.

## Export: layout of `wongvin/sophon`

```
LICENSE                  MIT (GitHub detects it); copyright "Vincent Wong and Sophon contributors"
LICENSES/MIT.txt, LICENSES/CC-BY-4.0.txt
REUSE.toml               docs (*.md) and icons → CC-BY-4.0; everything else MIT
THIRD-PARTY.md           what a firmware binary contains and its licences (see Licensing)
README.md  CONTRIBUTING.md  CODE_OF_CONDUCT.md  SECURITY.md  CHANGELOG.md  CLAUDE.md
west.yml                 pins Zephyr da0718ca0d52 (the version built here), name-allowlist of used modules
.clang-format  .gitignore  .pre-commit-config.yaml
.github/workflows/ci.yml   .github/ISSUE_TEMPLATE/*   .github/pull_request_template.md
firmware/    ← zephyr/sophon/      (project(sophon) unchanged, so build-mcuboot/sophon/ paths hold)
installer/   ← zephyr/sophon-installer/
dumper/      ← zephyr/sophon-dumper/
ios/         ← ios/Sophon/   (.xcodeproj moves unchanged: one synchronized group, no ../ paths)
.claude/agents/swift-reviewer.md, swift-reviewer-fixtures.md   (repathed)
```

**Excluded:**
- `PUBLIC-REPO-PLAN.md`;
- untracked junk (`.DS_Store`, the empty `installer/cmake/`);
- build trees.

## Export: changes to the copied tree

**Re-pathing:**
- **Markdown links:** the ~12 that cross trees, e.g. `../../ios/Sophon/` → `../ios/` and `../sophon-installer/` → `../installer/`. The full list is in the coupling report.
- **Path mentions in comments and docs:** `zephyr/sophon/…` → `firmware/…`, `ios/Sophon/…` → `ios/…`, for example in `frame.h`, `version.h` and the `SophonProtocol.swift` headers.
- **Sibling dependencies:**
  - `installer/scripts/common.sh:16`: `../sophon` → `../firmware`;
  - `installer/CMakeLists.txt:32-41`: the default `SOPHON_MCUBOOT_BIN` path and hint;
  - the dumper and installer `common.sh` and `CMakeLists.txt` header comments.
- **`.gitignore`:** `zephyr/*/build*` → `*/build/`, `*/build-*/`, `*/compile_commands.json`. Keep the keys block (`*.pem`, `*.p8`, `*.key`, `!*.pub.pem`) and merge in `ios/.gitignore`.
- **Pre-commit hook:**
  - `files:` becomes `^(firmware|installer|dumper)/src/.*\.(c|h)$`;
  - the entry uses `clang-format` from PATH, falling back to `xcrun`;
  - the stale "ruff/shellcheck" comment goes.

**Personal identifiers:**
- **Signing and bundle ID:** `ios/Sophon.xcodeproj` gets an `.xcconfig`:
  - `DEVELOPMENT_TEAM = ` (empty);
  - `PRODUCT_BUNDLE_IDENTIFIER = $(SOPHON_BUNDLE_ID)`, defaulting to a neutral `org.example.Sophon`;
  - `#include? "Signing.local.xcconfig"`, gitignored, for each developer's own values. This is the pattern FirstContact uses with `Secrets.xcconfig`.
- **Logger subsystem:** the 6 `Logger(subsystem: "com.vwong.Sophon")` calls become `Bundle.main.bundleIdentifier ?? "Sophon"`.
- **Device names:** `violav17` and "this project's iPad mini 5" become generic examples (`ios/README.md`, `deploy-device.sh:97`).
- **`firmware/scripts/ble-find.py:19-20`:** drop the default host UUID and board MAC. Address comes from `SOPHON_BLE_ADDR` or a scan.
- **Home paths:** `file:///Users/vwong/zephyrproject/...` and `~/repos/firstcontact` in the plan docs become `~/zephyrproject` or relative paths.
- **`BOOTLOADER.md:252-310`:** the owner's backup inventory (Time Machine, disk, specific filenames) becomes a generic "record your backups like this" section using one example board.
- **Board IDs** (`86F0`, `01A7`, …) **stay**. They are 16-bit FICR fragments, used as test vectors and in records of what was measured. README explains they're example boards.
- **KEYHASH `2133b06f…`:** make it configurable in `dumper/scripts/capture.py` (`SOPHON_KEYHASH`), keeping the hash as a named example, not the default. In docs, describe it as "the original project's key".

**Monorepo workflow text:**
- **`CLAUDE.md` (new):** contributor conventions only, merged from `zephyr/CLAUDE.md` (toolchain, build, flash, console, verification bar, design records) and the Sophon-applicable parts of `ios/CLAUDE.md` (free signing, simulator screenshot, swift-reviewer, devicectl codes). **None** of Project 1, `/ship`, commit-consent gates, or FirstContact or Gemini.
- **Workspace text:** replace `zephyr/CLAUDE.md`'s "freestanding, not pinned" rationale with the `west.yml` setup.
- **Plan docs** (`ORIGINAL-PLAN`, `UPDATED-PLAN`, `SIMULATOR-PLAN`, `SCAN-RESPONSE-PLAN`, `LORA-PLAN`, `LORA-UPDATED-PLAN`, `UF2-MIGRATION`): **keep as historical records.** Add one header line: "Written in the original private repository; the workflow steps refer to its process." Fix their personal paths and remove their issue numbers as above. Leave the rest of the text alone.
- **`#NNN` issue references (~560 across 77 files): removed.** The text around each should already describe the issue and how it was resolved, so the number adds nothing once this repo is private. A script inventories every reference, with file, line, number and its sentence, and sorts each into one of two kinds:
  - **Self-explanatory:** a tag such as `(#303)` or `#319:` on a sentence that already says what happened. **Delete the number.** This is the bulk.
  - **Leaning on the number:** `the #263 defect`, `as #237 found`, `fixed in #247`, `see #268`, or a bare `(#NNN)` doing the explaining. **Flag it**, and rewrite the clause to state the substance, taken from that issue's title, body and close summary here. For example, "the #263 defect" becomes "the defect where a read still in flight was shown as 'cannot report'".
  - The flagged list goes into the step-4 review, with each rewrite next to the original, so you can check none lost its meaning.
- Code comments, docs, plan docs and test names are all covered. **Not** covered: `#include`, `#define`, `#if`, Markdown headings, colours, and numbers that aren't issue references. The script matches only `#` followed by 2–3 digits in issue-like positions, and its hit list is reviewed, not applied blindly.
- **Rewording:**
  - `ios/README.md:7` "personal use only";
  - the three passages saying "this repo is public with no LICENSE" (`HARDWARE.md:72-73`, `BOOTLOADER.md:253`, `kicad-netlist.py:43-45`);
  - `Info.plist:6` and the other "Same arrangement as FirstContact" comments.

**Scripts for a new contributor and for CI:**
- `common.sh:38`: source `$WORKSPACE/.venv/bin/activate` only if it exists, so CI's `west` on PATH works.
- `common.sh` workspace default: `SOPHON_ZEPHYR_WORKSPACE`, else the parent of the repo if it holds `.west` (a `west init -l` checkout), else `~/zephyrproject`.

## Licensing

- **`LICENSE`:** MIT. `LICENSES/` plus `REUSE.toml`, following the REUSE spec.
- **Per file:** SPDX headers on every code file, `SPDX-License-Identifier: MIT` plus the copyright line. That covers `.c`, `.h`, `.swift`, `.sh`, `.py`, CMake, Kconfig, `.conf`, `.overlay` and the devicetree binding YAMLs, whose `Apache-2.0` header and holder-less copyright are corrected. Docs and icons are licensed through `REUSE.toml`, not per file.
- **`THIRD-PARTY.md`:** a firmware binary contains Zephyr, MCUboot, mbedtls/TF-PSA-Crypto and CMSIS (Apache-2.0), nrfx (BSD-3-Clause) and loramac-node (Revised BSD). Anyone **distributing binaries** must ship those licences. Also records the facts taken from other projects: the Meshtastic pin map (GPL-3.0; facts only), MCUboot trailer constants and the UF2 format (MIT), and Seeed schematics (CC BY-SA 4.0; facts, nothing reproduced).
- **No binary releases** at first: a prebuilt image or installer would embed a signing key. README explains generating your own (`imgtool keygen -k ~/.sophon/keys/... -t rsa-2048`).

## Public-project files

- **`README.md`:**
  - what Sophon is and the hardware to buy: XIAO nRF52840 Sense Plus; XIAO nRF52840 & Wio-SX1262 kit; Raspberry Pi Debug Probe (optional);
  - setup, through `west init -l` with `west.yml` or an existing workspace;
  - key generation; build, flash (OTA, SWD, UF2 migration) and the app;
  - § History: developed in a private repository before this one; the design records under `firmware/` and `ios/` carry its reasoning.
- **`CONTRIBUTING.md`:**
  - the verification bar from zephyr/CLAUDE.md: both build modes, hardware for firmware changes, simulator screenshot and swift-reviewer for app changes;
  - one ChangeLog entry per change; DCO sign-off.
- **Community files:** `CODE_OF_CONDUCT.md` (Contributor Covenant 2.1); `SECURITY.md` (private reporting via GitHub advisories); issue templates (bug, hardware report, feature); a PR template.
- **`CHANGELOG.md`:** starts fresh with one entry, "v2.27.0: first public release, imported from private development", summarising the features. The 55 private entries aren't carried over.
- **First tag:** `v2.27.0`, source only, matching the firmware `VERSION`.

## CI (`.github/workflows/ci.yml`)

- **`firmware` (ubuntu):**
  - `zephyrproject-rtos/action-zephyr-setup` from `west.yml`, with SDK 1.0.1;
  - a throwaway key from `openssl genrsa` into `$RUNNER_TEMP`, passed as `SOPHON_SIGNING_KEY`;
  - build MCUboot mode, then UF2 mode, then the installer (after MCUboot mode), then the dumper;
  - artefacts not uploaded as flashable.
- **`host-tests`:** `firmware/scripts/test-codec.sh` (cc with ASan and UBSan).
- **`lint`:** clang-format `--dry-run --Werror` over the src trees, shellcheck over `*/scripts/*.sh`, `reuse lint`.
- **`ios` (macOS):** `xcodebuild -project ios/Sophon.xcodeproj -scheme Sophon -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`, plus `swiftlint lint` in `ios/`. Needs an Xcode 26 runner (deployment target 26.0). If the hosted runners don't offer Xcode 26 yet, mark this job `continue-on-error` and note it in README.

## This repo

- `README.md` and `zephyr/sophon/README.md`: a pointer to `wongvin/sophon`. Nothing removed.
- `zephyr/sophon/PUBLIC-REPO-PLAN.md`, this plan.
- **ChangeLog** `docs:` entry for the spin-off.
- **Open `sophon:` issues** (#313, #314, #304, #326) stay here, with the owner's copy; nothing is recreated in the public repo.
- **Memory:** a project note that `wongvin/sophon` exists and evolves independently.
- **Go private (step 7):** `gh repo edit wongvin/firstcontact --visibility private --accept-visibility-change-consequences`. Before that, confirm:
  - **Vercel:** not Git-connected, so the webapp deploy is unaffected.
  - **Memory sync:** the memory repo is separate.
  - **Public links in:** nothing public links here. The audit gate already ensures `wongvin/sophon` doesn't.

## Audit gate (before the first push)

A script, run over the export tree, that must print **no hits**:
- `9Y8886KJR8`, `com.vwong`, `violav17`, `962CDEDA`, `EC:C6:E9`;
- `/Users/vwong`, `hk.vwong`, `repos/firstcontact`, `wongvin/firstcontact`;
- `Project 1`, `In review`, `commit consent`, outside the plan docs' historical header notes;
- issue references: `#` followed by 2–3 digits in issue-like positions, with the same exclusions as the removal script;
- `BEGIN .*PRIVATE KEY`.

Plus `reuse lint` and `git status` showing nothing ignored-but-needed. The script is kept in this repo as `zephyr/sophon/scripts/public-audit.sh`.

## Verification

1. **Gate:** the audit script prints nothing; `reuse lint` passes.
2. **Fresh clone, this Mac:** clone the export into a temp dir and follow README only. Use a new `west init -l` workspace or the existing one, and a throwaway key. Then:
   - firmware in MCUboot and UF2 modes;
   - installer and dumper;
   - `test-codec.sh`;
   - the iOS simulator build with **no** `Signing.local.xcconfig` (it must build unsigned);
   - a device build with one.
3. **Hardware:** build the public tree with the project key (`SOPHON_SIGNING_KEY`) and OTA 86F0 (sensor) and 0FAA (gateway). Then an app session: motion relayed, Charger row, LoRa link section. This shows the re-pathed tree works on real boards.
4. **CI green** on the first push: every job, or iOS marked as above.
5. **Rendering:** on github.com, open README, PROTOCOL.md and one plan doc. There should be no issue numbers, and no link may lead to `wongvin/firstcontact`.
6. **After going private:** check in a private window that the `wongvin/sophon` README and docs still read whole, with no broken links.
