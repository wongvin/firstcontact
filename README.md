# firstcontact

Attempt to make contact with an autonomous AI being.

That started as a web page. It is now a monorepo of several small projects that
grew out of it — a web app, two iOS apps, embedded firmware, and a local backend.

## Projects

### [`webapp/`](webapp/) — the web app

Next.js 16 / React 19 / Tailwind 4, deployed to Vercel. Serves the homepage, the
daily news reader with voice playback (`/news`), and the DigiKey / Mouser /
Transcripts tool pages.

Manual test cases in [`webapp/TEST-PLAN.md`](webapp/TEST-PLAN.md).

### [`ios/`](ios/) — two native iOS apps

- **[`FirstContact/`](ios/FirstContact/)** — news reader with keyword filtering, a
  30-day work-summary panel, and device-to-device sync of keywords and messages
  over Multipeer Connectivity.
- **[`Sophon/`](ios/Sophon/)** — viewer for the Sophon motion sensor, plus a
  **simulator mode** that turns a spare iPhone or iPad into a stand-in Sophon so
  app work does not need the board.

Swift + SwiftUI throughout. Personal use, signed with a free Apple ID — not
distributed via TestFlight or the App Store.

### [`zephyr/`](zephyr/) — embedded firmware

Zephyr RTOS applications, built against the shared toolchain at `~/zephyrproject`
rather than a west workspace inside this repo. Currently one app:
**[`sophon/`](zephyr/sophon/)**, a BLE motion peripheral on a Seeed XIAO nRF52840
Sense Plus, streaming 6-axis IMU data paced by the sensor's data-ready interrupt.

### [`api/`](api/) — local backend

A FastAPI service on `localhost:8001` that enriches the webapp: part-pricing
proxies for DigiKey and Mouser, the Claude Code transcript timeline, and the
homepage's 30-day summary panel. **Deliberately local-only** — it is never
deployed, and the webapp degrades gracefully without it.

### [`postman/`](postman/) — API collections

Postman collections and environments for the DigiKey and Mouser APIs, used while
building the pricing proxies above.

## Sophon spans two targets

[`zephyr/sophon/`](zephyr/sophon/) (firmware) and [`ios/Sophon/`](ios/Sophon/)
(app) are **one logical project**, not two — one issue prefix, one branch per
change, even when a change touches both folders.

The wire contract between them is
[`zephyr/sophon/PROTOCOL.md`](zephyr/sophon/PROTOCOL.md), which both sides
implement and which now has three implementers: the firmware, the app's decoder,
and the simulator's encoder.

## Getting set up

Nothing here needs all of it — each target stands alone. Install what the target
you are touching needs.

### Everything

```bash
brew bundle          # from the repo root; see Brewfile for what and why
```

Four tools: `shellcheck`, `tio`, `ruff`, `swiftlint`. Deliberately *not* in there
are `clang-format` and `clangd`, which ship with Xcode (`xcrun -f clang-format`)
and cost ~1.5 GB to duplicate via `llvm`; `jq`, which macOS ships at
`/usr/bin/jq`; and `arm-zephyr-eabi-gdb`, which comes with the Zephyr SDK.

### [`webapp/`](webapp/) — Node

```bash
cd webapp && npm install && npm run dev
```

`eslint` and `typescript` are devDependencies, so `npm run lint` needs no global
install.

### [`api/`](api/) — Python

```bash
pip install -r api/server/requirements.txt
```

### [`ios/`](ios/) — Xcode

Xcode, and a free Apple ID for signing. Device setup — trusting the Mac,
Developer Mode, and the ~7-day free-signing expiry — is in
[ios/CLAUDE.md](ios/CLAUDE.md).

### [`zephyr/`](zephyr/) — the one that is not a package manager away

The firmware builds against a **shared Zephyr workspace at `~/zephyrproject`**
and the **Zephyr SDK**, neither of which this repo vendors or installs. Follow
Zephyr's [getting started
guide](https://docs.zephyrproject.org/latest/develop/getting_started/index.html),
then build with the wrapper script — never bare `west`:

```bash
zephyr/sophon/scripts/build.sh
```

Two things that will bite otherwise, both explained in
[zephyr/CLAUDE.md](zephyr/CLAUDE.md) rather than repeated here:

- **`west` cannot run from inside this repo.** It walks *up* from `$PWD` looking
  for a `.west/` marker and finds nothing. The wrapper exports `ZEPHYR_BASE` and
  activates the workspace venv, which is what makes a freestanding app buildable.
- **This repo does not pin the Zephyr revision.** The firmware follows whatever
  `~/zephyrproject` happens to be at, so a `west update` elsewhere can change its
  dependencies with no record here. `CMakeLists.txt` guards a minimum of **4.4**
  and fails at configure time below that — but only on the version, not on
  anything else that moved.

Flashing over SWD additionally needs a CMSIS-DAP probe; OpenOCD comes with the
SDK. See [zephyr/sophon/BOOTLOADER.md](zephyr/sophon/BOOTLOADER.md).

## Conventions

Repo-wide conventions — issue tracking, branching, commit hygiene — are in
[CLAUDE.md](CLAUDE.md). Each target has its own `CLAUDE.md` for the things
specific to it (Vercel deploys, free-signing quirks, the Zephyr toolchain).

Every non-trivial change is tracked by an issue on
[Project 1](https://github.com/users/wongvin/projects/1), titled with the target
it concerns (`webapp:`, `iOS:`, `sophon:`). Project-wide changelog in
[`ChangeLog.md`](ChangeLog.md).

> **Note:** `web/`, the original static homepage on GitHub Pages, was retired in
> #88 and superseded by `webapp/`. Links to it elsewhere are stale.
