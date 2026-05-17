"""FastAPI app exposing GET /pricing for web/mouser-search.html."""

from __future__ import annotations

from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware

from mouser_client import MouserError, get_pricing


load_dotenv()

app = FastAPI(title="Mouser pricing proxy", version="0.1.0")

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


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/pricing")
async def pricing(
    manufacturer_part_number: str = Query(..., min_length=1, description="Manufacturer part number, e.g. NE555P"),
):
    try:
        return await get_pricing(manufacturer_part_number)
    except MouserError as err:
        raise HTTPException(status_code=502, detail=str(err))
