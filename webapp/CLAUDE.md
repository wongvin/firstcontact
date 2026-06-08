@AGENTS.md

# webapp target — conventions

The primary First Contact web app: a **Next.js 16 / React 19 / Tailwind 4** site
deployed to **Vercel** (this replaced the old static `web/` + GitHub Pages target,
issue #88). It serves three things:

- **Homepage** (`app/page.tsx`) — the unified landing (hero / quote /
  changes-made-this-week / 30-day summary / tool links + a "Latest News" link).
  A client component; ported 1:1 from the former `web/index.html`.
- **News reader** (`app/news/**`) — `/news`, `/news/health`, `/news/economy`.
  Headlines are fetched **server-side** from `gnews.io` using `GNEWS_API_KEY`
  (so this target needs a Node runtime — it can't be statically hosted).
  "Read Aloud" uses the browser `SpeechSynthesis` API (`app/news/TTSButton.tsx`).
- **Tool pages** (`public/digikey-search.html`, `mouser-search.html`,
  `transcripts-viewer.html`) — self-contained static HTML served verbatim by
  Next at `/digikey-search.html` etc. Not React; don't rewrite them.

> ⚠️ Next 16 has breaking changes vs. older versions (see [AGENTS.md](AGENTS.md)).
> Consult `node_modules/next/dist/docs/` before touching framework wiring.

## Local backend (`localhost:8001`)

The homepage's 30-day-summary panel and the three tool pages enrich themselves
from the local FastAPI backend (see [../api/server/README.md](../api/server/README.md))
when it's running, and degrade gracefully when it isn't. The news reader does
**not** use this backend — it calls `gnews.io` directly. `api/server` CORS allows
`http://localhost:3000` (dev) and `*.vercel.app` (deploys).

## Environment

`GNEWS_API_KEY` (from https://gnews.io) — set in `.env.local` for dev and as a
Vercel project env var for deploys. See `.env.local.example`. Never commit the key.

## Data source for project/task state

The "changes made this week" panel reads closed GitHub issues directly from the
browser — no auth, CORS open, 60 req/hr per IP is plenty:

```
https://api.github.com/repos/wongvin/firstcontact/issues?state=closed
```

`/issues` returns issues **and** PRs — always filter out entries with `pull_request`
set. Don't reach for GraphQL (needs a token) or a pre-generated `tasks.json` —
both are over-engineered at this scale.

The 30-day summary goes through the local backend instead so the Gemini key stays
server-side, and the prose is cached in `localStorage` with a 24-hour TTL so visits
while the backend is down still show the last-known-good summary.

## Rendering API-sourced text

Render external-API text (titles, bodies, quotes, authors) as JSX text children
(`{value}`) — React escapes these like `textContent`. Never use
`dangerouslySetInnerHTML` with API strings.

## Test plan

[TEST-PLAN.md](TEST-PLAN.md) covers manual test cases for this target. Update it in
the same commit as feature changes — add a new section per issue; don't delete
sections for shipped features (they're regression coverage).
