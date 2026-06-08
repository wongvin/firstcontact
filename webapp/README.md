# webapp — First Contact (Next.js, Vercel)

The primary First Contact web app: a [Next.js](https://nextjs.org) 16 / React 19 /
Tailwind 4 site deployed to Vercel. It serves the unified homepage, the daily
news reader with voice playback (`/news`), and the static tool pages
(DigiKey / Mouser / Transcripts) under `public/`.

See [CLAUDE.md](CLAUDE.md) for target conventions and [TEST-PLAN.md](TEST-PLAN.md)
for manual test cases.

## Getting started

```bash
cp .env.local.example .env.local   # then fill in GNEWS_API_KEY (https://gnews.io)
npm install
npm run dev                         # http://localhost:3000
```

The 30-day-summary and tool pages enrich themselves from the local FastAPI
backend at `localhost:8001` when it's running (see
[../api/server/README.md](../api/server/README.md)); they degrade gracefully
when it isn't.

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
