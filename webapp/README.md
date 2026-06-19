# webapp — First Contact (Next.js, Vercel)

The primary First Contact web app: a [Next.js](https://nextjs.org) 16 / React 19 /
Tailwind 4 site deployed to Vercel. It serves the unified homepage, the daily
news reader with voice playback (`/news`), and the static tool pages
(DigiKey / Mouser / Transcripts) under `public/`.

See [CLAUDE.md](CLAUDE.md) for target conventions and [TEST-PLAN.md](TEST-PLAN.md)
for manual test cases.

## Getting started

**Requires Node.js ≥ 20.9** (Next.js 16 refuses to start on anything older).
Check with `node -v`; if you're below that — common on WSL, whose system Node
is often v18 — see [Troubleshooting](#troubleshooting) before installing.

```bash
cp .env.local.example .env.local   # then fill in GNEWS_API_KEY (https://gnews.io)
npm install
npm run dev                         # http://localhost:3000
```

The 30-day-summary and tool pages enrich themselves from the local FastAPI
backend at `localhost:8001` when it's running (see
[../api/server/README.md](../api/server/README.md)); they degrade gracefully
when it isn't.

## GitHub treemap dataset (`/ghstars`)

The `/ghstars` treemap fetches `public/treemap-data/repos.json` (~9.4 MB) at
runtime. That folder is **gitignored** and never committed, so you must supply
the dataset locally. Download it from the upstream
[`xiaoxiunique/1k-github-stars`](https://github.com/xiaoxiunique/1k-github-stars)
repo (run from `webapp/`):

```bash
mkdir -p public/treemap-data
curl -L https://raw.githubusercontent.com/xiaoxiunique/1k-github-stars/main/data/repos.json \
  -o public/treemap-data/repos.json
```

Without it, `/ghstars` renders a graceful "dataset unavailable" empty state
(this is also why the route is empty on Vercel).

## Build / lint

```bash
npm run lint
npm run build
```

## Deploy

Hosted on Vercel with **Root Directory = `webapp`** and a `GNEWS_API_KEY`
environment variable. News headlines are fetched server-side from `gnews.io`,
which is why this target needs a Node runtime (Vercel) rather than static
hosting.

## Troubleshooting

### WSL: `npm run dev` fails with "Cannot find native binding" or a Node version error

The repo runs fine on macOS but breaks on a fresh WSL setup. Both symptoms below
have the same root cause: **WSL's default system Node is too old** (usually
v18, which ships with npm 9). Next.js 16 requires Node ≥ 20.9, and npm 9 hits an
[optional-dependency bug](https://github.com/npm/cli/issues/4828) that silently
skips installing Tailwind's native binding (`@tailwindcss/oxide-linux-x64-gnu`).

Symptoms:

```
You are using Node.js 18.x.x. For Next.js, Node.js version ">=20.9.0" is required.
```
```
./app/globals.css
Error: Cannot find native binding ...
Caused by: Cannot find module '@tailwindcss/oxide-linux-x64-gnu'
```

**Fix — upgrade Node, then reinstall cleanly:**

1. Install a recent Node via [nvm](https://github.com/nvm-sh/nvm) (user-local,
   no `sudo`):

   ```bash
   curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
   source ~/.bashrc
   nvm install 22 && nvm alias default 22
   node -v                              # should print v22.x (≥ 20.9)
   ```

2. Reinstall dependencies from scratch so the correct native binding lands
   (the old npm-9 `package-lock.json`/`node_modules` are corrupt for this repo):

   ```bash
   rm -rf node_modules package-lock.json .next
   npm install
   npm run dev
   ```

   > Restore the committed lockfile afterward (`git checkout -- package-lock.json`)
   > so you don't commit npm-version churn — `node_modules` is already correct.

Notes:

- Do **not** try to fix this by adding `"node"` to `package.json` dependencies —
  the npm `node` package is a userland shim, not your runtime, and it corrupts
  the install.
- Non-interactive shells (CI scripts, some editor/agent terminals) don't
  auto-load nvm and may still default to the old Node. Prefix such commands with
  `export NVM_DIR="$HOME/.nvm" && . "$NVM_DIR/nvm.sh" && nvm use 22`.
