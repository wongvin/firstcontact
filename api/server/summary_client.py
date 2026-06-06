"""Generates a <50-word prose summary of closed-issue activity from the last 30 days.

Pulls closed issues from the GitHub Issues API (unauthenticated), feeds the titles to a
Gemini model via Google AI Studio, enforces a 50-word cap server-side with one retry,
and returns a normalized JSON response.

GEMINI_API_KEY must be set in the environment (.env). Generate one at
https://aistudio.google.com/apikey.
"""

from __future__ import annotations

import os
import re
from datetime import datetime, timedelta, timezone
from typing import Any

import httpx


GITHUB_REPO = "wongvin/firstcontact"
GITHUB_ISSUES_URL = f"https://api.github.com/repos/{GITHUB_REPO}/issues"

WINDOW_DAYS = 30
ISSUE_FETCH_LIMIT = 50
WORD_LIMIT = 50

GEMINI_MODEL = "gemini-2.5-flash-lite"

SYSTEM_PROMPT = (
    "You write concise editorial summaries of software engineering work. "
    "Given a chronological list of recently-closed issue titles, write a single "
    f"plain-prose paragraph under {WORD_LIMIT} words that describes the overall "
    "themes of the work. No bullet points, no emojis, no markdown, no headings. "
    "Plain prose only. Do not include preamble like 'Here is the summary:'."
)

RETRY_INSTRUCTION = (
    f"\n\nYour previous response exceeded {WORD_LIMIT} words. "
    f"Rewrite it more concisely. Hard limit: strictly under {WORD_LIMIT} words."
)

_PREFIX_RE = re.compile(r"^(feat|fix|chore|docs|refactor|test|build|ci|perf)(\(.+?\))?:", re.IGNORECASE)


class SummaryError(Exception):
    """Raised when summary generation fails (missing key, GitHub fetch error, model failure, …)."""


def _get_api_key() -> str:
    key = os.environ.get("GEMINI_API_KEY")
    if not key:
        raise SummaryError(
            "GEMINI_API_KEY must be set in the environment (.env). "
            "Generate one at https://aistudio.google.com/apikey."
        )
    return key


def _word_count(text: str) -> int:
    return len(text.strip().split())


def _truncate_to_word_limit(text: str, limit: int) -> str:
    words = text.strip().split()
    if len(words) <= limit:
        return text.strip()
    return " ".join(words[:limit]).rstrip(",.;:") + "…"


def _extract_prefix(title: str) -> str:
    match = _PREFIX_RE.match(title)
    if match:
        return match.group(1).lower()
    return "other"


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _iso_z(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


async def _fetch_recent_closed_issues() -> list[dict[str, Any]]:
    cutoff = _utc_now() - timedelta(days=WINDOW_DAYS)
    async with httpx.AsyncClient(timeout=30) as client:
        resp = await client.get(
            GITHUB_ISSUES_URL,
            params={
                "state": "closed",
                "per_page": 100,
                "since": _iso_z(cutoff),
                "sort": "updated",
                "direction": "desc",
            },
            headers={"Accept": "application/vnd.github+json"},
        )
    if resp.status_code != 200:
        raise SummaryError(f"GitHub Issues fetch failed ({resp.status_code}): {resp.text[:300]}")
    items = resp.json()
    issues: list[dict[str, Any]] = []
    for item in items:
        if item.get("pull_request"):
            continue
        closed_at = item.get("closed_at")
        if not closed_at:
            continue
        closed_dt = datetime.fromisoformat(closed_at.replace("Z", "+00:00"))
        if closed_dt < cutoff:
            continue
        issues.append(item)
    issues.sort(key=lambda i: i["closed_at"], reverse=True)
    return issues[:ISSUE_FETCH_LIMIT]


def _build_prompt(issues: list[dict[str, Any]]) -> str:
    lines = []
    for issue in issues:
        title = (issue.get("title") or "").strip()
        prefix = _extract_prefix(title)
        lines.append(f"- [{prefix}] {title}")
    return (
        f"Recently-closed issues from the last {WINDOW_DAYS} days "
        f"(most recent first, {len(issues)} total):\n\n"
        + "\n".join(lines)
        + f"\n\nWrite a single plain-prose paragraph strictly under {WORD_LIMIT} words "
        "summarizing the overall themes. No bullet points, no markdown, no emojis."
    )


async def _generate_with_gemini(prompt: str) -> str:
    from google import genai
    from google.genai import types

    try:
        client = genai.Client(api_key=_get_api_key())
        response = await client.aio.models.generate_content(
            model=GEMINI_MODEL,
            contents=prompt,
            config=types.GenerateContentConfig(
                system_instruction=SYSTEM_PROMPT,
                temperature=0.4,
            ),
        )
    except SummaryError:
        raise
    except Exception as err:
        raise SummaryError(f"Gemini call failed: {err}") from err

    text = (response.text or "").strip()
    if not text:
        raise SummaryError("Gemini returned an empty response.")
    return text


async def get_30day_summary() -> dict[str, Any]:
    """Return `{summary, word_count, generated_at, issue_count}` for the last 30 days of closed issues."""
    issues = await _fetch_recent_closed_issues()
    if not issues:
        msg = "No issues were closed in the last 30 days."
        return {
            "summary": msg,
            "word_count": _word_count(msg),
            "generated_at": _iso_z(_utc_now()),
            "issue_count": 0,
        }

    prompt = _build_prompt(issues)
    summary = await _generate_with_gemini(prompt)
    if _word_count(summary) > WORD_LIMIT:
        summary = await _generate_with_gemini(prompt + RETRY_INSTRUCTION)
    if _word_count(summary) > WORD_LIMIT:
        summary = _truncate_to_word_limit(summary, WORD_LIMIT)

    return {
        "summary": summary,
        "word_count": _word_count(summary),
        "generated_at": _iso_z(_utc_now()),
        "issue_count": len(issues),
    }
