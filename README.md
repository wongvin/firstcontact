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
