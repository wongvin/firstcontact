# Mouser pricing proxy

Local FastAPI backend that proxies Mouser's PartNumberSearch API for [`web/mouser-search.html`](../../../web/mouser-search.html). Holds the API key in a local `.env` so the static frontend never sees it.

Companion to `api/digikey/server/` — same architecture, different distributor. Both can run side-by-side (Mouser on **port 8001**, DigiKey on 8000).

## Setup

```bash
cd api/mouser/server
cp .env.example .env
# Edit .env and fill in MOUSER_API_KEY from https://www.mouser.com/api-hub/

python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## Run

```bash
uvicorn main:app --port 8001
```

CORS allowed origins:
- `http://localhost:5500` (VS Code Live Server default)
- `http://localhost:8080` (e.g. `python -m http.server 8080` from `web/`)
- `https://wongvin.github.io` (deployed GH Pages origin)

## Endpoints

### `GET /health`

```
{ "status": "ok" }
```

### `GET /pricing?manufacturer_part_number=<MPN>`

Returns volume-tier pricing for a manufacturer part number from Mouser. Picks the **second-to-last tier** as the headline `unit_price` / `tier_quantity` (same selection rule as the DigiKey backend, for UX parity).

```bash
curl 'http://localhost:8001/pricing?manufacturer_part_number=NE555P'
```

Response shape (deliberately mirrors the DigiKey backend so the frontend logic carries over):

```json
{
  "manufacturer_part_number": "NE555P",
  "mouser_part_number": "595-NE555P",
  "currency": "USD",
  "unit_price": 0.36,
  "tier_quantity": 10,
  "tiers": [
    { "quantity": 1, "unit_price": 0.51 },
    { "quantity": 10, "unit_price": 0.36 },
    { "quantity": 100, "unit_price": 0.28 }
  ]
}
```

The frontend currently displays only the headline tier; the full `tiers` array is included for future use.

## Notes

- Mouser auth is a per-request `?apiKey=<KEY>` query parameter — no OAuth2 token flow, no token cache.
- Underlying API: `POST https://api.mouser.com/api/v1/search/partnumber`. The Postman collection at `api/mouser/mouser.postman_collection.json` documents the same endpoints.
- `Price` in Mouser's PriceBreaks rows arrives as a string (e.g. `"$0.51"` or `"0.51"`); the client strips currency symbols and parses as float, tolerating comma-as-decimal locales.
- Multiple `Parts[]` matches: the client picks the entry whose `ManufacturerPartNumber` matches the user's input case-insensitively, else falls back to the first match.
