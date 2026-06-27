"""DigiKey API client: OAuth2 token cache + ProductPricing call (with a best-effort
ProductMedia photo lookup) + response normalization."""

from __future__ import annotations

import os
import time
from typing import Any

import httpx


TOKEN_URL = "https://api.digikey.com/v1/oauth2/token"
PRODUCT_PRICING_URL_TEMPLATE = "https://api.digikey.com/products/v4/search/{part_number}/pricing"
PRODUCT_MEDIA_URL_TEMPLATE = "https://api.digikey.com/products/v4/search/{part_number}/media"

LOCALE_LANGUAGE = "en"
LOCALE_SITE = "US"
LOCALE_CURRENCY = "USD"

# Refresh access token when within this many seconds of expiry.
TOKEN_REFRESH_BUFFER_SECONDS = 60


_token_cache: dict[str, Any] = {"access_token": None, "expires_at": 0.0}


class DigiKeyError(Exception):
    """Raised when DigiKey returns a non-success response or required config is missing."""


def _get_credentials() -> tuple[str, str]:
    client_id = os.environ.get("DIGIKEY_CLIENT_ID")
    client_secret = os.environ.get("DIGIKEY_CLIENT_SECRET")
    if not client_id or not client_secret:
        raise DigiKeyError(
            "DIGIKEY_CLIENT_ID and DIGIKEY_CLIENT_SECRET must be set in the environment (.env)."
        )
    return client_id, client_secret


async def _fetch_token(client: httpx.AsyncClient) -> str:
    client_id, client_secret = _get_credentials()
    resp = await client.post(
        TOKEN_URL,
        data={
            "client_id": client_id,
            "client_secret": client_secret,
            "grant_type": "client_credentials",
        },
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    if resp.status_code != 200:
        raise DigiKeyError(f"Token request failed ({resp.status_code}): {resp.text}")
    body = resp.json()
    _token_cache["access_token"] = body["access_token"]
    _token_cache["expires_at"] = time.time() + float(body.get("expires_in", 600))
    return body["access_token"]


async def _get_access_token(client: httpx.AsyncClient) -> str:
    token = _token_cache.get("access_token")
    if token and time.time() < _token_cache["expires_at"] - TOKEN_REFRESH_BUFFER_SECONDS:
        return token
    return await _fetch_token(client)


def _select_tier(tiers: list[dict[str, Any]]) -> dict[str, Any]:
    """Pick the second-to-last tier (or only tier if fewer than 2)."""
    if not tiers:
        raise DigiKeyError("ProductPricing response contained no price-break tiers.")
    if len(tiers) < 2:
        return tiers[0]
    return tiers[-2]


def _normalize_tiers(raw_tiers: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Convert DigiKey's StandardPricing rows into {quantity, unit_price} sorted ascending."""
    normalized = [
        {"quantity": int(row["BreakQuantity"]), "unit_price": float(row["UnitPrice"])}
        for row in raw_tiers
    ]
    normalized.sort(key=lambda t: t["quantity"])
    return normalized


def _pick_match(pricings: list[dict[str, Any]], requested_mpn: str) -> dict[str, Any]:
    """Pick the ProductPricings entry whose MPN equals the user's input; else the first entry."""
    requested = requested_mpn.strip().casefold()
    for entry in pricings:
        if (entry.get("ManufacturerProductNumber") or "").casefold() == requested:
            return entry
    return pricings[0]


def _pick_variation(variations: list[dict[str, Any]]) -> dict[str, Any]:
    """Pick the variation with the most StandardPricing tiers (richest price-break info)."""
    if not variations:
        raise DigiKeyError("No ProductVariations returned for this part.")
    return max(variations, key=lambda v: len(v.get("StandardPricing") or []))


def _api_headers(token: str, client_id: str) -> dict[str, str]:
    return {
        "Authorization": f"Bearer {token}",
        "X-DIGIKEY-Client-Id": client_id,
        "X-DIGIKEY-Locale-Language": LOCALE_LANGUAGE,
        "X-DIGIKEY-Locale-Site": LOCALE_SITE,
        "X-DIGIKEY-Locale-Currency": LOCALE_CURRENCY,
        "Accept": "application/json",
    }


def _pick_product_image(media_body: dict[str, Any]) -> str | None:
    """Pull the product photo URL from a ProductMedia response.

    MediaLinks holds mixed media (datasheets, videos, photos); only "Product Photos"
    entries carry image URLs. Prefer the 200x200 SmallPhoto for display, then the
    full-res Url, then the 64x64 Thumbnail.
    """
    for link in media_body.get("MediaLinks") or []:
        if "photo" in (link.get("MediaType") or "").casefold():
            for key in ("SmallPhoto", "Url", "Thumbnail"):
                if link.get(key):
                    return link[key]
    return None


async def _fetch_product_image(
    client: httpx.AsyncClient, headers: dict[str, str], part_number: str
) -> str | None:
    """Best-effort product photo URL. Returns None on any failure — a missing image
    must never break the pricing response."""
    try:
        resp = await client.get(
            PRODUCT_MEDIA_URL_TEMPLATE.format(part_number=part_number), headers=headers
        )
        if resp.status_code != 200:
            return None
        return _pick_product_image(resp.json())
    except (httpx.HTTPError, ValueError):
        return None


async def get_pricing(manufacturer_part_number: str) -> dict[str, Any]:
    """Fetch volume-tier pricing for a manufacturer part number."""
    async with httpx.AsyncClient(timeout=30) as client:
        token = await _get_access_token(client)
        client_id, _ = _get_credentials()
        headers = _api_headers(token, client_id)
        url = PRODUCT_PRICING_URL_TEMPLATE.format(part_number=manufacturer_part_number)
        resp = await client.get(url, headers=headers)

        if resp.status_code == 404:
            raise DigiKeyError(f"Part not found: {manufacturer_part_number}")
        if resp.status_code != 200:
            raise DigiKeyError(f"ProductPricing failed ({resp.status_code}): {resp.text}")

        # Product photo is supplementary — fetched best-effort in the same session so a
        # media error never blocks pricing.
        image_url = await _fetch_product_image(client, headers, manufacturer_part_number)

    body = resp.json()
    pricings = body.get("ProductPricings") or []
    if not pricings:
        raise DigiKeyError(f"Part not found: {manufacturer_part_number}")

    matched = _pick_match(pricings, manufacturer_part_number)
    variation = _pick_variation(matched.get("ProductVariations") or [])
    raw_tiers = variation.get("StandardPricing") or []
    if not raw_tiers:
        raise DigiKeyError(
            f"No StandardPricing tiers returned for {manufacturer_part_number}. "
            f"This part may be unavailable in the US/USD locale."
        )

    tiers = _normalize_tiers(raw_tiers)
    selected = _select_tier(tiers)

    return {
        "manufacturer_part_number": matched.get("ManufacturerProductNumber") or manufacturer_part_number,
        "digikey_part_number": variation.get("DigiKeyProductNumber"),
        "currency": LOCALE_CURRENCY,
        "unit_price": selected["unit_price"],
        "tier_quantity": selected["quantity"],
        "tiers": tiers,
        "image_url": image_url,
    }
