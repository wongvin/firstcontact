"""Combined FastAPI app exposing /digikey/pricing and /mouser/pricing.

Replaces the previous two per-distributor servers (api/digikey/server/ and
api/mouser/server/). One process, one port, one .env with both sets of
credentials, one CORS middleware block, one venv to manage.

Frontends:
- web/digikey-search.html → GET /digikey/pricing
- web/mouser-search.html  → GET /mouser/pricing
"""

from __future__ import annotations

from dotenv import load_dotenv
from fastapi import APIRouter, FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware

from digikey_client import DigiKeyError, get_pricing as get_digikey_pricing
from mouser_client import MouserError, get_pricing as get_mouser_pricing


load_dotenv()

app = FastAPI(title="Part-pricing proxy (DigiKey + Mouser)", version="0.2.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        "http://localhost:5500",
        "http://localhost:8080",
        "https://wongvin.github.io",
    ],
    allow_methods=["GET"],
    allow_headers=["*"],
)


digikey_router = APIRouter(prefix="/digikey", tags=["digikey"])
mouser_router = APIRouter(prefix="/mouser", tags=["mouser"])


@digikey_router.get("/pricing")
async def digikey_pricing(
    manufacturer_part_number: str = Query(..., min_length=1, description="Manufacturer part number, e.g. STM32F407VGT6"),
):
    try:
        return await get_digikey_pricing(manufacturer_part_number)
    except DigiKeyError as err:
        raise HTTPException(status_code=502, detail=str(err))


@mouser_router.get("/pricing")
async def mouser_pricing(
    manufacturer_part_number: str = Query(..., min_length=1, description="Manufacturer part number, e.g. NE555P"),
):
    try:
        return await get_mouser_pricing(manufacturer_part_number)
    except MouserError as err:
        raise HTTPException(status_code=502, detail=str(err))


app.include_router(digikey_router)
app.include_router(mouser_router)


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}
