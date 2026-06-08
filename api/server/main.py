"""Combined FastAPI app exposing /digikey/pricing, /mouser/pricing, /claudecode/timeline, and /summary/30days.

One process, one port, one .env (DigiKey + Mouser + Gemini credentials), one CORS middleware block.

Frontends (served by the Vercel-hosted Next.js app under webapp/):
- webapp/public/digikey-search.html      → GET /digikey/pricing
- webapp/public/mouser-search.html       → GET /mouser/pricing
- webapp/public/transcripts-viewer.html  → GET /claudecode/timeline
- webapp/app/page.tsx (homepage)         → GET /summary/30days
"""

from __future__ import annotations

from dotenv import load_dotenv
from fastapi import APIRouter, FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware

from claudecode_client import build_timeline
from digikey_client import DigiKeyError, get_pricing as get_digikey_pricing
from mouser_client import MouserError, get_pricing as get_mouser_pricing
from summary_client import SummaryError, get_30day_summary


load_dotenv()

app = FastAPI(title="Part-pricing proxy + Claude Code transcript viewer + 30-day summary", version="0.4.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        "http://localhost:3000",  # Next.js dev server (webapp)
        "http://localhost:5500",
        "http://localhost:8080",
        "https://wongvin.github.io",  # legacy GH Pages origin (kept harmless)
    ],
    # Vercel production + preview deploys (e.g. https://<project>.vercel.app,
    # https://<project>-<hash>-<scope>.vercel.app).
    allow_origin_regex=r"https://.*\.vercel\.app",
    allow_methods=["GET"],
    allow_headers=["*"],
)


digikey_router = APIRouter(prefix="/digikey", tags=["digikey"])
mouser_router = APIRouter(prefix="/mouser", tags=["mouser"])
claudecode_router = APIRouter(prefix="/claudecode", tags=["claudecode"])
summary_router = APIRouter(prefix="/summary", tags=["summary"])


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


@summary_router.get("/30days")
async def summary_30days():
    """LLM-generated prose summary (<50 words) of closed-issue activity in the last 30 days."""
    try:
        return await get_30day_summary()
    except SummaryError as err:
        raise HTTPException(status_code=502, detail=str(err))


app.include_router(digikey_router)
app.include_router(mouser_router)
app.include_router(claudecode_router)
app.include_router(summary_router)


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}
