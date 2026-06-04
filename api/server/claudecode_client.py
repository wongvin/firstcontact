"""Claude Code session-transcript parser.

Walks every `*.jsonl` file under `~/.claude/projects/`, groups events into
`(user_prompt, assistant_response)` pairs, and produces a flat globally-sorted
timeline that the /claudecode/* routes serve to the viewer page.

JSONL event types observed in practice:
  - user                       — user prompt OR a tool_result echo (filter out the latter)
  - assistant                  — Claude's reply, with content blocks (text/thinking/tool_use); only `text` blocks are surfaced
  - ai-title                   — auto-generated session title
  - queue-operation            — operational noise
  - attachment                 — attached file
  - file-history-snapshot      — file snapshots
  - last-prompt                — marker
  - pr-link                    — PR link

Output shape (returned by build_timeline):
{
  "prompts": [
    {
      "index": 0,
      "day": "2026-05-13",
      "timestamp": "2026-05-13T22:00:00.000Z",
      "session_id": "21314020-...",
      "user_text": "...",
      "response_text": "..."
    },
    ...
  ],
  "days": [
    { "date": "2026-05-13", "first_prompt_index": 0, "last_prompt_index": 14 },
    ...
  ]
}
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Iterable


PROJECTS_ROOT = Path.home() / ".claude" / "projects"

NOISE_TYPES = frozenset({
    "queue-operation",
    "ai-title",
    "attachment",
    "file-history-snapshot",
    "last-prompt",
    "pr-link",
})


def _iter_session_files() -> Iterable[Path]:
    if not PROJECTS_ROOT.exists():
        return []
    return sorted(PROJECTS_ROOT.glob("*/*.jsonl"))


def _extract_user_text(entry: dict[str, Any]) -> str | None:
    """Return the user-typed text from a `type: user` entry, or None if this is a tool result echo."""
    message = entry.get("message") or {}
    content = message.get("content")
    if isinstance(content, str):
        return content if content.strip() else None
    if not isinstance(content, list):
        return None
    pieces: list[str] = []
    has_tool_result = False
    for block in content:
        if not isinstance(block, dict):
            continue
        btype = block.get("type")
        if btype == "tool_result":
            has_tool_result = True
            continue
        if btype == "text" and isinstance(block.get("text"), str):
            pieces.append(block["text"])
    text = "\n".join(p.strip() for p in pieces if p.strip())
    if not text:
        return None
    if has_tool_result and not text.strip():
        return None
    return text


def _extract_assistant_text_blocks(entry: dict[str, Any]) -> list[str]:
    """Return only the text blocks from an assistant entry.

    `tool_use` and `thinking` blocks are dropped — the viewer surfaces just the
    user-facing prose Claude produced, with no operational noise.
    """
    message = entry.get("message") or {}
    content = message.get("content")
    if isinstance(content, str):
        return [content] if content else []
    if not isinstance(content, list):
        return []
    texts: list[str] = []
    for block in content:
        if not isinstance(block, dict):
            continue
        if block.get("type") == "text" and isinstance(block.get("text"), str):
            text = block["text"]
            if text:
                texts.append(text)
    return texts


def _parse_session(path: Path) -> list[dict[str, Any]]:
    """Yield `(prompt, response)` pair dicts for one session file."""
    pairs: list[dict[str, Any]] = []
    current_prompt: dict[str, Any] | None = None
    current_response_texts: list[str] = []

    def flush() -> None:
        if current_prompt is None:
            return
        current_prompt["response_text"] = "\n\n".join(current_response_texts).strip()
        pairs.append(current_prompt)

    try:
        with path.open("r", encoding="utf-8") as f:
            for raw in f:
                line = raw.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    continue
                etype = entry.get("type")
                if etype in NOISE_TYPES:
                    continue
                if etype == "user":
                    user_text = _extract_user_text(entry)
                    if user_text is None:
                        continue
                    flush()
                    current_prompt = {
                        "timestamp": entry.get("timestamp"),
                        "session_id": entry.get("sessionId") or path.stem,
                        "user_text": user_text,
                    }
                    current_response_texts = []
                elif etype == "assistant":
                    if current_prompt is None:
                        # response with no preceding user prompt — skip
                        continue
                    current_response_texts.extend(_extract_assistant_text_blocks(entry))
    except OSError:
        return []
    flush()
    return [p for p in pairs if p.get("timestamp")]


def build_timeline() -> dict[str, Any]:
    """Parse every session under PROJECTS_ROOT into a single sorted timeline."""
    all_pairs: list[dict[str, Any]] = []
    for path in _iter_session_files():
        all_pairs.extend(_parse_session(path))

    all_pairs.sort(key=lambda p: p["timestamp"])

    prompts: list[dict[str, Any]] = []
    days_map: dict[str, list[int]] = {}
    for index, pair in enumerate(all_pairs):
        ts = pair["timestamp"] or ""
        day = ts[:10] if len(ts) >= 10 else ""
        prompts.append({
            "index": index,
            "day": day,
            "timestamp": ts,
            "session_id": pair.get("session_id", ""),
            "user_text": pair.get("user_text", ""),
            "response_text": pair.get("response_text", ""),
        })
        days_map.setdefault(day, []).append(index)

    days = [
        {"date": day, "first_prompt_index": indexes[0], "last_prompt_index": indexes[-1]}
        for day, indexes in sorted(days_map.items())
        if day
    ]

    return {"prompts": prompts, "days": days}
