"""Mouser API client: SearchByPartRequest call + response normalization.

No token caching needed — Mouser auth is a per-request `?apiKey=` query string.
"""

from __future__ import annotations

import os
import re
from typing import Any

import httpx


PART_NUMBER_SEARCH_URL = "https://api.mouser.com/api/v1/search/partnumber"


class MouserError(Exception):
    """Raised when Mouser returns an error response or required config is missing."""


def _get_api_key() -> str:
    api_key = os.environ.get("MOUSER_API_KEY")
    if not api_key:
        raise MouserError("MOUSER_API_KEY must be set in the environment (.env).")
    return api_key


def _parse_price(price_str: str) -> float:
    """Mouser returns Price as a string like '$0.51' or '0.51'. Strip non-numeric prefix and parse."""
    if not price_str:
        raise MouserError(f"Empty price string in Mouser response.")
    # Strip leading currency symbols and whitespace; tolerate locale variants
    cleaned = re.sub(r"^[^\d.,-]+", "", price_str.strip())
    # Normalize comma-as-decimal locales by replacing the last comma with a dot if no dot present
    if "." not in cleaned and "," in cleaned:
        cleaned = cleaned.replace(",", ".")
    else:
        cleaned = cleaned.replace(",", "")
    try:
        return float(cleaned)
    except ValueError as err:
        raise MouserError(f"Could not parse Mouser price string {price_str!r}: {err}") from err


def _pick_part(parts: list[dict[str, Any]], requested_mpn: str) -> dict[str, Any]:
    """Pick the Part whose ManufacturerPartNumber matches user input (case-insensitive); else first."""
    requested = requested_mpn.strip().casefold()
    for part in parts:
        if (part.get("ManufacturerPartNumber") or "").casefold() == requested:
            return part
    return parts[0]


def _select_tier(tiers: list[dict[str, Any]]) -> dict[str, Any]:
    """Pick the second-to-last tier (or only tier if fewer than 2). Same rule as DigiKey backend."""
    if not tiers:
        raise MouserError("Mouser response contained no PriceBreaks.")
    if len(tiers) < 2:
        return tiers[0]
    return tiers[-2]


def _normalize_tiers(raw_breaks: list[dict[str, Any]]) -> tuple[list[dict[str, Any]], str]:
    """Convert Mouser PriceBreaks rows into [{quantity, unit_price}] sorted ascending,
    and return the currency string from the first row."""
    normalized: list[dict[str, Any]] = []
    currency = "USD"
    for row in raw_breaks:
        normalized.append(
            {
                "quantity": int(row["Quantity"]),
                "unit_price": _parse_price(row.get("Price") or ""),
            }
        )
        if row.get("Currency"):
            currency = row["Currency"]
    normalized.sort(key=lambda t: t["quantity"])
    return normalized, currency


async def get_pricing(manufacturer_part_number: str) -> dict[str, Any]:
    """Fetch volume-tier pricing for a manufacturer part number from Mouser."""
    api_key = _get_api_key()
    body = {
        "SearchByPartRequest": {
            "mouserPartNumber": manufacturer_part_number,
            "partSearchOptions": "",
        }
    }
    async with httpx.AsyncClient(timeout=30) as client:
        resp = await client.post(
            PART_NUMBER_SEARCH_URL,
            params={"apiKey": api_key},
            json=body,
            headers={"Accept": "application/json", "Content-Type": "application/json"},
        )

    if resp.status_code != 200:
        raise MouserError(f"PartNumberSearch failed ({resp.status_code}): {resp.text}")

    payload = resp.json()
    errors = payload.get("Errors") or []
    if errors:
        first_msg = errors[0].get("Message") or "Mouser returned an error."
        raise MouserError(first_msg)

    results = payload.get("SearchResults") or {}
    parts = results.get("Parts") or []
    if not parts:
        raise MouserError(f"Part not found: {manufacturer_part_number}")

    matched = _pick_part(parts, manufacturer_part_number)
    raw_breaks = matched.get("PriceBreaks") or []
    if not raw_breaks:
        raise MouserError(
            f"No PriceBreaks returned for {manufacturer_part_number}. "
            f"This part may have no published pricing in the API."
        )

    tiers, currency = _normalize_tiers(raw_breaks)
    selected = _select_tier(tiers)

    return {
        "manufacturer_part_number": matched.get("ManufacturerPartNumber") or manufacturer_part_number,
        "mouser_part_number": matched.get("MouserPartNumber"),
        "currency": currency,
        "unit_price": selected["unit_price"],
        "tier_quantity": selected["quantity"],
        "tiers": tiers,
    }
