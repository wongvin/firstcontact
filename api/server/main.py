"""Combined FastAPI app exposing /digikey/pricing, /mouser/pricing, and /claudecode/timeline.

One process, one port, one .env (DigiKey + Mouser credentials), one CORS middleware block.

Frontends:
- web/digikey-search.html  → GET /digikey/pricing
- web/mouser-search.html   → GET /mouser/pricing
- web/transcripts-viewer.html → GET /claudecode/timeline
"""

from __future__ import annotations

from dotenv import load_dotenv
from fastapi import APIRouter, FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware

from claudecode_client import build_timeline
from digikey_client import DigiKeyError, get_pricing as get_digikey_pricing
from mouser_client import MouserError, get_pricing as get_mouser_pricing


load_dotenv()

app = FastAPI(title="Part-pricing proxy + Claude Code transcript viewer", version="0.3.0")

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
claudecode_router = APIRouter(prefix="/claudecode", tags=["claudecode"])


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


@claudecode_router.get("/timeline")
async def claudecode_timeline():
    """Flat globally-sorted timeline of (user_prompt, assistant_response) pairs across all sessions."""
    return build_timeline()


app.include_router(digikey_router)
app.include_router(mouser_router)
app.include_router(claudecode_router)


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}
