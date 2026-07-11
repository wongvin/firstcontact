"""Octopart client: scrape the public search page for a part's median (~1K-qty) price.

Octopart has no free API in use here and sits behind Cloudflare bot protection —
a plain httpx/requests GET returns a 403 JS-challenge page with no price. `curl_cffi`
with a Chrome TLS-fingerprint impersonation clears the passive challenge and returns
the real rendered HTML, from which two stable `data-testid` elements are read:

- `serp-result-count`         → "Results: N" (gate on N != 1 before trusting a price)
- `serp-part-header-median-price` → the median unit price (already ~1K-qty)

curl_cffi is a synchronous library; get_pricing keeps the FastAPI endpoint
non-blocking by running the fetch in a worker thread via asyncio.to_thread.
"""

from __future__ import annotations

import asyncio
import re
from typing import Any
from urllib.parse import quote

from curl_cffi import requests as curl_requests


SEARCH_URL_TEMPLATE = "https://octopart.com/search?currency=USD&specs=0&q={q}&s=1"

# Chrome TLS-fingerprint impersonation that clears Cloudflare's passive challenge.
# Version-less alias → curl_cffi auto-selects its newest bundled Chrome profile, so
# upgrading curl_cffi is the version bump (no manual number to maintain).
_IMPERSONATE = "chrome"

_RESULT_COUNT_RE = re.compile(
    r'data-testid="serp-result-count"[^>]*>\s*Results:\s*([\d,]+)'
)
_MEDIAN_PRICE_RE = re.compile(
    r'data-testid="serp-part-header-median-price"[^>]*>([\d.,]+)<'
)


class OctopartError(Exception):
    """Raised when the Octopart page can't be fetched or yields no usable single price."""


def _parse_price(price_str: str) -> float:
    """Octopart renders the median price as e.g. '37.744' (thousands may carry commas)."""
    cleaned = price_str.strip().replace(",", "")
    try:
        return float(cleaned)
    except ValueError as err:
        raise OctopartError(f"Could not parse Octopart price string {price_str!r}: {err}") from err


def _fetch_html(url: str) -> str:
    """Synchronous Cloudflare-clearing GET; raises OctopartError on transport/HTTP failure."""
    try:
        resp = curl_requests.get(url, impersonate=_IMPERSONATE, timeout=30)
    except Exception as err:  # curl_cffi raises its own exception types
        raise OctopartError(f"Octopart request failed: {err}") from err
    if resp.status_code != 200:
        raise OctopartError(f"Octopart search failed ({resp.status_code}).")
    return resp.text


async def get_pricing(manufacturer_part_number: str) -> dict[str, Any]:
    """Scrape the median (~1K-qty) unit price for an exact-match manufacturer part number."""
    mpn = manufacturer_part_number.strip()
    url = SEARCH_URL_TEMPLATE.format(q=quote(mpn))

    html = await asyncio.to_thread(_fetch_html, url)

    # Gate on the result count first — a multi-result page must never silently
    # return the first/featured part's price.
    count_match = _RESULT_COUNT_RE.search(html)
    if not count_match:
        raise OctopartError(f"No Octopart results for {mpn}.")
    count = int(count_match.group(1).replace(",", ""))
    if count == 0:
        raise OctopartError(f"No Octopart results for {mpn}.")
    if count > 1:
        raise OctopartError(
            f"Ambiguous part number {mpn}: {count:,} Octopart results. Enter a more specific MPN."
        )

    price_match = _MEDIAN_PRICE_RE.search(html)
    if not price_match:
        raise OctopartError(
            f"No Octopart price found for {mpn}. "
            f"The part may have no listed pricing or the page layout changed."
        )

    return {
        "manufacturer_part_number": mpn,
        "currency": "USD",
        "unit_price": _parse_price(price_match.group(1)),
        "tier_quantity": 1000,  # Octopart's median price is already ~1K-qty
        "octopart_url": url,
    }
