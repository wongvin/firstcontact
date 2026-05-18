# Part-pricing proxy (DigiKey + Mouser)

Single local FastAPI backend that proxies pricing API calls for both [`web/digikey-search.html`](../../web/digikey-search.html) and [`web/mouser-search.html`](../../web/mouser-search.html). Holds DigiKey OAuth2 client credentials **and** the Mouser API key in one local `.env` so neither set ships to the static frontend.

Consolidates the previous `api/digikey/server/` and `api/mouser/server/` directories per issue #26. Distributor-specific logic still lives in dedicated client modules (`digikey_client.py`, `mouser_client.py`) — only the routing layer is shared.

## Setup

```bash
cd api/server
cp .env.example .env
# Edit .env and fill in:
#   DIGIKEY_CLIENT_ID, DIGIKEY_CLIENT_SECRET    (from https://developer.digikey.com)
#   MOUSER_API_KEY                              (from https://www.mouser.com/api-hub/)

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
- `https://wongvin.github.io` (the deployed GH Pages origin)

## Endpoints

### `GET /health`

```
{ "status": "ok" }
```

### `GET /digikey/pricing?manufacturer_part_number=<MPN>`

```bash
curl 'http://localhost:8000/digikey/pricing?manufacturer_part_number=STM32F407VGT6'
```

Returns volume-tier pricing from DigiKey's ProductPricing v4 API. Picks the second-to-last tier as the headline.

### `GET /mouser/pricing?manufacturer_part_number=<MPN>`

```bash
curl 'http://localhost:8000/mouser/pricing?manufacturer_part_number=NE555P'
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

## Notes

- **DigiKey auth** uses OAuth2 client-credentials with an in-memory access-token cache (refreshes when within 60s of expiry).
- **Mouser auth** is a per-request `?apiKey=<key>` query string — no token flow.
- Restarting the server clears the DigiKey token cache.
- The Postman collections at `../digikey/digikey.postman_collection.json` and `../mouser/mouser.postman_collection.json` document the same upstream APIs.
