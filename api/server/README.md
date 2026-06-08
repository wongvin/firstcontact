# Part-pricing proxy + transcript viewer + 30-day summary

Single local FastAPI backend serving four frontends in the Vercel-hosted `webapp/` target:

- [`webapp/public/digikey-search.html`](../../webapp/public/digikey-search.html) — `/digikey/pricing`
- [`webapp/public/mouser-search.html`](../../webapp/public/mouser-search.html) — `/mouser/pricing`
- [`webapp/public/transcripts-viewer.html`](../../webapp/public/transcripts-viewer.html) — `/claudecode/timeline`
- [`webapp/app/page.tsx`](../../webapp/app/page.tsx) (homepage) — `/summary/30days` (the 30-day work-summary panel; issue #74)

Holds DigiKey OAuth2 credentials, the Mouser API key, and the Google AI Studio (Gemini) key in one local `.env` so none of them ship to the frontend.

Consolidates the previous `api/digikey/server/` and `api/mouser/server/` directories per issue #26. Per-feature logic still lives in dedicated client modules (`digikey_client.py`, `mouser_client.py`, `claudecode_client.py`, `summary_client.py`) — only the routing layer is shared.

## Setup

```bash
cd api/server
cp .env.example .env
# Edit .env and fill in:
#   DIGIKEY_CLIENT_ID, DIGIKEY_CLIENT_SECRET    (from https://developer.digikey.com)
#   MOUSER_API_KEY                              (from https://www.mouser.com/api-hub/)
#   GEMINI_API_KEY                              (from https://aistudio.google.com/apikey)

python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## Run

```bash
uvicorn main:app --port 8001
```

The server listens on `http://localhost:8001`. CORS is allowed for:
- `http://localhost:3000` (Next.js dev server for `webapp/`)
- `http://localhost:5500` (VS Code Live Server default)
- `http://localhost:8080` (e.g. `python -m http.server 8080`)
- `https://*.vercel.app` (Vercel production + preview deploys, via `allow_origin_regex`)
- `https://wongvin.github.io` (legacy GH Pages origin; kept harmless)

## Endpoints

### `GET /health`

```
{ "status": "ok" }
```

### `GET /digikey/pricing?manufacturer_part_number=<MPN>`

```bash
curl 'http://localhost:8001/digikey/pricing?manufacturer_part_number=STM32F407VGT6'
```

Returns volume-tier pricing from DigiKey's ProductPricing v4 API. Picks the second-to-last tier as the headline.

### `GET /mouser/pricing?manufacturer_part_number=<MPN>`

```bash
curl 'http://localhost:8001/mouser/pricing?manufacturer_part_number=NE555P'
```

Returns volume-tier pricing from Mouser's V1 PartNumberSearch API. Same headline tier selection rule (`tiers[-2]`) for UX parity with the DigiKey route.

Both routes share the same normalized response shape:

```json
{
  "manufacturer_part_number": "<MPN>",
  "digikey_part_number": "...",          // present on /digikey/pricing
  "mouser_part_number": "...",            // present on /mouser/pricing
  "currency": "USD",
  "unit_price": 7.12,
  "tier_quantity": 1000,
  "tiers": [{ "quantity": 1, "unit_price": 9.34 }, ...]
}
```

### `GET /summary/30days`

```bash
curl http://localhost:8001/summary/30days
```

LLM-generated prose summary (strictly under 50 words) of closed-issue activity over the last 30 days. Fetches closed issues from `api.github.com/repos/wongvin/firstcontact/issues`, sends the titles to a Gemini model via Google AI Studio, enforces the word cap server-side (one retry, then truncate), and returns:

```json
{
  "summary": "<prose paragraph>",
  "word_count": 42,
  "generated_at": "2026-06-05T14:00:00Z",
  "issue_count": 18
}
```

If `GEMINI_API_KEY` is unset, the route returns HTTP 502 with a clear `detail` ("`GEMINI_API_KEY must be set in the environment (.env). Generate one at https://aistudio.google.com/apikey.`").

## Notes

- **DigiKey auth** uses OAuth2 client-credentials with an in-memory access-token cache (refreshes when within 60s of expiry).
- **Mouser auth** is a per-request `?apiKey=<key>` query string — no token flow.
- **Gemini auth** is a per-call API key passed to `google.genai.Client(api_key=...)`. The summary route uses `gemini-2.5-flash-lite` (cheapest current tier; well-matched to short summarization). The 24-hour TTL on the frontend cache means visitors trigger at most one backend call per day, comfortably inside AI Studio's free-tier daily request quota.
- Restarting the server clears the DigiKey token cache.
- The Postman collections at `../digikey/digikey.postman_collection.json` and `../mouser/mouser.postman_collection.json` document the same upstream APIs.
