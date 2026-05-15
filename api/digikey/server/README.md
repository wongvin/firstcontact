# DigiKey pricing proxy

Local FastAPI backend that proxies DigiKey ProductPricing API calls for [`web/search.html`](../../../web/search.html). Holds OAuth2 client credentials in a local `.env` so the static frontend never sees them.

## Setup

```bash
cd api/digikey/server
#cp .env.example .env
# Edit .env and fill in DIGIKEY_CLIENT_ID and DIGIKEY_CLIENT_SECRET from
# https://developer.digikey.com (production app credentials)

python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## Run

```bash
uvicorn main:app --port 8000
```

The server listens on `http://localhost:8000`. CORS is allowed for:
- `http://localhost:5500` (VS Code Live Server default)
- `http://localhost:8080` (e.g. `python -m http.server 8080` from `web/`)
- `https://wongvin.github.io` (the deployed GH Pages origin, future-proofing)

## Endpoints

### `GET /health`

```
{ "status": "ok" }
```

### `GET /pricing?manufacturer_part_number=<MPN>`

Returns volume-tier pricing for a manufacturer part number. Picks the
second-to-last tier as the headline (`unit_price` / `tier_quantity`).

```bash
curl 'http://localhost:8000/pricing?manufacturer_part_number=STM32F407VGT6'
```

Response shape:

```json
{
  "manufacturer_part_number": "STM32F407VGT6",
  "digikey_part_number": "497-11769-ND",
  "currency": "USD",
  "unit_price": 7.12,
  "tier_quantity": 1000,
  "tiers": [
    { "quantity": 1, "unit_price": 9.34 },
    { "quantity": 10, "unit_price": 8.41 },
    { "quantity": 100, "unit_price": 7.85 },
    { "quantity": 1000, "unit_price": 7.12 },
    { "quantity": 10000, "unit_price": 6.40 }
  ]
}
```

The frontend currently displays only the headline tier; the full `tiers` array is included for future use.

## Notes

The access token is cached in-process and refreshed when within 60s of expiry. Restarting the server clears the cache.
