# Test Plan

A snapshot of test cases for the live site at https://wongvin.github.io/firstcontact/, covering features shipped through issues #1–#3. Update when new features land.

## Scope

In scope:
- HTTPS / HTTP-redirect behavior
- Homepage hero (Hello, World + device line)
- Quote of the day (daily rotation)
- "Changes made this week" panel (live GitHub fetch)
- Layout on mobile and desktop viewports
- Empty / error paths

Out of scope:
- Performance / Lighthouse scoring
- Cross-tab session behavior (no session state)
- Visual regression snapshots (no tooling set up)

## Environments

| Browser | Device | Required |
|---|---|---|
| Chrome (latest) | Desktop, 1440×900 | yes |
| Safari (latest) | Desktop, 1440×900 | yes |
| Mobile Safari | iPhone (375×667 or wider) | yes |
| DevTools mobile emulation | Chrome → iPhone SE preset | yes |

All tests run against **production** (`https://wongvin.github.io/firstcontact/`) after the Pages build for the commit under test has reported `built`.

DevTools procedures (set a breakpoint, block a URL, override a response, etc.) are documented once in the [Appendix](#appendix-devtools-procedures-chrome) and referenced by letter from the test cases below.

---

## 1. HTTPS / redirect (issue #1)

| ID | Steps | Expected |
|---|---|---|
| 1.1 | `curl -sI https://wongvin.github.io/firstcontact/` | First line is `HTTP/2 200`. `content-type: text/html` present. |
| 1.2 | `curl -sI http://wongvin.github.io/firstcontact/` | First line is `HTTP/1.1 301 Moved Permanently`. `Location:` header points to `https://…`. |
| 1.3 | In a fresh Chrome incognito window (to avoid HSTS-cached redirect), type `http://wongvin.github.io/firstcontact/` into the address bar and press Enter. | Browser briefly shows the http URL, then silently navigates to `https://…`. Padlock icon appears in the address bar. |

## 2. Hero & device line

| ID | Steps | Expected |
|---|---|---|
| 2.1 | Load homepage on desktop. | "Hello, World!" heading visible, centered horizontally and vertically. |
| 2.2 | Same. | Gradient background (purple → indigo, top-left to bottom-right) covers the full viewport. |
| 2.3 | Same. | A line below the heading reads `You are on: <something>` (e.g. `Macintosh; Intel Mac OS X 10_15_7`). The token between parens of the user-agent string should appear. |
| 2.4 | Open the URL on a real iPhone in Safari (see Appendix J). | Hero and device line render. Nothing overflows the viewport horizontally. Pinch-zoom not required to read text. |
| 2.5 | Disable JavaScript (Appendix F), reload. | Hero heading still renders. Device line keeps placeholder text "Loading device info…". Quote and recent-tasks panels remain in their loading/empty state. (Acceptable graceful degradation.) Re-enable JS when done. |

## 3. Quote of the day (issues #2, #4)

This feature was originally a static day-of-year-rotating array (issue #2) and was replaced by a live API fetch from `dummyjson.com/quotes/random` in issue #4. Tests below cover the current implementation.

| ID | Steps | Expected |
|---|---|---|
| 3.1 | Load homepage. | A quote in italics and a `— <author>` line render below the device line, with a thin top border separating them from the hero. (May briefly appear empty before the fetch resolves — typically <1s on a normal connection.) |
| 3.2 | DevTools → **Network** tab (Appendix A), hard-refresh, filter by "dummyjson". | Exactly one request to `https://dummyjson.com/quotes/random`. Status `200`, type `fetch`. Response JSON has `quote` and `author` string fields. |
| 3.3 | Hard-refresh the page three times. | At least two **different** quote texts appear across the three loads. (Random API; small chance of two repeats — a third try should produce variation. If all three are identical across many tries, suspect API caching at an edge.) |
| 3.4 | DevTools → Elements panel, locate `<blockquote id="quote">`. | Contains `<span id="quote-text">` (non-empty, with smart double-quotes around the API text) and a `<footer>` with `<span id="quote-author">` (non-empty, plain text). Values match the most recent network response. |
| 3.5 | Open the URL on a real iPhone (Appendix J). | Quote card readable. Doesn't push the hero off-screen on a 375-px-wide viewport. |
| 3.6 | Block the URL pattern `*dummyjson.com*` (Appendix C), hard-refresh. | Quote area shows the message **"Could not load today's quote."** (plain text, no smart quotes around it; author span empty). No JS error pop-up. Page does not appear broken. Remove the block when done. |
| 3.7 | DevTools → Network → throttle to "Offline" (Appendix D), hard-refresh. | Same as 3.6: graceful "Could not load today's quote." Restore "No throttling" when done. |

## 4. Changes made this week (issue #3)

### 4a. Happy path

| ID | Steps | Expected |
|---|---|---|
| 4a.1 | Load homepage. | Top-right panel visible. Heading "CHANGES MADE THIS WEEK" in uppercase, bold, with a thin underline border below it. Translucent background (blurred view of gradient). |
| 4a.2 | Same. | Body is a **numbered** list (`<ol>`, decimal markers `1.`, `2.`, `3.` visible). |
| 4a.3 | Same. | List items are titles of issues closed in the last 7 days, **most recent first**. As of `119b0e5`, expect: `1.` "Display tasks completed in the last 7 days", `2.` "Add quote of the day to homepage", `3.` "HTTPS homepage". |
| 4a.4 | Same. | Each entry is **plain text** — no underlined link, no `(Xh ago)` timestamp, no icon. Hover does not change the cursor to a pointer. |
| 4a.5 | DevTools → **Network** tab (Appendix A), hard-refresh (Cmd-Shift-R). Filter by "github.com". | Exactly one request to `https://api.github.com/repos/wongvin/firstcontact/issues?state=closed&per_page=30&sort=updated&direction=desc`. Status `200`, `Type: fetch`. |

### 4b. Layout / sizing

| ID | Steps | Expected |
|---|---|---|
| 4b.1 | Resize browser window to 1440px wide (or use Appendix G with width 1440). | Panel sits in top-right, ~20rem (320 px) wide, with ~16 px (1 rem) padding from both edges. |
| 4b.2 | Use the device toolbar (Appendix G) to set a custom viewport of 360×640. | Panel width shrinks (formula: `min(20rem, calc(100vw - 2rem))` ≈ 328 px) and stays in the top-right corner without overlapping the right edge or wrapping into the hero. |
| 4b.3 | DevTools → Elements → click the `<aside id="recent-tasks">` node → right pane → **Computed** tab (Appendix H). Filter for "max-height" then "overflow". | `max-height` resolves to `25vh` (e.g. `225px` at 900-px viewport height). `overflow-y` resolves to `auto`. |
| 4b.4 | In the Console, paste:<br>`for(let i=0;i<30;i++){const li=document.createElement('li');li.textContent='filler '+i;document.getElementById('recent-tasks-list').appendChild(li);}` | Panel height stays capped at 25vh. An internal vertical scrollbar appears within the panel. The page itself does not gain a scrollbar. |

### 4c. Empty path

| ID | Steps | Expected |
|---|---|---|
| 4c.1 | Set a breakpoint (Appendix B) on the line<br>`if (recent.length === 0) return setEmpty('No changes this week.');`<br>inside `loadRecent` (around line 131 of `index.html`). Hard-refresh. When execution pauses, in the Console run `recent.length = 0`, then click ▶ Resume. | Panel body shows the single line "No changes this week.", un-bulleted (no `1.`) and dimmed. |

### 4d. Error path

| ID | Steps | Expected |
|---|---|---|
| 4d.1 | Block the GitHub API URL (Appendix C) with pattern `*api.github.com*`. Hard-refresh. | Panel body shows the single line "Could not load recent changes.", un-bulleted and dimmed. Network tab shows the request as red/blocked. No further uncaught JS errors in the Console (a single "blocked" log entry is acceptable). Remove the block when done. |
| 4d.2 | Set network throttling to "Offline" (Appendix D). Hard-refresh. | Same as 4d.1: graceful "Could not load recent changes." Restore "No throttling" when done. |

### 4e. Defense-in-depth

| ID | Steps | Expected |
|---|---|---|
| 4e.1 | DevTools → Elements → click any `<li>` inside `#recent-tasks-list`. | Inside the `<li>` is a single Text node (the title). No `<a>`, no `<span>`, no nested elements. (Confirms the `textContent` rendering path.) |
| 4e.2 | Override the API response (Appendix E). In the saved JSON file, change one issue's `title` to the literal string<br>`<img src=x onerror=alert('XSS')>`<br>and save. Hard-refresh. | The literal `<img …>` string appears as text in the list — visible angle brackets and all. **No alert dialog opens. No image tag is created.** Confirm by checking the rendered `<li>`'s innerHTML in the Elements panel — it should be the text-encoded form (`&lt;img …&gt;`), not a real `<img>` element. Disable the override when done. |

## 5. Cross-browser / accessibility quick checks

| ID | Steps | Expected |
|---|---|---|
| 5.1 | Repeat 2.1, 3.1, 4a.1 in Safari (desktop). | All pass. The `backdrop-filter` (with `-webkit-` prefix) renders the panel as translucent / blurred (not a hard solid color). |
| 5.2 | Repeat 2.1, 3.1, 4a.1 on iPhone Safari (Appendix J). | All pass. Panel is translucent and legible. |
| 5.3 | Click the address bar, then press Tab repeatedly (Appendix H, "Keyboard navigation"). | No focusable elements exist in the page itself (no inputs, no anchors, no buttons), so Tab moves out of the page on the first press. No focus traps; no errors. |
| 5.4 | DevTools → Elements → select the `<aside id="recent-tasks">` node → switch the right pane to **Accessibility** (Appendix H). | "Computed Properties" shows `name: Changes made this week` and `role: complementary`. The `<h2>` is also reachable via the Accessibility tree as a Heading landmark. |
| 5.5 | Run a Lighthouse Accessibility audit (Appendix I). | Score ≥ 90. Investigate any flagged item (e.g. contrast warnings on translucent panel text). |

## 6. Product search (issue #20)

The `web/digikey-search.html` page is a static frontend that calls a **local** Python FastAPI backend at `http://localhost:8000/digikey/...` (`api/server/`). The live deployed page exists but is non-functional unless the user has the combined backend running with their own DigiKey credentials. Since #26, the DigiKey and Mouser backends share one process — see § 7 for the Mouser-side smoke tests against the same server.

### 6a. Homepage link

| ID | Steps | Expected |
|---|---|---|
| 6a.1 | Open `https://wongvin.github.io/firstcontact/`. | Bottom-right shows a "Product search →" link in the glass-card style; does not overlap the "Changes made this week" panel. |
| 6a.2 | Click the link. | Navigates to `/firstcontact/digikey-search.html`. New page loads with same gradient background, a "← Home" link top-left, an `<h1>DigiKey Product Search</h1>`, a subtitle, and an MPN input form. |

### 6b. Backend unreachable (live site, no local server)

| ID | Steps | Expected |
|---|---|---|
| 6b.1 | On the live `/digikey-search.html` with no local backend running, type `STM32F407VGT6` and submit. | After a brief "Loading…", an error message appears: "Backend unreachable at `http://localhost:8000` — start the local server (see `api/server/README.md`)." Form re-enables; no console crash. |

### 6c. Local backend smoke (developer-only)

Prerequisite: combined backend up per `api/server/README.md` with real `DIGIKEY_CLIENT_ID` / `DIGIKEY_CLIENT_SECRET` (and `MOUSER_API_KEY` if you'll also run § 7c).

| ID | Steps | Expected |
|---|---|---|
| 6c.1 | `curl http://localhost:8000/health` | Returns `{"status":"ok"}`. |
| 6c.2 | `curl 'http://localhost:8000/digikey/pricing?manufacturer_part_number=STM32F407VGT6'` | HTTP 200 with JSON containing `manufacturer_part_number`, `digikey_part_number`, `currency: "USD"`, non-empty `tiers` array (sorted ascending by `quantity`), and a `unit_price` / `tier_quantity` pair matching `tiers[-2]` (or `tiers[0]` if fewer than 2 entries). |
| 6c.3 | Serve `web/` locally (`cd web && python -m http.server 8080`), open `http://localhost:8080/digikey-search.html`, type a known MPN, submit. | Headline renders as `Qty <N> → $<P> USD / unit` with both numbers in the same large font weight/size. A muted line below shows `<MPN>  ·  DK: <DigiKey-PN>`. No tier table appears. |
| 6c.4 | Submit a bogus MPN like `NOTAPART_xyz`. | After "Loading…", an error message renders (DigiKey 404 surfaced as a 502 from the proxy with a "Part not found" detail), not the headline. |

### 6d. Defense-in-depth

| ID | Steps | Expected |
|---|---|---|
| 6d.1 | DevTools → Elements → after a successful search, inspect the `.headline` and `.part-line` nodes. | Inner content is Text nodes only — no nested `<a>`, `<span>` (except the deliberate ones), and certainly no markup injected from the backend response. (Confirms `document.createElement` + `textContent` / `createTextNode` rendering path.) |

## 7. Mouser product search (issue #24)

The `web/mouser-search.html` page is a static frontend that calls a **local** Python FastAPI backend at `http://localhost:8000/mouser/...` (`api/server/`). Same shape as § 6 but for Mouser; since #26 both distributors share the single backend on port 8000, so § 6c and § 7c hit the same `uvicorn` process at different path prefixes.

### 7a. Homepage link

| ID | Steps | Expected |
|---|---|---|
| 7a.1 | Open `https://wongvin.github.io/firstcontact/`. | Bottom-right shows two stacked glass-card links: "DigiKey search →" (top) and "Mouser search →" (bottom). Neither overlaps the "Changes made this week" panel. |
| 7a.2 | Click the Mouser link. | Navigates to `/firstcontact/mouser-search.html`. New page loads with same gradient background, a "← Home" link top-left, an `<h1>Mouser Product Search</h1>`, a subtitle, and an MPN input form (placeholder `NE555P`). |

### 7b. Backend unreachable (live site, no local server)

| ID | Steps | Expected |
|---|---|---|
| 7b.1 | On the live `/mouser-search.html` with no local backend running, type `NE555P` and submit. | After a brief "Loading…", an error message appears: "Backend unreachable at `http://localhost:8000` — start the local server (see `api/server/README.md`)." Form re-enables; no console crash. |

### 7c. Local backend smoke (developer-only)

Prerequisite: combined backend up per `api/server/README.md` with a real `MOUSER_API_KEY` (and DigiKey credentials if you'll also run § 6c against the same process).

| ID | Steps | Expected |
|---|---|---|
| 7c.1 | `curl http://localhost:8000/health` | Returns `{"status":"ok"}`. (Same `/health` endpoint covers both distributors.) |
| 7c.2 | `curl 'http://localhost:8000/mouser/pricing?manufacturer_part_number=NE555P'` | HTTP 200 with JSON containing `manufacturer_part_number`, `mouser_part_number`, `currency`, non-empty `tiers` array (sorted ascending by `quantity`), and a `unit_price` / `tier_quantity` pair matching `tiers[-2]` (or `tiers[0]` if fewer than 2 entries). |
| 7c.3 | Serve `web/` locally (`cd web && python3 -m http.server 8080`), open `http://localhost:8080/mouser-search.html`, type a known MPN, submit. | Headline renders as `Qty <N> → $<P> USD / unit` with both numbers in the same large font weight/size. A muted line below shows `<MPN>  ·  Mouser: <Mouser-PN>`. No tier table appears. |
| 7c.4 | Submit a bogus MPN like `NOTAPART_xyz`. | After "Loading…", an error message renders ("Part not found" surfaced as a 502 from the proxy), not the headline. |
| 7c.5 | With one `uvicorn main:app --port 8000` from `api/server/`, open both `digikey-search.html` and `mouser-search.html` in two tabs simultaneously. Search a known MPN on each. | Each page hits its own path prefix (`/digikey/pricing` vs `/mouser/pricing`) on the same backend process. Both return their respective headlines. Network tab shows both responses coming from `localhost:8000`. |

### 7d. Defense-in-depth

| ID | Steps | Expected |
|---|---|---|
| 7d.1 | DevTools → Elements → after a successful search, inspect the `.headline` and `.part-line` nodes. | Inner content is Text nodes only — no nested markup injected from the backend response. (Confirms `document.createElement` + `textContent` / `createTextNode` rendering path, mirroring the DigiKey page.) |

## 8. Claude Code transcript viewer (issue #33)

The `web/transcripts-viewer.html` page is a static frontend that calls the combined backend at `http://localhost:8000/claudecode/timeline` (`api/server/`). The backend reads JSONL files from `~/.claude/projects/**/*.jsonl` and returns a globally-sorted timeline of `(user_prompt, assistant_response)` pairs with per-day buckets. No external API, no credentials — purely local file read.

> **Refined in #35 — see § 9 below for the new layout cases.** 8a/8b still apply unchanged. 8c.7 (textarea-focus exemption) is obsolete since the textarea is gone in #35; the replacement regression case lives in § 9f.

### 8a. Homepage link

| ID | Steps | Expected |
|---|---|---|
| 8a.1 | Open `https://wongvin.github.io/firstcontact/`. | Bottom-right shows three stacked glass-card links: `DigiKey search →`, `Mouser search →`, `Transcripts viewer →`. |
| 8a.2 | Click the Transcripts-viewer link. | Navigates to `/firstcontact/transcripts-viewer.html`. Page loads with the same gradient background, a "← Home" link top-left, a "Response" card occupying most of the page, a datetime line beneath it, a `<textarea readonly>` prompt editbox, and a `↑↓ prompts · ←→ days` help line. |

### 8b. Backend unreachable (live site, no local server)

| ID | Steps | Expected |
|---|---|---|
| 8b.1 | On the live `/transcripts-viewer.html` with no local backend running, wait for the initial load. | Response card shows: "Backend unreachable at `http://localhost:8000` — start the local server (see `api/server/README.md`)." No console crash. |

### 8c. Local-backend smoke (developer-only)

Prerequisite: combined backend up per `api/server/README.md` (`.env` doesn't need credentials for this endpoint — the timeline parser only reads local JSONL files).

| ID | Steps | Expected |
|---|---|---|
| 8c.1 | `curl http://localhost:8000/health` | Returns `{"status":"ok"}`. |
| 8c.2 | `curl -s 'http://localhost:8000/claudecode/timeline' \| jq '{prompts: (.prompts\|length), days: (.days\|length), first: .prompts[0]}'` | Returns JSON with non-empty `prompts` and `days` counts; the first prompt has `user_text`, `response_text`, `timestamp`, `session_id` strings. |
| 8c.3 | Serve `web/` locally (`cd web && python3 -m http.server 8080`), open `http://localhost:8080/transcripts-viewer.html`. | Latest prompt's response renders in the top card; datetime label shows above the prompt editbox; the prompt textarea contains the user's prompt text. No "Prompt #N of M" line, no session-id chip, no sidebar, no session dropdown. |
| 8c.4 | Press ↓ a few times. | The response card and prompt textarea update. The prompt index increments — may cross into a different session_id (verify by reading the timeline payload's `session_id` for the displayed prompt; it can change). |
| 8c.5 | Press ←. | Jumps back to the previous day's first prompt. May cross session boundaries cleanly (the days array is global). |
| 8c.6 | Press → from the same prompt. | Jumps to the next day's first prompt. |
| 8c.7 | Click into the prompt `<textarea>`, then press ↑ or ↓. | Cursor moves *within* the textarea (text-select navigation); the page does NOT advance to a different prompt. Click outside to resume global navigation. |
| 8c.8 | Refresh the page with `?prompt=5` appended. | The viewer loads with the 5th prompt (global index) shown. |

### 8d. Defense-in-depth

| ID | Steps | Expected |
|---|---|---|
| 8d.1 | DevTools → Elements → inspect the response card's body span. | Inner content is Text nodes only — no nested markup injected from the JSONL response (confirms `textContent` rendering path). |
| 8d.2 | Inspect the prompt textarea. | Element is `<textarea readonly>` with a `.value` property set; no inner HTML. Even if a JSONL line contained `<script>...</script>`, it would appear as literal text in the textarea. |

## 9. Claude Code transcripts viewer — layout refinement (issue #35)

Issue #35 collapses the viewer to a single output box with a single prompt line above the response body. The prompt line normally reads `<date> <time> User: <prompt>`; when the previous response ends with `?`, the line is prefixed with the Claude question so it reads `<date> <time> Claude: <question> User: <prompt>` on the same line (no separate Claude row, same `User:` separator in both cases). Time renders as `hh:mm AM/PM` (zero-padded hour). The prompt line itself is a bold dark-navy text on a near-white pill for high contrast against the response body. The read-only prompt textarea is removed. The response body uses a hand-rolled markdown subset (no external dependencies; built via `createElement` + `textContent`).

### 9a. Layout shape

| ID | Steps | Expected |
|---|---|---|
| 9a.1 | DevTools → Elements panel. | No `<textarea>` anywhere in the document. No `#claude-line` either. An `<article id="output-card">` is present, containing exactly two children in order: `<div id="prompt-line">` and `<div id="response-body">`. |
| 9a.2 | Inspect `.output-card` computed styles. | Same glass-card look as before — `rgba(255, 255, 255, 0.12)` background, blur, rounded border, `overflow-y: auto`. |
| 9a.3 | Inspect `#prompt-line` computed `font-family`, `color`, `font-weight`, and `background-color`. | Font family resolves to the fixed-width stack (`ui-monospace`, `SFMono-Regular`, `Menlo`, monospace). Color is the dark navy (`rgb(26, 26, 46)` / `#1a1a2e`). Font weight ≥ 700. Background is the near-white pill (`rgba(255, 255, 255, 0.88)`). |
| 9a.4 | Inside `#prompt-line`, find the `<span class="time-chip">`. | Wraps just the time portion (`hh:mm AM\|PM`). No special styling — the span exists as a DOM hook in case future styling is added, but currently renders identically to plain text. The date prefix and the `User:` (or `Claude:` … `User:`) suffix are plain text nodes outside the chip. |

### 9b. Datetime format (hh:mm AM/PM)

| ID | Steps | Expected |
|---|---|---|
| 9b.1 | Navigate to any prompt whose previous response does NOT end with `?` (no Claude prefix). | The `#prompt-line` text reads `YYYY-MM-DD hh:mm AM\|PM User: <prompt>` — **hour zero-padded** (e.g. `01:05 PM`, `09:07 AM`), minute zero-padded; the datetime is the **prompt's** own timestamp. The `hh:mm AM\|PM` portion is inside `<span class="time-chip">` (currently unstyled). |
| 9b.2 | Navigate to a prompt whose previous response ends with `?` (Claude prefix present). | The `#prompt-line` text reads `YYYY-MM-DD hh:mm AM\|PM Claude: <question> User: <prompt>` — and the leading datetime is the **previous** prompt's timestamp (when Claude asked the question), not the current prompt's. Same `User:` separator (with colon) as the no-prefix case, not the old `(User)` form. |
| 9b.3 | If a prompt with a midnight (00:xx) or noon (12:xx) timestamp exists: navigate to it. | Renders as `12:xx AM` (midnight) or `12:xx PM` (noon) — not `00:xx AM` or `12:xx AM` for noon. |
| 9b.4 | Pick a prompt timestamp known to fall in the 1–9 AM/PM range. | Hour renders zero-padded: `01:05 PM`, `09:30 AM` — not `1:05 PM` / `9:30 AM`. |

### 9c. Question prefix on the prompt line

| ID | Steps | Expected |
|---|---|---|
| 9c.1 | Navigate to a prompt whose **previous** prompt's `response_text` ends with `?` (peek at the timeline JSON to find one). | `#prompt-line` reads `<date> <time-chip> Claude: <last-question> User: <prompt>` on a single line — no separate Claude row above. `<last-question>` is just the last sentence/line ending in `?`, not the whole previous response. |
| 9c.2 | Navigate to a prompt whose previous response does NOT end with `?`. | `#prompt-line` reads `<date> <time-chip> User: <prompt>` — no Claude prefix, just `User:` after the time chip. |
| 9c.3 | Set `?prompt=0` in the URL and reload. | Same as 9c.2 — no Claude prefix (no previous prompt to derive a question from). |
| 9c.4 | If a transcript pair exists where the previous response is multi-sentence ending with `...First sentence. What about X?`: navigate to it. | The prefix portion shows just `What about X?` (between `Claude: ` and ` User: `) — not the full multi-sentence text. |

### 9d. Markdown rendering

Seed a response (DevTools Local Overrides on `/claudecode/timeline`, Appendix E) that contains all of:
- a markdown link `[example](https://example.com)`
- a bare URL `https://example.org`
- a fenced code block (triple backticks, `js` language tag, a couple of lines)
- inline code: `` `inlineCode` ``
- an `## h2 heading`
- an unordered list (two `- item` lines)
- an ordered list (two `1. item` / `2. item` lines)
- `**bold**` and `*italic*` text
- a GFM table (header row, `|---|---|` separator, two body rows; at least one cell containing inline markdown like `` `code` ``, `[link](url)`, `**bold**`)

| ID | Steps | Expected |
|---|---|---|
| 9d.1 | Navigate to the seeded prompt. | Every markdown construct renders with the appropriate element: `<a>` for both link forms, `<pre><code>` for the fenced block, inline `<code>` for the inline span, `<h2>` for the heading, `<ul><li>` / `<ol><li>` for the lists, `<strong>` and `<em>` for bold/italic. |
| 9d.2 | Click the rendered `[example](https://example.com)` link. | Opens `https://example.com` in a **new tab** (the rendered `<a>` carries `target="_blank"` and `rel="noopener noreferrer"`). The original transcripts-viewer tab stays where it was. |
| 9d.3 | Inspect the fenced-code `<pre>` element. | `background` is the dim translucent block style; `overflow-x: auto` so wide code scrolls horizontally inside the block (page itself doesn't gain a horizontal scrollbar). |
| 9d.4 | Inspect the rendered GFM table in the Elements panel. | DOM is `<table><thead><tr><th>...</th></tr></thead><tbody><tr><td>...</td></tr>...</tbody></table>`. Each cell's inline markdown renders as its own child element — the inline tokenizer is run per cell. |
| 9d.5 | A response containing a single line with a `\|` character but NO `\|---\|---\|` separator line below it. | The line renders as a paragraph, not a table. (The table detector requires both the header pipes AND the separator on the next line.) |
| 9d.6 | Seed a response with inline code containing an absolute plan-file path, e.g. `` `/Users/vwong/.claude/plans/plan-foo.md` `` (with and without a `:42` line suffix). Inspect each in Elements. | DOM is `<a class="plan-path" href="vscode://file/Users/vwong/.claude/plans/plan-foo.md" target="_blank" rel="noopener noreferrer"><code>…</code></a>`. The trailing `:LINE` (and optional `:COL`) is preserved in the href. |
| 9d.7 | Seed a response with inline code that is NOT a plan path: `` `ChangeLog.md` ``, `` `web/transcripts-viewer.html` ``, `` `/Users/vwong/repos/firstcontact/api/server/main.py` ``, `` `~/.claude/plans/foo.md` ``, `` `/Users/vwong/.claude/skills/foo.md` ``, `` `42-foo` ``. | Each renders as a plain `<code>` element — no `<a>` wrapper. Only absolute paths matching `<root>/.claude/plans/<name>.md` are wrapped. |
| 9d.8 | Click a rendered plan-path link. | Browser hands off to the `vscode:` URI handler — VS Code is invoked and opens the plan file at the absolute path. |

### 9e. Defense-in-depth (no `innerHTML` on API strings)

Seed a response (Appendix E) where `response_text` contains all of:
- `<script>alert('xss-1')</script>`
- `<img src=x onerror="alert('xss-2')">`
- A markdown link with a `javascript:` URL: `[evil](javascript:alert('xss-3'))`
- A markdown link with a `data:` URL: `[evil](data:text/html,<script>alert(1)</script>)`

And edit a `user_text` to `<b>raw</b>`.

| ID | Steps | Expected |
|---|---|---|
| 9e.1 | Hard-refresh on the seeded prompt. | No alert dialog opens. Console shows no XSS errors. |
| 9e.2 | DevTools Elements → inspect `#response-body`. | No `<script>` element, no `<img>` element. The raw `<script>...</script>` and `<img ...>` strings appear as literal text nodes (visible angle brackets in the rendered text). |
| 9e.3 | Inspect the rendered `[evil](javascript:...)` markdown. | Renders as literal text `[evil](javascript:alert('xss-3'))` — no `<a>` element created. Same for the `data:` URL. |
| 9e.4 | Inspect `#user-line`. | Text content includes the literal string `<b>raw</b>` — no `<b>` element created. |

### 9f. State preservation (regression — replaces obsolete 8c.7)

| ID | Steps | Expected |
|---|---|---|
| 9f.1 | Repeat 8c.4 (press ↓ several times). | Each press advances one prompt — output card swaps content. URL `?prompt=N` updates each time. |
| 9f.2 | Repeat 8c.5 (press ←). | Jumps to previous day's remembered prompt (or first if none remembered). |
| 9f.3 | Repeat 8c.6 (press →). | Symmetric forward jump. |
| 9f.4 | Repeat 8c.8 (`?prompt=5` reload). | Viewer loads with global prompt index 5. |
| 9f.5 | **(Replaces obsolete 8c.7.)** Click anywhere inside `#response-body`, then press ↓. | Page advances to the next prompt — no focus trap (the textarea exemption is gone with the textarea). |
| 9f.6 | Navigate forward through a day boundary via ↓ until you land on the first prompt of a new day. Press ← back into the previous day, then → again. | Returns to the same prompt index you were on (day-position memory still works). |

### 9g. Cross-browser

| ID | Steps | Expected |
|---|---|---|
| 9g.1 | Repeat 9a.1, 9d.1, 9f.5 in Safari (desktop). | All pass. `backdrop-filter` still renders the card as translucent. Markdown children render the same. |

### 9h. CSS polish (visual fidelity check)

| ID | Steps | Expected |
|---|---|---|
| 9h.1 | Eyeball the `#prompt-line`. | Renders as a near-white pill (`rgba(255,255,255,0.88)` background) with bold (`font-weight: 700`) dark navy text (`#1a1a2e`), padded `0.4rem 0.7rem`, rounded `0.4rem` corners. Stands out clearly against the response body's white-on-purple text below it. |
| 9h.2 | Inspect `.response-body` computed `font-family` and `font-weight`. Inspect inline `<code>` computed `font-family` and `font-weight`. | Body prose: sans-serif system stack (`-apple-system`, `BlinkMacSystemFont`, …, inherited from `body`) at `font-weight: 300` (light). Inline `<code>`: `ui-monospace, SFMono-Regular, Menlo, monospace` at `font-weight: 700`. **The visual distinction between body prose and inline code is light-sans-serif vs bold-monospace — typography only, no background tint.** |
| 9h.3 | Inspect inline `<code>` computed `font-weight`. | Resolves to `700` (bold). Inline code's visual cues: monospace family + bold weight. No `background-color`, no `border`. Dark backgrounds are reserved for hyperlinks (9h.5). |
| 9h.4 | Inspect a fenced `<pre>` block and its inner `<code>`. | `<pre>` has a thin translucent border (`rgba(255,255,255,0.18)`) and rounded corners — no dark fill. Inner `<code>` inherits `font-weight: 700` from the `.response-body code` rule, so multi-line code blocks render in bold monospace. Wide content scrolls horizontally inside the block (`overflow-x: auto`); the page doesn't gain a horizontal scrollbar. |
| 9h.5 | On a response containing a markdown link, eyeball the rendered `<a>`. | The link is a clearly marked dark pill — `color: #cfe0ff` over `background: rgba(0, 0, 0, 0.32)` with `border-radius: 4px` and `padding: 0.05rem 0.3rem`. Underline at faint `rgba(207, 224, 255, 0.5)`. Hyperlinks are the *only* element type with a dark background on the page. |
| 9h.6 | Hover over the rendered `<a>`. | Background darkens to `rgba(0, 0, 0, 0.5)`; underline brightens to `#cfe0ff`. Cursor is the pointer. |
| 9h.7 | On a response containing `**bold**` text, inspect the rendered `<strong>`. | Computed `font-weight` is `700`. No background, no border. Boldness comes from weight alone. |
| 9h.8 | On a response containing a plan-path inline code, inspect it. | The outer `<a class="plan-path">` carries the dark pill (inherits from the general `<a>` rule); the inner `<code>` inherits its color and font from the link — so the visual is a single dark pill with monospace link-colored text. No stacked layers. |
| 9h.9 | On a response with a rendered table, eyeball it. | The table has visible cell borders (`rgba(255,255,255,0.2)`); the header row has a slightly lighter (not dark) background (`rgba(255,255,255,0.08)`); header text is bold (`font-weight: 600`). Cell padding `0.3rem 0.6rem`. |
| 9h.10 | Side-by-side: open the same response in a Claude.ai chat window AND in the transcripts viewer. | Visual structure matches — sans-serif body prose, monospace code without background tint, bold text via weight, hyperlinks clearly marked as dark pills, tables look like tables. Exact colors differ (Claude.ai light theme vs the viewer's purple gradient) but structural fidelity holds. |

## Exit criteria

A change ships when:

1. All test cases above for **affected features** pass.
2. `gh api /repos/wongvin/firstcontact/pages/builds/latest --jq .status` returns `built` for the commit under test.
3. iPhone visual smoke test (open production URL on a real iPhone over cellular) confirms the headline + new feature both render.

## Notes

- This plan is manual-execution only. No automated test runner is set up (and none is justified at the project's current size).
- For each new issue, append a section above (e.g. `## 6. Foo feature (issue #N)`) and update the in-scope list. Don't delete sections for shipped features — they're regression-coverage.

---

## Appendix: DevTools procedures (Chrome)

These are written for Chrome DevTools on macOS. Safari Web Inspector is broadly equivalent but menu paths differ.

### A. Open DevTools

- Cmd-Option-I → opens the last-used panel.
- Cmd-Option-J → opens directly to Console.
- Right-click any element → **Inspect** → opens to Elements with that node selected.

### B. Set a JS breakpoint

1. Open DevTools → **Sources** tab.
2. In the left file tree, expand `wongvin.github.io/firstcontact/` and open `(index)` (or `index.html`).
3. Click the line number where you want to pause. A blue marker appears.
4. Hard-refresh (Cmd-Shift-R). Execution pauses at the marker; the Sources panel highlights the current line.
5. Inspect or modify variables in the Console (still paused) — e.g. `recent.length = 0`.
6. Click the blue ▶ Resume button (top-right of Sources) or press F8 to continue.
7. Right-click the breakpoint marker → **Remove breakpoint** when done.

### C. Block a request URL

1. DevTools → **Network** tab.
2. Click the ⋮ (overflow) menu in the Network toolbar → **Block request URL** OR press Cmd-Shift-P → "Show Request Blocking".
3. In the Network request blocking pane, click **+ Add pattern** → enter the pattern (e.g. `*api.github.com*`) → Enter.
4. Ensure the "Enable request blocking" checkbox is on.
5. Hard-refresh (Cmd-Shift-R). Blocked requests show as red in the Network log.
6. Uncheck or remove the pattern when done.

### D. Throttle the network / Offline

1. DevTools → **Network** tab.
2. In the throttling dropdown (next to the Disable cache checkbox, defaults to "No throttling"), choose **Offline** or a preset like "Slow 3G".
3. Hard-refresh.
4. Restore to "No throttling" when done.

### E. Override a fetch response (Local Overrides)

1. DevTools → **Network** tab. Hard-refresh so the request you want to override appears.
2. Right-click the request (e.g. the `/issues?...` one) → **Override content**.
3. If prompted to choose a folder, pick or create one (e.g. `~/devtools-overrides/`). Click **Allow** in the permission prompt.
4. The response body opens in the Sources panel as an editable file.
5. Edit the JSON (e.g. change one `title` field). Save with Cmd-S.
6. Hard-refresh — DevTools serves your modified body in place of the network response.
7. To clear: Sources → **Overrides** tab → uncheck "Enable Local Overrides", or delete the override file.

### F. Toggle JavaScript on/off

1. Cmd-Shift-P (in DevTools) → type "Disable JavaScript" → Enter.
2. Reload the page to test the no-JS state.
3. Cmd-Shift-P → "Enable JavaScript" when done. (Closing DevTools also re-enables.)

### G. Resize viewport (Device toolbar)

1. Cmd-Shift-M, or click the device-toolbar icon (two-rectangle icon, top-left of DevTools).
2. Choose a preset device (top center: "iPhone SE", "iPad", etc.) or "Responsive" for a custom width.
3. For custom widths, type values directly into the dimension boxes (e.g. `360 × 640`).
4. Reload to ensure media queries re-apply on resize.
5. Click the device-toolbar icon again to exit.

### H. Inspect element — Computed styles, Accessibility, Keyboard

1. Right-click the element on the page → **Inspect**, OR click the node in the Elements tree.
2. In the **Styles** pane (right side), see authored CSS rules and overrides.
3. Switch the same pane's tab to **Computed** to see resolved values (e.g. `25vh` → `225px`). Use the filter box for fast lookup.
4. Switch to **Accessibility** to see the computed accessible name, role, and ARIA attributes.
5. **Keyboard navigation**: click the address bar to clear focus, then press Tab to advance. Watch for the focus-ring outline. Shift-Tab moves backward.

### I. Lighthouse audit

1. DevTools → **Lighthouse** tab.
2. Categories: tick only the ones you care about (e.g. just "Accessibility" for test 5.5).
3. Mode: "Navigation". Device: "Desktop" or "Mobile" (run both for thorough coverage).
4. Click **Analyze page load**. Wait ~30s.
5. Review the report. Each flagged item links to remediation guidance.

### J. Test on a real iPhone

1. Ensure the iPhone is on a network with internet (cellular or WiFi).
2. In iPhone Safari, open https://wongvin.github.io/firstcontact/.
3. Test in both portrait and landscape orientations.
4. **Optional — pair with desktop Safari Web Inspector for debugging:**
   - On iPhone: Settings → Safari → Advanced → toggle **Web Inspector** on, plug into Mac via USB.
   - On Mac: Safari → Develop menu → `<your iPhone name>` → select the open tab.
   - You now have a desktop DevTools-like inspector for the iPhone page.
