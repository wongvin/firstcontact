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
| 4a.4 | Same. | Each entry is **plain text** — no underlined link, no `(Xh ago)` timestamp, no icon. Item-level hover does not change the cursor. **Panel-level hover** (since #79) does — the whole `#recent-tasks` panel shows `cursor: pointer` and a faint background-brightness shift, and a small `⟳` glyph sits at the top-right. The full tap-cycle behavior is covered by § 4f. |
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

### 4f. View rotation mechanic (issue #79)

`#recent-tasks` is tappable: each tap (or `Enter` / `Space` while focused) cycles the panel's body content through three views, then back to view 1. View 2 and view 3 are placeholder lines for this issue — the body reads `View 2: Work in progress` and `View 3: Work in progress` respectively (the 1-based view number is embedded so the user can see which view they're on without an extra indicator). Real angles land in follow-up issues. The cycle counter resets on page reload.

| ID | Steps | Expected |
|---|---|---|
| 4f.1 | Hard-refresh. | View 1 renders — numbered list of recent issues (existing behavior, indistinguishable from § 4a.3). |
| 4f.2 | Click anywhere inside the panel (e.g. on the heading text). | View 2 renders — panel body is now a single un-bulleted `View 2: Work in progress` line (the `<ol>` contains exactly one `<li class="empty">View 2: Work in progress</li>`). |
| 4f.3 | Click again. | View 3 — body reads `View 3: Work in progress`. The view number distinguishes it from view 2. |
| 4f.4 | Click again. | Cycles back to view 1. The full numbered list re-renders, matching what § 4a.3 expects. |
| 4f.5 | Tab into the panel (`#recent-tasks` is `role="button"` `tabindex="0"`). Confirm a focus ring or background-brightness change indicates focus. Press `Enter`. Then press `Space`. | `Enter` and `Space` each advance one view, parallel to a tap. |
| 4f.6 | After 4f.3 (cycled to view 3), hard-refresh. | Panel is back to view 1. View counter is in-memory only — no `localStorage` entry created. |
| 4f.7 | Block the GitHub API URL (Appendix C) and hard-refresh. Panel shows `Could not load recent changes.` in view 1. Click. | View 2 renders `View 2: Work in progress`. Click again → view 3 (`View 3: Work in progress`). Click again → back to view 1's `Could not load recent changes.`. The error state cycles cleanly with no crash and no stale list. |
| 4f.8 | DevTools → Elements → select the `<aside id="recent-tasks">` node → confirm attributes: `role="button"`, `tabindex="0"`, `aria-live="polite"`, `aria-label="Changes made this week. Tap to cycle view."`. | All four present. The `<span class="cycle-glyph" aria-hidden="true">⟳</span>` child is present right after the opening `<aside>` tag. |
| 4f.9 | Wait for view 1 to fully render (the issue list, not just `Loading…`). Note the panel's rendered height (DevTools → Elements → hover the panel for the layout overlay, or read `getBoundingClientRect().height` in the Console). Tap to advance to view 2. | Panel height is **unchanged** — the `View 2: Work in progress` placeholder occupies a panel of the same height as view 1, with empty space below the text. DevTools → Elements → `#recent-tasks` shows an inline `style="min-height: <Npx>"` matching the view-1 height. Tap to view 3 → same. Tap back to view 1 → same height (full list re-renders within the locked size). |

## 5. Cross-browser / accessibility quick checks

| ID | Steps | Expected |
|---|---|---|
| 5.1 | Repeat 2.1, 3.1, 4a.1 in Safari (desktop). | All pass. The `backdrop-filter` (with `-webkit-` prefix) renders the panel as translucent / blurred (not a hard solid color). |
| 5.2 | Repeat 2.1, 3.1, 4a.1 on iPhone Safari (Appendix J). | All pass. Panel is translucent and legible. |
| 5.3 | Click the address bar, then press Tab repeatedly (Appendix H, "Keyboard navigation"). | No focusable elements exist in the page itself (no inputs, no anchors, no buttons), so Tab moves out of the page on the first press. No focus traps; no errors. |
| 5.4 | DevTools → Elements → select the `<aside id="recent-tasks">` node → switch the right pane to **Accessibility** (Appendix H). | "Computed Properties" shows `name: Changes made this week` and `role: complementary`. The `<h2>` is also reachable via the Accessibility tree as a Heading landmark. |
| 5.5 | Run a Lighthouse Accessibility audit (Appendix I). | Score ≥ 90. Investigate any flagged item (e.g. contrast warnings on translucent panel text). |

## 6. Product search (issue #20)

The `web/digikey-search.html` page is a static frontend that calls a **local** Python FastAPI backend at `http://localhost:8001/digikey/...` (`api/server/`). The live deployed page exists but is non-functional unless the user has the combined backend running with their own DigiKey credentials. Since #26, the DigiKey and Mouser backends share one process — see § 7 for the Mouser-side smoke tests against the same server.

### 6a. Homepage link

| ID | Steps | Expected |
|---|---|---|
| 6a.1 | Open `https://wongvin.github.io/firstcontact/`. | Bottom-right shows a "Product search →" link in the glass-card style; does not overlap the "Changes made this week" panel. |
| 6a.2 | Click the link. | Navigates to `/firstcontact/digikey-search.html`. New page loads with same gradient background, a "← Home" link top-left, an `<h1>DigiKey Product Search</h1>`, a subtitle, and an MPN input form. |

### 6b. Backend unreachable (live site, no local server)

| ID | Steps | Expected |
|---|---|---|
| 6b.1 | On the live `/digikey-search.html` with no local backend running, type `STM32F407VGT6` and submit. | After a brief "Loading…", an error message appears: "Backend unreachable at `http://localhost:8001` — start the local server (see `api/server/README.md`)." Form re-enables; no console crash. |

### 6c. Local backend smoke (developer-only)

Prerequisite: combined backend up per `api/server/README.md` with real `DIGIKEY_CLIENT_ID` / `DIGIKEY_CLIENT_SECRET` (and `MOUSER_API_KEY` if you'll also run § 7c).

| ID | Steps | Expected |
|---|---|---|
| 6c.1 | `curl http://localhost:8001/health` | Returns `{"status":"ok"}`. |
| 6c.2 | `curl 'http://localhost:8001/digikey/pricing?manufacturer_part_number=STM32F407VGT6'` | HTTP 200 with JSON containing `manufacturer_part_number`, `digikey_part_number`, `currency: "USD"`, non-empty `tiers` array (sorted ascending by `quantity`), and a `unit_price` / `tier_quantity` pair matching `tiers[-2]` (or `tiers[0]` if fewer than 2 entries). |
| 6c.3 | Serve `web/` locally (`cd web && python -m http.server 8080`), open `http://localhost:8080/digikey-search.html`, type a known MPN, submit. | Headline renders as `Qty <N> → $<P> USD / unit` with both numbers in the same large font weight/size. A muted line below shows `<MPN>  ·  DK: <DigiKey-PN>`. No tier table appears. |
| 6c.4 | Submit a bogus MPN like `NOTAPART_xyz`. | After "Loading…", an error message renders (DigiKey 404 surfaced as a 502 from the proxy with a "Part not found" detail), not the headline. |

### 6d. Defense-in-depth

| ID | Steps | Expected |
|---|---|---|
| 6d.1 | DevTools → Elements → after a successful search, inspect the `.headline` and `.part-line` nodes. | Inner content is Text nodes only — no nested `<a>`, `<span>` (except the deliberate ones), and certainly no markup injected from the backend response. (Confirms `document.createElement` + `textContent` / `createTextNode` rendering path.) |

## 7. Mouser product search (issue #24)

The `web/mouser-search.html` page is a static frontend that calls a **local** Python FastAPI backend at `http://localhost:8001/mouser/...` (`api/server/`). Same shape as § 6 but for Mouser; since #26 both distributors share the single backend on port 8001, so § 6c and § 7c hit the same `uvicorn` process at different path prefixes.

### 7a. Homepage link

| ID | Steps | Expected |
|---|---|---|
| 7a.1 | Open `https://wongvin.github.io/firstcontact/`. | Bottom-right shows two stacked glass-card links: "DigiKey search →" (top) and "Mouser search →" (bottom). Neither overlaps the "Changes made this week" panel. |
| 7a.2 | Click the Mouser link. | Navigates to `/firstcontact/mouser-search.html`. New page loads with same gradient background, a "← Home" link top-left, an `<h1>Mouser Product Search</h1>`, a subtitle, and an MPN input form (placeholder `NE555P`). |

### 7b. Backend unreachable (live site, no local server)

| ID | Steps | Expected |
|---|---|---|
| 7b.1 | On the live `/mouser-search.html` with no local backend running, type `NE555P` and submit. | After a brief "Loading…", an error message appears: "Backend unreachable at `http://localhost:8001` — start the local server (see `api/server/README.md`)." Form re-enables; no console crash. |

### 7c. Local backend smoke (developer-only)

Prerequisite: combined backend up per `api/server/README.md` with a real `MOUSER_API_KEY` (and DigiKey credentials if you'll also run § 6c against the same process).

| ID | Steps | Expected |
|---|---|---|
| 7c.1 | `curl http://localhost:8001/health` | Returns `{"status":"ok"}`. (Same `/health` endpoint covers both distributors.) |
| 7c.2 | `curl 'http://localhost:8001/mouser/pricing?manufacturer_part_number=NE555P'` | HTTP 200 with JSON containing `manufacturer_part_number`, `mouser_part_number`, `currency`, non-empty `tiers` array (sorted ascending by `quantity`), and a `unit_price` / `tier_quantity` pair matching `tiers[-2]` (or `tiers[0]` if fewer than 2 entries). |
| 7c.3 | Serve `web/` locally (`cd web && python3 -m http.server 8080`), open `http://localhost:8080/mouser-search.html`, type a known MPN, submit. | Headline renders as `Qty <N> → $<P> USD / unit` with both numbers in the same large font weight/size. A muted line below shows `<MPN>  ·  Mouser: <Mouser-PN>`. No tier table appears. |
| 7c.4 | Submit a bogus MPN like `NOTAPART_xyz`. | After "Loading…", an error message renders ("Part not found" surfaced as a 502 from the proxy), not the headline. |
| 7c.5 | With one `uvicorn main:app --port 8001` from `api/server/`, open both `digikey-search.html` and `mouser-search.html` in two tabs simultaneously. Search a known MPN on each. | Each page hits its own path prefix (`/digikey/pricing` vs `/mouser/pricing`) on the same backend process. Both return their respective headlines. Network tab shows both responses coming from `localhost:8001`. |

### 7d. Defense-in-depth

| ID | Steps | Expected |
|---|---|---|
| 7d.1 | DevTools → Elements → after a successful search, inspect the `.headline` and `.part-line` nodes. | Inner content is Text nodes only — no nested markup injected from the backend response. (Confirms `document.createElement` + `textContent` / `createTextNode` rendering path, mirroring the DigiKey page.) |

## 8. Claude Code transcript viewer (issue #33)

The `web/transcripts-viewer.html` page is a static frontend that calls the combined backend at `http://localhost:8001/claudecode/timeline` (`api/server/`). The backend reads JSONL files from `~/.claude/projects/**/*.jsonl` and returns a globally-sorted timeline of `(user_prompt, assistant_response)` pairs with per-day buckets. No external API, no credentials — purely local file read.

> **Refined in #35 — see § 9 below for the new layout cases.** 8a/8b still apply unchanged. 8c.7 (textarea-focus exemption) is obsolete since the textarea is gone in #35; the replacement regression case lives in § 9f.

### 8a. Homepage link

| ID | Steps | Expected |
|---|---|---|
| 8a.1 | Open `https://wongvin.github.io/firstcontact/`. | Bottom-right shows three stacked glass-card links: `DigiKey search →`, `Mouser search →`, `Transcripts viewer →`. |
| 8a.2 | Click the Transcripts-viewer link. | Navigates to `/firstcontact/transcripts-viewer.html`. Page loads with the same gradient background, a "← Home" link top-left, a "Response" card occupying most of the page, a datetime line beneath it, a `<textarea readonly>` prompt editbox, and a `↑↓ prompts · ←→ days` help line. |

### 8b. Backend unreachable (live site, no local server)

| ID | Steps | Expected |
|---|---|---|
| 8b.1 | On the live `/transcripts-viewer.html` with no local backend running, wait for the initial load. | Response card shows: "Backend unreachable at `http://localhost:8001` — start the local server (see `api/server/README.md`)." No console crash. |

### 8c. Local-backend smoke (developer-only)

Prerequisite: combined backend up per `api/server/README.md` (`.env` doesn't need credentials for this endpoint — the timeline parser only reads local JSONL files).

| ID | Steps | Expected |
|---|---|---|
| 8c.1 | `curl http://localhost:8001/health` | Returns `{"status":"ok"}`. |
| 8c.2 | `curl -s 'http://localhost:8001/claudecode/timeline' \| jq '{prompts: (.prompts\|length), days: (.days\|length), first: .prompts[0]}'` | Returns JSON with non-empty `prompts` and `days` counts; the first prompt has `user_text`, `response_text`, `timestamp`, `session_id` strings. |
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

## 10. Claude Code transcripts viewer — VIM search and navigation (issue #45)

Issue #45 layers VIM-style cursor navigation and search on top of the #35 layout. The cursor is a `<span class="cursor">` that WRAPS the character at the cursor position (darker translucent-black background pill), inserted into `#response-body`. All movement and search operates in **rendered-text** coordinates — i.e. `responseBodyEl.textContent` split by `\n`. The renderer inserts synthetic `\n` text nodes between sibling blocks (between paragraphs, headings, code blocks, tables, etc.) and between list items, so block boundaries become real `\n`s in textContent — `j/k/G` see paragraph and list-item breaks as line separators. These `\n` text nodes are visually inert (browsers collapse whitespace between block-level siblings). Search runs over rendered text across **all prompts in the global timeline**; `user_text` is NOT searched. Existing arrow keys (↑↓ prompts, ←→ days) are unchanged. The new search-input textbox sits between `#output-card` and the help line, left-aligned, ~20 chars wide.

### 10a. Cursor on load

| ID | Steps | Expected |
|---|---|---|
| 10a.1 | Open the viewer (initial render). | A blinking darker-tint block is visible at the start of the response body, WRAPPING the first character of the first source line (the character stays visible, with a `rgba(0, 0, 0, 0.55)` background pill behind it). DevTools Elements: a `<span class="cursor">` containing exactly one character (or a space for an empty line) exists inside the first tagged block of `#response-body`. |
| 10a.2-bis | Move cursor to a position past the end of the displayed character (e.g. on a line with one char, press `l`). | The cursor block wraps the last character or, if at end-of-line, displays a space inside the span (visible block with no character beneath). |
| 10a.2 | DevTools Elements → inspect any block child of `#response-body`. | Each block has `data-source-line-start` and `data-source-line-end` attributes (positive integers, 1-indexed). For `<li>` and `<tr>`, the start and end are equal (one source line per item/row). |

### 10b. h/j/k/l motion

| ID | Steps | Expected |
|---|---|---|
| 10b.1 | Press `l` repeatedly. | Cursor advances one column right per press. At end of line, stops (does not wrap). |
| 10b.2 | Press `h` repeatedly. | Cursor moves one column left. At column 1, stops. |
| 10b.3 | Press `j`. | Cursor moves to the next source line. If the new line is shorter than the previous col, cursor lands at end of line. |
| 10b.4 | Press `k`. | Symmetric — cursor moves to the previous source line. |
| 10b.5 | At the last source line, press `j`. | Cursor stays put (no error). |
| 10b.6 | At line 1 col 1, press `k`. | Cursor stays put. |
| 10b.7 | On a response with multiple paragraphs (e.g. two `<p>` blocks). From the last character of the first paragraph, press `j`. | Cursor advances to the first character of the second paragraph — block boundaries count as line breaks. (Without the synthetic `\n` between blocks, `j` would have been a no-op.) |
| 10b.8 | On a response with a list (`- a\n- b\n- c`). From the cursor on "a", press `j`. | Cursor advances to "b". Press `j` again → "c". |

### 10c. `<optional line number>G`

**Feature semantics.** If no line number is entered before `G`, the cursor moves to the **first character of the last rendered line**. If a line number is entered, the cursor moves to the **first character of the line with that number** (1-indexed; rendered-text lines, where block boundaries are real `\n`s). `G` always sets col to 1; the previous column is discarded.

Implementation: a `numberPrefix` accumulator collects digit keydowns. The `G` keydown reads `parseInt(numberPrefix, 10)` (or `totalLines()` if empty), then clears the accumulator. Any non-digit non-`G` "vim-relevant" key also clears the accumulator. Modifier-only keydowns (Shift, Control, Alt, Meta, CapsLock) short-circuit at the top of the handler and do NOT clear the accumulator — so typing `1` `Shift` `G` (= `1G`) works.

#### 10c.A — Basic behavior

| ID | Steps | Expected |
|---|---|---|
| 10c.A.1 | Press `G` (no prefix). | Cursor wraps the **first character** of the **last rendered line** of the current response. Cursor col is 1. |
| 10c.A.2 | Press `1` then `G`. | Cursor wraps the first character of rendered line 1. (This is the smallest valid line number and the most common test of the prefix path.) |
| 10c.A.3 | Press `2` then `G` on a response with ≥ 2 rendered lines. | Cursor wraps the first character of rendered line 2. |
| 10c.A.4 | Press `5` then `G` on a response with ≥ 5 rendered lines. | Cursor wraps the first character of rendered line 5. |
| 10c.A.5 | After 10c.A.4, press `G` again (no prefix). | Cursor moves to the last rendered line, col 1. The number-prefix accumulator was cleared by the previous `G`, so this second `G` falls into the no-prefix branch. |

#### 10c.B — Multi-digit numbers

| ID | Steps | Expected |
|---|---|---|
| 10c.B.1 | Press `1`, `0`, `G` on a response with ≥ 10 rendered lines. | Cursor wraps the first character of rendered line 10. (Two-digit accumulator.) |
| 10c.B.2 | Press `1`, `2`, `3`, `G` on a response with ≥ 123 rendered lines. | Cursor wraps the first character of rendered line 123. |
| 10c.B.3 | Press `0`, `5`, `G`. | Per `parseInt('05', 10) === 5`, cursor moves to line 5. (Leading zeros are accepted.) |

#### 10c.C — Bounds and clamping

| ID | Steps | Expected |
|---|---|---|
| 10c.C.1 | Press `9`, `9`, `9`, `G` on a response with fewer than 999 lines. | Cursor clamps to the last rendered line. No error in the console; cursor is at last-line col 1. |
| 10c.C.2 | Press `0`, `G` on any response. | Cursor clamps to line 1, col 1. (`placeCursorAt(0, 1)` clamps to `Math.max(1, …) === 1`.) |
| 10c.C.3 | `G` on a single-line response. | Cursor stays/lands at line 1, col 1 (last line is also line 1). |
| 10c.C.4 | `1G` on a single-line response. | Cursor stays/lands at line 1, col 1. |
| 10c.C.5 | `G` on the `(no response captured)` placeholder response. | Cursor wraps the first character `(` of `(no response captured)`. |

#### 10c.D — Accumulator clearing

| ID | Steps | Expected |
|---|---|---|
| 10c.D.1 | Press `7`, then `j` (not `G`), then `G`. | The `j` advances the cursor by one line AND clears `numberPrefix`. The following `G` then jumps to the **last** line (not line 7). |
| 10c.D.2 | Press `3`, then `/`, type `foo`, press `Escape`, then `G`. | Entering search mode (`/`) clears the accumulator; the trailing `G` jumps to the last line. |
| 10c.D.3 | Press `4`, then `h`, then `G`. | `h` moves col -1 AND clears the accumulator; the trailing `G` jumps to the last line. |
| 10c.D.4 | Press `1`, `2`, then `↓` (arrow key), then `G`. | Arrow keys re-render a different prompt (and reset/restore cursor) BEFORE the digit branch could reach the accumulator. After ↓, `numberPrefix` is still `'12'` from before — but the active prompt is different. Pressing `G` afterward jumps to line 12 of the NEW prompt (or clamps to last if the new prompt has fewer lines). This is a slight surprise; documented but not considered a bug. |

#### 10c.E — Modifier interaction

| ID | Steps | Expected |
|---|---|---|
| 10c.E.1 | Press `1`, then hold Shift, then press `G` (the natural way to type `1G`). | Cursor moves to line 1, col 1. The Shift keydown short-circuits at the top of the handler so it does NOT clear the accumulator. |
| 10c.E.2 | Press `1`, `2`, then hold Shift, then press `G`. | Cursor moves to line 12 col 1. |
| 10c.E.3 | Press `1`, then Ctrl+T (or Cmd+R, any modifier+key shortcut). | The modifier-key branch at the top of the handler returns early on the Ctrl/Meta down. The browser handles the shortcut. `numberPrefix` retains `'1'`. Pressing `G` after still jumps to line 1. (Optional verification — relies on browser-specific shortcut behavior.) |

#### 10c.F — Cross-block navigation

| ID | Steps | Expected |
|---|---|---|
| 10c.F.1 | On a response with two paragraphs (`First.\n\nSecond.`), press `2G`. | Cursor wraps `S` (first character of `"Second."`). |
| 10c.F.2 | On a response with a heading + a paragraph, press `2G`. | Cursor wraps the first character of the paragraph (heading is line 1, paragraph is line 2). |
| 10c.F.3 | On a response with a 3-item list `- a / - b / - c`, press `1G`, then `2G`, then `3G`. | Cursor wraps `a`, then `b`, then `c` in turn. |
| 10c.F.4 | On a response that begins with a fenced code block of 4 lines, press `1G` through `4G`. | Cursor wraps the first character of each rendered code line in turn (the rendered code preserves source `\n`s as visible line breaks). |

#### 10c.G — Visual + state side-effects

| ID | Steps | Expected |
|---|---|---|
| 10c.G.1 | Pre-position cursor at (5, 10) via h/j/k/l, then press `1G`. | Cursor col is reset to 1 (G always sets col to 1, regardless of previous col). |
| 10c.G.2 | After `1G`, inspect `responseBodyEl.querySelectorAll('.cursor')` in DevTools. | Exactly ONE `<span class="cursor">` exists. |
| 10c.G.3 | On a response taller than the viewport so the last line is off-screen, press `G`. | The output card auto-scrolls so the cursor (on the last line) is visible. |
| 10c.G.4 | Navigate to prompt B, then back to A, then press `1G`. | Cursor lands on (1, 1) of A. A's per-prompt cursor memory may have stored a different position from the navigate-away — `1G` overrides it. |
| 10c.G.5 | Press `5G` on prompt A, then navigate ↓ to B, then back ↑ to A. | A's cursor restored to (5, 1) — `cursorByPromptIndex` saved it on the navigate-away. |

#### 10c.H — Defense-in-depth + safety

| ID | Steps | Expected |
|---|---|---|
| 10c.H.1 | Inspect the cursor span in DevTools after each `G` action. | Span is `<span class="cursor">…</span>` (one character of real content, or a space with `data-placeholder="1"` for an empty line). Class list contains only `cursor` (possibly with `data-placeholder`). No script execution. |
| 10c.H.2 | `numberPrefix` state after various sequences (verify in console via test harness). | After `1G`: `''`. After `12 / 3 G`: `''`. After `1 then j`: `''`. After `1 then Shift`: `'1'`. After raw `G` (no prefix): `''`. |

### 10d. Search entry and execution (current response)

| ID | Steps | Expected |
|---|---|---|
| 10d.1 | Press `/`. | Search bar appears (was hidden) with `/` left-aligned. Cursor stops responding to vim keys; pressing any printable key appends to the search string. |
| 10d.2 | Type `foo`. | Bar shows `/foo`. |
| 10d.3 | Press `Backspace`. | Bar shows `/fo`. Backspace at empty string (`/` only) exits search mode and clears the bar. |
| 10d.4 | Press `Enter`. | Search executes. If `foo` exists in the current response, cursor moves to its first occurrence (source-line/col mapped). Search bar clears (back to hidden). |

### 10e. Search across prompts

| ID | Steps | Expected |
|---|---|---|
| 10e.1 | From a prompt whose response does NOT contain "baz", press `/`, type `baz`, press `Enter` — where some LATER prompt's response contains "baz". | Viewer auto-jumps to that later prompt (the prompt-line at top updates to show the new prompt's metadata). Cursor lands on the match in the new response body. |

### 10f. Search wraps the timeline

| ID | Steps | Expected |
|---|---|---|
| 10f.1 | Navigate to the LAST prompt (or any prompt after which no further matches exist). Search for a string that appears only in an EARLIER prompt. | The search wraps to the start of the timeline and finds the match in the earlier prompt; viewer auto-jumps there. |

### 10g. Pattern not found

| ID | Steps | Expected |
|---|---|---|
| 10g.1 | Search for a string that doesn't exist in any response (e.g. a long random UUID). | Search bar background turns dark red (`rgba(140, 20, 20, 0.9)`), text shows `Pattern not found: <s>` in white. After 2 seconds, bar clears and returns to the hidden state. Cursor does not move. |

### 10h. n / N navigation

| ID | Steps | Expected |
|---|---|---|
| 10h.1 | After a successful search, press `n`. | Cursor moves to the next match (in the current response if any exists past current cursor; else jumps to the next prompt containing a match; else wraps). |
| 10h.2 | Press `N`. | Symmetric backward navigation. Wraps from the first match to the last. |
| 10h.3 | Press `n` with no prior search. | No-op (no error). |

### 10i. `user_text` is NOT searched

| ID | Steps | Expected |
|---|---|---|
| 10i.1 | Find a transcript where a unique string appears only in a user prompt (`user_text`), never in any `response_text`. Search for it. | `Pattern not found: <s>` — even though the string is visible on screen in the prompt line at the top of the matching prompt(s). |
| 10i.2 | Search for a string that exists in the source markdown ONLY inside markup characters (e.g. search for a triple-backtick `\`\`\`` literal). | `Pattern not found` — the markdown markup is stripped during rendering, so the rendered text doesn't contain literal backticks delimiting code fences. |
| 10i.3 | Search for a string that appears inside an inline-code span (e.g. `` `Contents.json` `` in source). | Match found. Cursor lands on the FIRST CHARACTER of the rendered string (the `C` of `Contents.json` in the rendered `<code>`), not on the backtick or anywhere else. |

### 10j. Escape cancels search

| ID | Steps | Expected |
|---|---|---|
| 10j.1 | Press `/`, type `foo`, press `Escape`. | Search bar clears (hidden state). Search does NOT execute. Cursor unchanged. |

### 10k. Modal interaction

| ID | Steps | Expected |
|---|---|---|
| 10k.1 | Press `/`, type `j`, then `Enter`. | Bar shows `/j` during typing. Enter executes a search for the literal character `j`. The cursor does NOT move down a line — `j` was captured as search input, not a vim command. |
| 10k.2 | Press `/`, type `42G`, then `Enter`. | Bar shows `/42G`. Search executes for the literal string `42G`. The `G` did NOT trigger a line-jump. |

### 10l. Arrow keys still work

| ID | Steps | Expected |
|---|---|---|
| 10l.1 | Press ↓. | Advances to next prompt (existing behavior). Cursor on the new prompt starts at (1, 1) on first visit. |
| 10l.2 | Press ←. | Jumps to previous day's remembered prompt (existing behavior). |
| 10l.3 | Press ↑↓ while in search mode (search bar visible). | Still navigates prompts — arrow keys are not captured by search mode. (Search bar may persist visually until Enter/Escape; that's expected.) |

### 10m. Cursor memory across prompts

| ID | Steps | Expected |
|---|---|---|
| 10m.1 | On prompt A, press `5G` (cursor at line 5 col 1). Press ↓ to prompt B. Press `3G` on B. Press ↑ back to A. | Cursor on A restored to line 5 col 1. |
| 10m.2 | From the previous test, press ↓ again to B. | Cursor on B restored to line 3 col 1. |
| 10m.3 | Hard-refresh the page. | Cursor memory **survives** the refresh (#68 added `localStorage` persistence under `firstcontact:transcripts-viewer:v1:cursorByPromptIndex`). The loaded prompt's cursor restores from the saved entry if one exists; otherwise falls back to (1, 1). See § 17 for the persistence regression coverage; clear the storage key (`localStorage.removeItem('firstcontact:transcripts-viewer:v1:cursorByPromptIndex')`) and refresh again to observe the (1, 1) fallback. |

### 10n. Cursor memory + search auto-jump

| ID | Steps | Expected |
|---|---|---|
| 10n.1 | On prompt A at (5, 1), `/foo<Enter>` matches in prompt B at line 10. | Viewer jumps to B, cursor lands at the match (line 10 col matching the string position). NOT B's previously-remembered position (the match override wins). |
| 10n.2 | After 10n.1, press ↑ back to A. | Cursor on A restored to (5, 1) (A's saved position when it was left). |

### 10o. Defense-in-depth

| ID | Steps | Expected |
|---|---|---|
| 10o.1 | Search for a string like `<script>alert(1)</script>` (won't be found in normal transcripts). | Search bar displays the literal string in the "Pattern not found: …" error — no `<script>` element created, no alert fires (search-bar uses `textContent`). |

## 11. VIM cross-response navigation (issue #50)

Issue #50 extends the `h/j/k/l` motion from § 10b so that the cursor can cross the boundary between adjacent prompts in the global timeline. At the trailing edge of a response, `j` (from the last source line) or `l` (from the last character of the last line) advances to the first line / `(1, 1)` of the next prompt's response. At the leading edge, `k` (from the first line) or `h` (from `(1, 1)`) retreats to the last line / last character of the previous prompt's response. Column position is preserved across `j`/`k` cross-response moves, clamping down to the new line's length when shorter (or to col 1 when the new line is empty). The cross-response branches are gated by `currentIndex ± 1` bounds, so timeline boundaries (first prompt's `k`/`h`, last prompt's `j`/`l`) fall through to the existing intra-response clamp and the cursor stays put. Cross-response motion calls `render(newIndex)` (which auto-saves the leaving prompt's cursor into `cursorByPromptIndex`) and then `placeCursorAt(...)` to OVERRIDE the destination prompt's remembered cursor with the cross-response target — mirroring the search auto-jump behavior in § 10n.

### 11a. Basic cross-response cases (one per direction)

| ID | Steps | Expected |
|---|---|---|
| 11a.1 | On prompt A (not the last), position cursor at the **last** source line of A's response (`G` then any column via `l`). Press `j`. | Viewer auto-jumps to prompt A+1. Cursor wraps a character at line 1 of A+1's response body. Prompt-line at top updates to A+1's metadata. URL `?prompt=` reflects A+1. |
| 11a.2 | On prompt B (not the first), position cursor at line 1 of B's response (`1G`). Press `k`. | Viewer auto-jumps to prompt B-1. Cursor wraps a character at the **last** rendered line of B-1's response body. Prompt-line updates; URL reflects B-1. |
| 11a.3 | On prompt A (not the first), position cursor at `(1, 1)` of A's response (`1G`). Press `h`. | Viewer jumps to prompt A-1. Cursor wraps the **last character of the last rendered line** of A-1's response body. |
| 11a.4 | On prompt A (not the last), position cursor at the last character of the last rendered line of A's response (`G` then `l` until at end-of-line). Press `l`. | Viewer jumps to prompt A+1. Cursor wraps the first character of line 1 of A+1's response body (i.e. `(1, 1)`). |

### 11b. Column preservation under `j` / `k`

| ID | Steps | Expected |
|---|---|---|
| 11b.1 | Choose a prompt pair A → A+1 where line 1 of A+1's response is **at least as long** as A's last line, then position cursor at `(lastLine(A), 4)` in A. Press `j`. | Cursor lands at `(1, 4)` of A+1. The column 4 is preserved exactly. |
| 11b.2 | Choose A → A+1 where line 1 of A+1 has length `L` and pick a column in A's last line with `col > L` (e.g. A ends with a long line, A+1 starts with a short heading). Position at `(lastLine(A), col)` then press `j`. | Cursor lands at `(1, L)` of A+1 — clamped to the new line's length. |
| 11b.3 | Choose A → A+1 where line 1 of A+1's response is an **empty** rendered line (e.g. starts with a blank synthetic line) and position at any column > 1 in A's last line. Press `j`. | Cursor lands at `(1, 1)` of A+1 — clamped to 1 because the destination line has zero characters. The `<span class="cursor">` wraps a space placeholder (see § 10a.2-bis). |
| 11b.4 | Mirror of 11b.1 with `k`: position at `(1, 4)` of B where last line of B-1 is ≥ 4 chars. Press `k`. | Cursor lands at `(lastLine(B-1), 4)` of B-1. |
| 11b.5 | Mirror of 11b.2 with `k`: B's line 1 col `col` where last line of B-1 has length `L < col`. Press `k`. | Cursor lands at `(lastLine(B-1), L)` of B-1 — clamped down. |
| 11b.6 | Mirror of 11b.3 with `k`: last line of B-1 is empty. Press `k` from `(1, col>1)` of B. | Cursor lands at `(lastLine(B-1), 1)` of B-1. |

### 11c. Timeline boundaries

| ID | Steps | Expected |
|---|---|---|
| 11c.1 | Navigate to the **first** prompt (e.g. `?prompt=0`). Position cursor at line 1 col 1. Press `k`. | Cursor stays at `(1, 1)`. No re-render. No console error. `currentIndex` unchanged; URL unchanged. |
| 11c.2 | Same first prompt, cursor at `(1, 1)`. Press `h`. | Cursor stays at `(1, 1)`. No re-render. |
| 11c.3 | Navigate to the **last** prompt. Position cursor at the last rendered line (any column). Press `j`. | Cursor stays put — intra-response clamp keeps it on the last line. No re-render; `currentIndex` unchanged. |
| 11c.4 | Same last prompt, cursor at `(lastLine, lastCol)`. Press `l`. | Cursor stays at `(lastLine, lastCol)`. No re-render. |

### 11d. Cursor memory interaction with cross-response motion

| ID | Steps | Expected |
|---|---|---|
| 11d.1 | On prompt A, position cursor at `(lastLine(A), 7)`. Press `j` to cross into A+1. Inspect `cursorByPromptIndex[A]` in the console (via the test harness or a debug accessor). | A's entry stores `{ line: lastLine(A), col: 7 }` (the leaving cursor). |
| 11d.2 | After 11d.1, press `k` to return to A. | Cursor on A restored to `(lastLine(A), 7)` — the position you crossed FROM. |
| 11d.3 | Pre-seed prompt B with a remembered cursor by visiting B first (e.g. press `5G` then ↑ away). Then go to A (B-1) and cross forward via `j` from A's last line. | Cursor on B lands at the **cross-response target** (`(1, col)` clamped), NOT at B's previously-remembered `(5, 1)`. The cross-motion overrides the remembered cursor. |
| 11d.4 | After 11d.3, press ↑ (arrow) back to A, then ↓ back to B. | Cursor on B is now restored to the cross-response target from 11d.3 (since that became the most-recently-saved cursor on the leave from B). |
| 11d.5 | On prompt A at `(1, 1)`, press `h` to cross to A-1. Then press `l`. | `l` at `(lastLine(A-1), lastCol(A-1))` crosses forward into A — cursor lands at `(1, 1)` of A (the cross-response forward target), not at A-1's prior `(1, 1)` memory of A. |

### 11e. Interaction with existing keys

| ID | Steps | Expected |
|---|---|---|
| 11e.1 | After a cross-response `j` from A to A+1, press ↑. | Arrow key swaps back to prompt A, restoring A's remembered cursor (the `(lastLine(A), col)` from before the cross — saved in 11d.1). Arrow-key behavior from § 9f / § 10l unchanged. |
| 11e.2 | Cross forward via `j`, then press `/`, type a string present in the new prompt, press Enter. | Search behaves exactly as in § 10d / § 10e — no interaction with cross-response motion. |
| 11e.3 | On prompt A, position at `(2, 3)`. Press `n` (with no prior search) — no-op. Then press `G`. | `G` jumps to the last line of A (col 1). It does **not** cross into A+1 even if A is non-last — `G` only operates within the current response. § 10c.A.1 semantics unchanged. |
| 11e.4 | Press `5G` on the last prompt where line 5 exists. | Cursor at `(5, 1)` of the last prompt. Does not cross into a non-existent prompt+1. |

### 11f. Edge cases

| ID | Steps | Expected |
|---|---|---|
| 11f.1 | Choose a prompt pair A → A+1 where A+1's response is the `(no response captured)` placeholder. From A's last line, press `j`. | Viewer jumps to A+1. Cursor wraps the first character `(` of `(no response captured)`. |
| 11f.2 | Mirror of 11f.1: from `(1, 1)` of A+1 (the placeholder prompt), press `k`. | Viewer jumps to A. Cursor lands on A's last rendered line at col 1 — col is preserved from the outgoing cursor's col 1 (`k` is column-preserving per the 11b column rule, NOT `h`-style "last character of last line"). |
| 11f.3 | Choose A → A+1 where A+1's first rendered line is empty (zero-length). Cross via `j` from any column of A's last line. | Cursor lands at `(1, 1)` of A+1, span renders a space placeholder. (Same as 11b.3.) |
| 11f.4 | Choose A → A+1 where A's last rendered line is empty. Position cursor at `(lastLine(A), 1)` (the only valid col on an empty line). Press `l`. | The intra-response clamp keeps the cursor on the empty line (col 1 is also `curMaxCol` of `Math.max(1, 0) = 1`), so the `l`-cross branch fires and jumps to `(1, 1)` of A+1. |
| 11f.5 | Navigate to the first prompt (`?prompt=0`). Position cursor at `(1, 1)`. Press `h`. | No-op (stays put — same as 11c.2). |
| 11f.6 | Navigate to the last prompt. Position cursor at `(lastLine, lastCol)`. Press `l`. | No-op (stays put — same as 11c.4). |
| 11f.7 | From the first prompt, press `j` repeatedly (each time landing on the last line of the current prompt, then crossing). Continue until reaching the last prompt. From the last prompt's last line, press `j` one more time. | The walk advances one prompt per cross (after each cross, the cursor is on line 1 of the new prompt; subsequent `j` presses walk down within that prompt until hitting its last line and crossing again). The final `j` on the last prompt's last line is a no-op (11c.3). |
| 11f.8 | Same shape as 11f.7 but with `l` from `(last, lastCol)` after each cross-forward (manually re-positioning to `(last, lastCol)` of each new prompt with `G` + `l`-until-clamped, then pressing `l`). | Each `l` at `(last, lastCol)` jumps forward to the next prompt's `(1, 1)`. The final `l` on the last prompt is a no-op (11c.4). |

### 11g. Visual + state side-effects

| ID | Steps | Expected |
|---|---|---|
| 11g.1 | Before cross-response `j`/`k`/`h`/`l`, note the `#prompt-line` text (date, time, `User:` prefix, prompt text). Cross to a neighbouring prompt. Re-read `#prompt-line`. | After the cross, `#prompt-line` reflects the new prompt's user_text and timestamp per § 9b / § 9c (including any `Claude:` prefix when the previous response ended with `?`). |
| 11g.2 | Note the URL's `?prompt=N` value before a cross. Cross forward via `j` from the last line. Re-read the URL. | `?prompt=` now reads `N+1`. (Cross via `k`/`h` decrements to `N-1`; non-crossing keypresses leave it unchanged.) |
| 11g.3 | After any cross-response motion, `document.querySelectorAll('#response-body .cursor')` in the Console. | Returns exactly ONE `<span class="cursor">` — inside the newly rendered response body. (No stale cursor from the previous prompt's DOM.) |
| 11g.4 | After cross-response `j` from A at col 4 (where A+1's line 1 has length ≥ 4), inspect the cursor span and the surrounding text. | The cursor span wraps the 4th character of the rendered line-1 text of A+1's response body. The character beneath the cursor matches A+1's source line 1 at col 4. |
| 11g.5 | After cross-response `h` from `(1, 1)` of A to A-1's last line last col, inspect the cursor span. | The cursor span wraps the last character of the last rendered line of A-1's response body. |

## 12. VIM screen-position motions H / M / L (issue #54)

Issue #54 adds three VIM-style "screen position" motions to the existing `hjklG/nN` keybinds in `web/transcripts-viewer.html`:

| Key | Move |
| --- | --- |
| `H` | top of screen ("High") — first rendered line whose top is at or below the `#output-card` viewport top |
| `M` | middle of screen — rendered line whose vertical center is closest to the viewport midpoint |
| `L` | bottom of screen ("Low") — last rendered line whose bottom is at or above the viewport bottom |

Cursor column position resets to `1` after H / M / L (per the issue's `cursor column position will be reset to beginning of the new line` requirement — the cursor lands at the start of the new line, not at the previously-held column).

Implementation:
- New `rectForLineStart(line)` helper builds a `Range` over the first character of the given rendered line and returns its `getBoundingClientRect()`. The Range API doesn't mutate the DOM (no `splitText`), so this is a cheap measurement primitive distinct from `placeCursorAt`.
- New `findVisibleLineRange()` iterates over `1..totalLines()`, calls `rectForLineStart` on each, and tracks: the first line fully inside the viewport (→ `top`), the last line fully inside the viewport (→ `bot`), and the line whose center is closest to the viewport midpoint (→ `mid`). Fallbacks: short content where the entire response fits inside the viewport returns first / mid / last line.
- Keyboard handler: `H`, `M`, `L` (each capital — Shift + h/m/l) call `findVisibleLineRange()` and dispatch `moveCursorAbs(target, 1)`. `numberPrefix` is cleared (no `<num>H` support — H/M/L take no count). Shift's own keydown short-circuits at the existing modifier-only guard so Shift before capital H/M/L doesn't clobber `numberPrefix`.
- Help text updated: `hjklG/nN vim keybind` → `hjklHMLG/nN vim keybind`.

The issue also notes `gg (top of file) will be implemented with other "g" functions` — that is **out of scope** for #54 and will land in a separate issue covering the `g` family.

### 12a. H motion — top of screen

| ID | Steps | Expected |
|---|---|---|
| 12a.1 | Load a long response (≥ 50 rendered lines, e.g. a code-heavy reply that overflows the viewport). Scroll the `#output-card` so several lines are above the viewport top. Press `H`. | Cursor jumps to the first rendered line whose top is at or below the viewport top. Cursor column is `1`. The `<span class="cursor">` wraps the first character of that line (or a placeholder space if the line is empty). |
| 12a.2 | After 12a.1, press `H` again without scrolling. | No effective movement — cursor is already on the H line. (`placeCursorAt(top, 1)` re-fires but is a DOM-equivalent no-op; no console error.) |
| 12a.3 | On a SHORT response that fits entirely inside the viewport (e.g. a 3-line reply). Press `H`. | Cursor lands at line 1, col 1 — the fallback when no line is "fully inside" the viewport (the entire response is). |
| 12a.4 | Press `H` while the cursor is mid-line at `(N, 7)` where line N is below the H line. | Cursor moves to `(H_line, 1)`. Column 7 is **not** preserved — col is reset to 1 (issue #54 spec). |
| 12a.5 | Press `H` while the cursor is below the H line (e.g. on the L line at the bottom of the viewport). | Cursor moves up to `(H_line, 1)`. |

### 12b. M motion — middle of screen

| ID | Steps | Expected |
|---|---|---|
| 12b.1 | Long response, scrolled so the viewport shows lines 20–40 (approximately). Press `M`. | Cursor lands on the rendered line whose vertical center is closest to the viewport midpoint — roughly line 30. Col = 1. |
| 12b.2 | Long response with uneven block heights (mix of headings, paragraphs, fenced code blocks). Press `M` and visually note which line the cursor lands on. | The chosen line's *vertical center* should be the closest one to the viewport midpoint — i.e. a tall preceding code block can shift the M line to a smaller logical-line number than a midpoint-of-`(top, bot)` average would suggest. |
| 12b.3 | Press `M` on a short response that fits inside the viewport. | Cursor lands at the response's middle line (`ceil((1 + total) / 2)`) — the fallback when no fully-visible range can be established. |
| 12b.4 | Press `M` from any cursor position. | Col resets to 1 regardless of starting column. |

### 12c. L motion — bottom of screen

| ID | Steps | Expected |
|---|---|---|
| 12c.1 | Long response, scrolled so several lines are below the viewport bottom. Press `L`. | Cursor jumps to the last rendered line whose bottom is at or above the viewport bottom. Col = 1. |
| 12c.2 | Press `L` then `j` repeatedly. | Each `j` moves down one line; after enough presses the cursor drops below the viewport and `scrollCursorIntoView` (existing behavior) brings it into view. The `L` landing was on the *visible* bottom line, not the response's *absolute* last line. |
| 12c.3 | Short response inside viewport. Press `L`. | Cursor lands at the response's last line, col 1 — fallback for short content. |
| 12c.4 | Press `L` from a cursor higher in the viewport. | Cursor moves down. Col resets to 1. |

### 12d. Column reset after H / M / L

| ID | Steps | Expected |
|---|---|---|
| 12d.1 | Position cursor at `(5, 12)` via `5G` then `l` × 11. Press `H`. | Cursor lands at `(H_line, 1)` — column 1, not 12. |
| 12d.2 | Repeat 12d.1 with `M` instead of `H`. | Cursor at `(M_line, 1)`. Column reset. |
| 12d.3 | Repeat with `L`. | Cursor at `(L_line, 1)`. Column reset. |
| 12d.4 | On a long line where col 12 would exist on the H line. Set cursor at `(5, 12)`, press `H`. | Cursor at `(H_line, 1)`. The fact that col 12 IS valid on the new line is irrelevant — col is unconditionally reset. |

### 12e. Interaction with existing keys

| ID | Steps | Expected |
|---|---|---|
| 12e.1 | Type `5` (number prefix accumulator engaged), then `H`. | `H` triggers top-of-screen and clears `numberPrefix` — there is no `<num>H` support. `5G` (with a numeric prefix) still works as before, but `5H` is just `H`. |
| 12e.2 | Press `/`, type `H`, press Enter. | Search executes for the literal character `H`. Cursor does NOT jump to top-of-screen — `H` is captured as search input while in search mode (consistent with § 10k.1 for `j`). |
| 12e.3 | Press `H` while inside search mode (search bar visible, partial pattern typed). | `H` appended to `searchString`. No top-of-screen motion. |
| 12e.4 | After `H`/`M`/`L`, press `j` or `k`. | Motion continues from the new (line, 1) position — j/k operate normally from wherever H/M/L landed. |
| 12e.5 | After `H`/`M`/`L`, press `↑` (arrow). | Page advances to the previous prompt (existing arrow-key behavior unchanged). The cursor save still records the H/M/L landing position into `cursorByPromptIndex[currentIndex]` before the swap. |
| 12e.6 | After `H`/`M`/`L`, press `G`. | Jumps to the last source line (existing § 10c behavior). |
| 12e.7 | Type `5`, hold Shift (Shift keydown fires — modifier-only guard short-circuits and keeps `numberPrefix = '5'`), then while still holding Shift press `H`. | `H` triggers top-of-screen with `numberPrefix` cleared in `H`'s branch — `5` is discarded (intentional: H takes no count). |

### 12f. Visual + state side-effects

| ID | Steps | Expected |
|---|---|---|
| 12f.1 | After any H/M/L motion, `document.querySelectorAll('#response-body .cursor')` in the Console. | Returns exactly ONE `<span class="cursor">` — the previous cursor span is replaced by `removeCursorSpan` inside `placeCursorAt` before the new one is inserted (existing § 9f / § 10a invariant). |
| 12f.2 | After H/M/L on a long response, inspect `cursor` (via console accessor if available, or trace via `placeCursorAt`'s assignment). | `cursor.line` matches the H/M/L target line; `cursor.col === 1`. |
| 12f.3 | After H/M/L, navigate to a different prompt via ↑/↓ then back. | `cursorByPromptIndex[<original>]` stored the H/M/L position (line, col=1); returning restores cursor to that line/col. |
| 12f.4 | Scroll the `#output-card` so the cursor is off-screen, then press `H`. | Cursor lands at the visible top line and `scrollCursorIntoView` keeps it visible (or the cursor itself is what becomes visible since H targets a line inside the current viewport). No scroll-jump to top-of-document for non-line-1 targets. |
| 12f.5 | Help text at the bottom of the viewer reads `↑↓ prompts · ←→ days · hjklHMLG/nN vim keybind`. | Exact substring match — `HML` inserted between `hjkl` and `G`. |

### 12g. Edge cases

| ID | Steps | Expected |
|---|---|---|
| 12g.1 | Empty `(no response captured)` placeholder prompt. Press `H`, `M`, `L`. | Each lands at `(1, 1)` of the placeholder text (it has one line of content). No JS error. |
| 12g.2 | Single-line response that fits entirely in the viewport. Press `H`. | Cursor at `(1, 1)`. Press `M`: also `(1, 1)`. Press `L`: also `(1, 1)`. |
| 12g.3 | Viewport-sized response (exactly fills the viewport, no scroll). Press `H` / `L`. | H lands at line 1; L lands at the last line (`totalLines()`). M lands at the middle. |
| 12g.4 | Resize the browser window so the `#output-card` shrinks vertically, putting more lines off-screen. Press `H`/`M`/`L` again. | Each motion re-measures the viewport via `getBoundingClientRect()`, so the new H/M/L targets reflect the new visible range. |
| 12g.5 | Sanity check: set cursor at line 1, scroll, then press `H`/`M`/`L`. Verify the motion still finds the correct viewport-relative lines. | `rectForLineStart`'s tree walker skips nodes whose parent has class `cursor`, so the cursor's own position does not bias the measurement. |

## 13. Per-day prompt-position memory (issue #66)

Issue #66 specifies three behaviors for `web/transcripts-viewer.html`'s day-navigation memory. The `lastIndexByDay` / `targetForDay` machinery (introduced #35, unchanged across #45 / #50 / #54) satisfies the **in-session** part of all three: per-day memory write on visit, fallback to `first_prompt_index` for unvisited days, transition reads via `targetForDay`. Per the #66 follow-up, the **initial-load default** was also changed so the viewer opens at `days[days.length - 1].first_prompt_index` (first prompt of the last day) instead of `prompts.length - 1` (most-recent prompt globally) — making the "initialize to first prompt of each day" requirement apply at load time too, not just on first ←/→ visit.

| Requirement (#66) | How it's met in `main` |
| --- | --- |
| Initialize prompt location of each day to be the first prompt of the day | (a) On initial load, `startIndex = days[days.length - 1].first_prompt_index` when no `?prompt=` URL param. (b) For every other day, `targetForDay(day)` returns `day.first_prompt_index` whenever `lastIndexByDay[day.date]` is unset (or out of range). |
| If a day has been visited, remember the last visited prompt location of that day | `render(index)` writes `lastIndexByDay[p.day] = clamped` on every prompt-switch (line ~1051). "Visited" = "currently rendered". |
| When transitioning to a day, jump to the saved prompt location of that day | `goToPrevDay` / `goToNextDay` call `render(targetForDay(days[di ± 1]))`. Arrow `←` / `→` are wired to those in the key handler. |

Memory is **in-memory only** — a page refresh clears `lastIndexByDay`. This is intentional (mirrors `cursorByPromptIndex` from § 10m.3). If cross-refresh persistence is wanted later, it would need its own issue (localStorage backing) and isn't part of #66's scope — see #68 in the backlog.

### 13a. Initialization — load default + unvisited-day fallback both land on first prompt of the day

| ID | Steps | Expected |
|---|---|---|
| 13a.1 | Hard-refresh the page (no `?prompt=` URL parameter). Note the prompt index in the URL after load and the `#prompt-line` timestamp. | URL is rewritten to `?prompt=N` where `N === days[days.length - 1].first_prompt_index` — the **first prompt of the last day**, not the most-recent prompt globally. Timestamp shown is the first prompt's `timestamp` of the last day. Verifiable against the `/claudecode/timeline` JSON payload's last `days[]` entry. |
| 13a.1-bis | Load with `?prompt=5` in the URL. | Viewer renders prompt index 5 — the explicit URL override wins over the new load default. (§ 8c.8 / § 9f.4 regression unchanged.) |
| 13a.1-ter | Backend returns an empty `days` array (zero prompts overall). | `lastDayFirst` evaluates to `0`; `render(0)` falls into the empty-state path inside `render` (no prompts to render) — viewer shows "No prompts found in `~/.claude/projects/`." muted message. No JS error. |
| 13a.2 | After 13a.1, press ← (assuming there is a day before the last). | Viewer jumps to `days[lastDay - 1].first_prompt_index` — the previous day's **first** prompt, because that day has never been visited this session and `targetForDay` returns the `first_prompt_index` fallback. |
| 13a.3 | Continue pressing ← repeatedly into older days. Each press lands on the first prompt of the destination day on the first visit. | Until a day has been visited, each ← landing is `days[di].first_prompt_index`. |

### 13b. Memory — last visited prompt of each day is remembered

| ID | Steps | Expected |
|---|---|---|
| 13b.1 | Load. ↓ several times so the current prompt is past day D's `first_prompt_index` (e.g. land on day D, prompt P > first). Console-inspect `lastIndexByDay` (via a test-harness accessor or temporary debug snippet). | `lastIndexByDay[D.date] === P` — the current `currentIndex` is captured. |
| 13b.2 | After 13b.1, press ← into day D-1, then ↓ a few times to land at day D-1's prompt Q > first. | `lastIndexByDay[D-1.date] === Q`. The previous entry for `D.date` is untouched (still equals `P` from 13b.1). |
| 13b.3 | After 13b.2, press → back into day D. | Viewer lands at prompt `P` (the remembered position from 13b.1) — **not** the first prompt of D. URL `?prompt=N` reads `N === P`. |
| 13b.4 | After 13b.3, ↓ to a new prompt P' in day D. | `lastIndexByDay[D.date]` updates to `P'`. Older value `P` overwritten. |
| 13b.5 | Inspect `lastIndexByDay` after a full walk visiting days D, D-1, D-2 at non-first prompts. | The dict contains one entry per visited day, mapping date → last-rendered prompt index. Unvisited days are absent. |

### 13c. Transition — ← / → jump to saved location

| ID | Steps | Expected |
|---|---|---|
| 13c.1 | Set up: visit day D at prompt P_D, day D-1 at prompt P_{D-1}, day D-2 at prompt P_{D-2}. Then from any of them, press ←. | Lands at the saved prompt of the previous day per `targetForDay`. |
| 13c.2 | After 13c.1, press → back. | Lands at the saved prompt of the day you came from — *the position when you last left it*, which `render` saved on the leave-trigger from that day. |
| 13c.3 | From a remembered position in day D, press ←, then immediately ←, then →, then →. Compare landings against `lastIndexByDay` snapshots taken between each press. | Each landing matches `lastIndexByDay[destDay.date]` if defined, else `destDay.first_prompt_index`. The walk is symmetric. |
| 13c.4 | Walk from a day's first prompt to its last prompt via ↓. Press ←. Press →. | The → return lands at the day's last prompt (the most recent save in `lastIndexByDay[D.date]`), not at first or middle. |

### 13d. Clamp safety — remembered index outside the day's range

| ID | Steps | Expected |
|---|---|---|
| 13d.1 | Manually corrupt the memory via Console: `lastIndexByDay[someDay.date] = 99999`. Then ← / → to land on `someDay`. | `targetForDay` rejects the out-of-range value (`remembered >= day.first_prompt_index && remembered <= day.last_prompt_index` guard fails) and falls back to `day.first_prompt_index`. No JS error, no broken render. |
| 13d.2 | Same as 13d.1 but with a value below `first_prompt_index` (e.g. `lastIndexByDay[D.date] = -1`). | Same fallback to `first_prompt_index`. |
| 13d.3 | Same with `lastIndexByDay[D.date] = null`. | `null != null` is false, so the guard `remembered != null` is false → fallback to `first_prompt_index`. |

### 13e. Memory boundaries — refresh, single day, day-less prompts

| ID | Steps | Expected |
|---|---|---|
| 13e.1 | Visit day D at prompt P. Hard-refresh the page. Press ← (or → if D was the first day). | Per-day memory **survives** the refresh — landing is the pre-refresh `P` (#68 added `localStorage` persistence under `firstcontact:transcripts-viewer:v1:lastIndexByDay`). To exercise the original `first_prompt_index` fallback, first clear the key: `localStorage.removeItem('firstcontact:transcripts-viewer:v1:lastIndexByDay')` then refresh. See § 17 for the persistence regression coverage. |
| 13e.2 | Single-day timeline (only one `days[]` entry). Press ← or → from any prompt. | No-op per existing boundary checks. `lastIndexByDay` is still maintained by `render()` calls (from ↑ ↓ navigation) but isn't read because day-transitions never happen. |
| 13e.3 | A prompt with no `.day` field (placeholder / corrupted backend response). Render it (e.g. via direct `?prompt=N` URL). Inspect `lastIndexByDay`. | `if (p.day) lastIndexByDay[p.day] = clamped;` short-circuits — no entry written for a day-less prompt. Then pressing ← / → from such a prompt hits `dayIndexOf(undefined) === -1`, which `goToPrevDay`'s `di === -1` branch handles by rendering `targetForDay(days[0])` (first day's saved or first-prompt). |

### 13f. Interaction — memory survives across all motion types

| ID | Steps | Expected |
|---|---|---|
| 13f.1 | Visit day D prompt P. ↓ ↓ ↓ (advance within D to P+3). ↑ back to P. | `lastIndexByDay[D.date] === P` (the most recent render). |
| 13f.2 | Use `/searchterm` to auto-jump to a match in day D at prompt P. The auto-jump is performed by `applyMatch` → `render(promptIdx)`. | `render` writes `lastIndexByDay[D.date] === P` just like a manual navigation. Search auto-jump is not exempt. |
| 13f.3 | Use cross-response motion (§ 11) `j` from the last line of day D's last prompt to cross into day D+1's first prompt. | Both `render(oldIdx)`'s saved state and `render(newIdx)`'s write update `lastIndexByDay` for the source and destination days respectively. |
| 13f.4 | Use H / M / L (§ 12) — these don't change `currentIndex`, only cursor position within the response. | `lastIndexByDay` is **not** updated by H/M/L because no `render` call occurs (these are intra-response motions). The prompt index for the current day is whatever `render` last wrote. |
| 13f.5 | Use `<num>G` (§ 10c) — intra-response motion, no `render`. | `lastIndexByDay` unchanged. |

### 13g. Sanity — code-shape regression guards against re-attempts of #63

| ID | Steps | Expected |
|---|---|---|
| 13g.1 | `grep -n 'lastIndexByDay' web/transcripts-viewer.html` | At least 4 occurrences: declaration (`const lastIndexByDay = {}`), write (`lastIndexByDay[p.day] = clamped`), read (`lastIndexByDay[day.date]`) inside `targetForDay`, and the `targetForDay` function definition itself. Removing any breaks #66. |
| 13g.2 | `grep -n 'targetForDay' web/transcripts-viewer.html` | At least 4 occurrences: definition + 3 call-sites (one in `goToPrevDay` for `di > 0`, one in the `di === -1` fallback, one in `goToNextDay`). Removing any reduces the day-navigation paths that respect memory. |
| 13g.3 | Read `goToPrevDay` and `goToNextDay`. | Both call `render(targetForDay(...))`, not `render(days[...].first_prompt_index)` directly. The indirection through `targetForDay` is what makes memory honored. |

## 14. Per-prompt cursor-position memory (issue #67)

Issue #67 specifies three behaviors for cursor-position memory inside each prompt's response. All three are met by the existing `cursorByPromptIndex` machinery introduced in #45 (see § 10m, § 10n) and unchanged across #50 / #54 / #66 — this section is **regression coverage** for that pre-existing behavior, not a new feature.

| Requirement (#67) | How it's met in `main` |
| --- | --- |
| Initialize cursor location of each prompt to first character of first line | `render(index)` checks `cursorByPromptIndex[clamped]`; if absent, sets `cursor = { line: 1, col: 1 }` (lines ~1058–1063). The fallback IS the initialization — no explicit pre-population. |
| Remember last cursor location of each prompt | `render(index)` saves `cursorByPromptIndex[currentIndex] = { line: cursor.line, col: cursor.col }` *before* swapping to the new prompt (line ~1018), gated by `currentIndex !== clamped` so same-prompt renders don't pollute. |
| Transition restores saved cursor | After the prompt swap, `render` reads `cursorByPromptIndex[clamped]` and calls `placeCursorAt(cursor.line, cursor.col)` (line ~1064). All transition entry points (↑/↓ arrows, ←/→ day jumps, search auto-jump, cross-response j/k/h/l, direct `?prompt=N` URL) route through `render` and inherit this behavior. |

Memory is **in-memory only** — a page refresh clears `cursorByPromptIndex` (per § 10m.3). The localStorage-persistence companion is scoped as #68 in the backlog.

Existing § 10m / § 10n / § 11d already cover much of this behavior end-to-end. § 14 below complements them by scoping cases explicitly to #67's three requirements and adding code-shape regression guards (§ 14g) that prevent silent removal of the memory machinery.

### 14a. Initialization — unvisited prompts default to (1, 1)

| ID | Steps | Expected |
|---|---|---|
| 14a.1 | Load. The initial render places the cursor at `cursor.line = 1, cursor.col = 1` for the starting prompt. Inspect `cursorByPromptIndex` in the Console. | `cursorByPromptIndex` is an empty object (well, may contain one entry for `currentIndex = 0` written by the first-render save when `startIndex !== 0` — see 14a.4). The starting prompt's cursor is `(1, 1)` regardless. |
| 14a.2 | Navigate via ↓ to a never-visited prompt (any direction works the first time). | Cursor on the new prompt lands at `(1, 1)`. |
| 14a.3 | Hard-refresh the page. | `cursorByPromptIndex` hydrates from `firstcontact:transcripts-viewer:v1:cursorByPromptIndex` if that key exists (#68); otherwise starts empty. If the starting prompt has a saved entry, the cursor restores to that entry; otherwise initial render places it at `(1, 1)`. To exercise the empty-start path, `localStorage.removeItem('firstcontact:transcripts-viewer:v1:cursorByPromptIndex')` and refresh. |
| 14a.4 | Load with `?prompt=5` URL param. Inspect `cursorByPromptIndex[0]` in the Console immediately after load. | Entry exists with `{ line: 1, col: 1 }` — the spurious save from `render(5)` saving the default cursor for the initial `currentIndex = 0` (`if (currentIndex !== clamped)` guard fires because `0 !== 5`). This is a known minor imperfection — it doesn't observably affect navigation since prompt 0 would land at `(1, 1)` either way. |

### 14b. Memory — last cursor location of each prompt is remembered

| ID | Steps | Expected |
|---|---|---|
| 14b.1 | On prompt A, press `5G` to land at `(5, 1)`. Press `l` × 3 to land at `(5, 4)`. Press ↓ to swap to prompt B. Console-inspect `cursorByPromptIndex[A]`. | `cursorByPromptIndex[A] === { line: 5, col: 4 }` — the cursor at the moment of leaving A. |
| 14b.2 | After 14b.1, on prompt B press `3G` then `l` × 6 → cursor at `(3, 7)`. ↑ back to A. Inspect `cursorByPromptIndex[B]`. | Saved on leaving B: `{ line: 3, col: 7 }`. |
| 14b.3 | After 14b.2 (cursor restored to A's `(5, 4)`), do nothing for 5 seconds, then ↓ to B. Inspect `cursorByPromptIndex[A]`. | Unchanged from 14b.1: `{ line: 5, col: 4 }` — only the leave-trigger writes, not idle time. |
| 14b.4 | Visit prompts P0..P9 in sequence with distinct cursor positions on each. Inspect the dict's full state. | 10 entries (one per visited prompt), each mapping `index → { line, col }` of where the cursor was on leaving. |
| 14b.5 | Save state via `JSON.stringify(cursorByPromptIndex)`. Each value is `{ line: <int>, col: <int> }`. | Schema is uniform — no nested objects, no extra fields. The shape `{ line, col }` matches what `placeCursorAt` consumes. |

### 14c. Transition — entering a prompt restores saved cursor

| ID | Steps | Expected |
|---|---|---|
| 14c.1 | After 14b.2, ↑ back to A, then ↓ back to B. | Cursor on B restored to `(3, 7)` from `cursorByPromptIndex[B]`. |
| 14c.2 | Visit A at `(5, 4)`, B at `(2, 1)`. From B press ←/→ to switch days then come back via ←/→ landing on A (per § 13). | Cursor on A restored to `(5, 4)`. (Both day-position memory and per-prompt cursor memory cooperate: § 13's `lastIndexByDay` chooses A as the day's saved prompt; § 14's `cursorByPromptIndex[A]` chooses `(5, 4)` as the cursor.) |
| 14c.3 | Visit A at `(5, 4)`. Open URL `?prompt=<A>` in a new tab (different session). | Since #68 added `localStorage` persistence, the new tab shares the same origin's storage and restores A's cursor to `(5, 4)`. (For per-session-only isolation, open the URL in a private / incognito window — that window's `localStorage` is separate and starts empty, so cursor lands at `(1, 1)`.) |
| 14c.4 | Visit A at `(5, 4)`, B at `(7, 2)`. Search `/sometext<Enter>` matches in A at line 9. | Search auto-jump renders A then OVERRIDES `cursorByPromptIndex[A]`'s `(5, 4)` with `(9, <match col>)` via `placeCursorAt(matchLine, matchCol)` (§ 10n.1 behavior). |
| 14c.5 | After 14c.4, ↑ to A's neighbor then ↓ back to A. | Cursor restored to the *match* position `(9, ...)` — the search override updated the saved memory through the next save-on-leave cycle. |

### 14d. Cursor-validity sanity — restored value clamps via `placeCursorAt`

| ID | Steps | Expected |
|---|---|---|
| 14d.1 | Manually corrupt the memory: `cursorByPromptIndex[A] = { line: 9999, col: 9999 }`. Then ↑↓ or arrow-jump to A. | `placeCursorAt` clamps `(line, col)` to the prompt's rendered text range — `L = min(line, totalLines())`, `C = min(col, max(1, lineLength(L)))`. No JS error; cursor lands within bounds. |
| 14d.2 | `cursorByPromptIndex[A] = { line: 0, col: 0 }`. Visit A. | `placeCursorAt` floors to `(1, 1)` via its `Math.max(1, …)` clamps. |
| 14d.3 | `cursorByPromptIndex[A] = null`. Visit A. | The restore branch `if (remembered)` skips the null and falls through to `cursor = { line: 1, col: 1 }`. |
| 14d.4 | `cursorByPromptIndex[A] = { line: 'foo', col: 'bar' }` (type-corrupted). Visit A. | `placeCursorAt`'s `Math.max/Math.min` against `Number(line)` short-circuits via NaN to the fallback. Cursor lands at `(1, 1)` (or the clamped boundary). No throw. |

### 14e. Interaction with all motion types

| ID | Steps | Expected |
|---|---|---|
| 14e.1 | `h`/`j`/`k`/`l` intra-prompt motion. Inspect `cursorByPromptIndex` after each press. | Unchanged. Only prompt-swap (`currentIndex` change) writes to the dict. Intra-prompt cursor motion mutates the live `cursor` variable but not the saved memory. |
| 14e.2 | `<num>G` and `G` intra-prompt jumps. | Same as 14e.1 — no save. |
| 14e.3 | `H`/`M`/`L` (§ 12). | Same as 14e.1 — no save. Even though col resets to 1, no `render` call occurs and no entry is written. |
| 14e.4 | Cross-response `j` (§ 11) — `j` from the last line of A jumps to `(1, col)` of A+1. | The save fires on leaving A (writes `{ lastLine(A), col }`), and the cross-response code then OVERRIDES the restored cursor on A+1 with the cross-target. Inspect both entries after: `cursorByPromptIndex[A]` reflects the leaving position; A+1's cursor is the cross-target (not a previously-saved value). |
| 14e.5 | Search auto-jump (§ 10n) into a prompt with prior memory. | Save fires on leaving the source prompt. On the destination prompt, the search's `placeCursorAt(matchLine, matchCol)` overrides the restored memory (see 14c.4–14c.5). |
| 14e.6 | Cursor-span sanity after any restore: `document.querySelectorAll('#response-body .cursor')` in Console. | Returns exactly one `<span class="cursor">` (existing § 11g.3 / § 9f / § 10a invariant). |

### 14f. Boundary cases

| ID | Steps | Expected |
|---|---|---|
| 14f.1 | Empty response prompt (`(no response captured)` placeholder). Cursor lands somewhere via `placeCursorAt(1, 1)`. Navigate away and back. | Saved cursor for that prompt is whatever `placeCursorAt` resolved to (likely `(1, 1)`). Restore re-applies it. |
| 14f.2 | Prompt with a single empty rendered line (`totalLines() === 1`, `lineLength(1) === 0`). Set cursor at `(1, 1)`. Navigate away and back. | Restore lands at `(1, 1)` — the only valid position. No error. |
| 14f.3 | Visit the first prompt (`currentIndex = 0`), set cursor at `(3, 5)`. Navigate to prompt 1 then back to 0. | Cursor restored to `(3, 5)`. |
| 14f.4 | Visit the last prompt, set cursor at the last line's last col. Navigate away and back. | Cursor restored to that position. |

### 14g. Code-shape regression guards against silent removal

| ID | Steps | Expected |
|---|---|---|
| 14g.1 | `grep -n 'cursorByPromptIndex' web/transcripts-viewer.html` | At least 3 occurrences: declaration (`const cursorByPromptIndex = {}`), write inside `render` (`cursorByPromptIndex[currentIndex] = { line, col }`), and read inside `render` (`const remembered = cursorByPromptIndex[clamped]`). Removing any breaks #67. |
| 14g.2 | Read the `render(index)` function. | Contains both a save block (`if (prompts.length && currentIndex !== clamped) { cursorByPromptIndex[currentIndex] = …; }`) BEFORE the `currentIndex = clamped` assignment, AND a restore block (`const remembered = cursorByPromptIndex[clamped]; if (remembered) cursor = …; else cursor = { line: 1, col: 1 }; placeCursorAt(...)`) at the END. The ordering matters — saving after the swap would write to the wrong index. |
| 14g.3 | Read the save block's guard. | `currentIndex !== clamped` — same-prompt renders (e.g. a no-op re-render) skip the save. Removing this guard would overwrite the saved cursor with the current cursor on every render, including intra-prompt motions if they ever started routing through `render`. |

## 15. Tool-call lines removed from transcripts viewer (issue #65)

Issue #65 removes the `🔧 tool_call: …` lines that used to appear inside `response_text` between prose paragraphs of assistant responses. The fix is **backend-only** in [api/server/claudecode_client.py](api/server/claudecode_client.py): `_extract_assistant_text_blocks(entry)` now collects only `text`-typed content blocks; `tool_use` blocks are dropped at parse time, alongside the already-dropped `thinking` blocks. The previous `_TOOL_CALL_PREFIX` constant, the `('text', …) | ('tool', …)` tuple shape, the `tool_buffer` / `flush_tools` grouping logic, and the leading-tool-call-line dropper are all gone — joining is now a plain `"\n\n".join(texts)` inside `_parse_session.flush`.

The frontend (`web/transcripts-viewer.html`) is unchanged — the viewer just renders whatever `response_text` it receives. An assistant response that consists only of tool calls (no text blocks) now produces `response_text = ""`, which falls through to the frontend's existing `(no response captured)` placeholder.

### 15a. Backend response shape — no tool_call prefix anywhere

| ID | Steps | Expected |
|---|---|---|
| 15a.1 | `curl -s 'http://localhost:8001/claudecode/timeline' \| jq -r '.prompts[].response_text' \| grep -F '🔧 tool_call:'` | Zero matches across every prompt in the timeline. (Previously some prompts contained one or more `🔧 tool_call: Read... Bash... Edit...` lines mid-response.) |
| 15a.2 | `curl -s 'http://localhost:8001/claudecode/timeline' \| jq -r '.prompts[].response_text' \| grep -F '🔧'` | Zero matches. The emoji was only used in the now-removed prefix; no other usage in real Claude transcripts. |
| 15a.3 | Pick a prompt that used to show a `🔧 tool_call:` line mid-response (e.g. one in your local cache from before this change). Re-fetch its response_text. | Mid-response text now reads continuously across the spot where the tool-call line used to sit, separated by the same `\n\n` paragraph break that the join produces. No orphan blank lines. |

### 15b. Frontend rendering

| ID | Steps | Expected |
|---|---|---|
| 15b.1 | Open `transcripts-viewer.html`. Navigate to a prompt whose stored response had both prose paragraphs AND tool calls between them. | The rendered response shows the prose paragraphs back-to-back; no `🔧 tool_call: …` line appears. |
| 15b.2 | Navigate to a prompt whose response was **only** tool calls (no text blocks at all — e.g. a "ran 3 tools then stopped" turn). | The viewer renders the existing `(no response captured)` placeholder text inside `#response-body`. No JS error, no blank card. |
| 15b.3 | Navigate to a prompt with only text blocks (no tool calls). | Unchanged from before — the response renders identically to how it did with the old code (since the join already produced the same output for tool-free responses). |
| 15b.4 | DevTools → search the page DOM for the string `🔧` or `tool_call:` after navigating across multiple prompts. | Zero hits in `#response-body` for any prompt. |

### 15c. Cursor / search / navigation regressions

| ID | Steps | Expected |
|---|---|---|
| 15c.1 | Visit a prompt that used to have N tool-call lines. Note that `totalLines()` for that response is now lower than it was before (the tool-call lines contributed `\n` separators that are gone). Press `G` to jump to the last line. | Cursor lands at the new last line (post-removal). No off-by-N error. |
| 15c.2 | `/some-text<Enter>` for a string that previously appeared *after* a tool-call line in some prompt. | Search still finds it. Match position shifts upward by however many `\n` separators were removed, but the cursor lands on the correct character. |
| 15c.3 | ←/→ day navigation, ↑/↓ prompt navigation, H/M/L screen motions. | All unchanged. |

### 15d. Code-shape regression guards

| ID | Steps | Expected |
|---|---|---|
| 15d.1 | `grep -nF '🔧' api/server/claudecode_client.py` | Zero matches. The emoji should not be re-introduced. |
| 15d.2 | `grep -nF '_TOOL_CALL_PREFIX' api/server/claudecode_client.py` | Zero matches. The constant has been removed. |
| 15d.3 | `grep -nF "'tool'" api/server/claudecode_client.py` | Zero matches for the `'tool'` kind tag (the tuple-shape sentinel). Docstrings may still mention `tool_use` to explain *what is dropped* — those don't use the bare `'tool'` literal. |
| 15d.4 | Read `_extract_assistant_text_blocks`. | Returns `list[str]` of text-block contents only. No `tool_use` branch, no `('text', …)` tuple wrapping. |
| 15d.5 | Read `_parse_session.flush`. | Inlines the join: `current_prompt["response_text"] = "\n\n".join(current_response_texts).strip()`. No call to a removed `_render_response_items` helper. |

## 16. 30-day work summary on home screen via backend + localStorage cache (issue #74)

Issue #74 adds an LLM-generated prose summary of the last ~30 days of closed-issue work as a new `#summary-30d` panel on the home screen. The static frontend ([web/index.html](web/index.html)) calls a new local backend route `GET http://localhost:8001/summary/30days` (defined in [api/server/main.py](api/server/main.py) and [api/server/summary_client.py](api/server/summary_client.py)) that fetches closed issues from the GitHub API, feeds them to a Gemini model via Google AI Studio (`google-genai` SDK, `gemini-2.5-flash-lite`, key in `.env` as `GEMINI_API_KEY`), and returns a strictly-under-50-word prose paragraph. The rendered summary is cached in `localStorage` under the key `firstcontact:summary-30d:v1` with a 24-hour TTL so visits while the backend is down still show the last-known-good summary.

Sibling of the rejected hand-curated version (#73, `[Rejected]`).

### 16a. Backend smoke

| ID | Steps | Expected |
|---|---|---|
| 16a.1 | Backend up with `GEMINI_API_KEY` set. `curl http://localhost:8001/summary/30days` | HTTP 200, JSON with keys `summary` (string), `word_count` (int, ≤ 50), `generated_at` (ISO timestamp ending in `Z`), `issue_count` (int ≥ 0). |
| 16a.2 | `curl -s http://localhost:8001/summary/30days \| jq -r .summary \| wc -w` | Integer ≤ 50. |
| 16a.3 | `curl http://localhost:8001/health` | Still returns `{"status":"ok"}` — the new route doesn't break the existing health endpoint. |
| 16a.4 | Stop the backend, unset `GEMINI_API_KEY` in `.env`, restart. `curl -i http://localhost:8001/summary/30days` | HTTP 502 with JSON body `{"detail": "GEMINI_API_KEY must be set in the environment (.env). Generate one at https://aistudio.google.com/apikey."}`. Re-set the key and restart when done. |
| 16a.5 | Block outbound to `api.github.com` (firewall rule or DNS override) and call `/summary/30days`. | HTTP 502 with `detail` starting with `"GitHub Issues fetch failed"`. Remove the block when done. |

### 16b. Backend word-count guard

| ID | Steps | Expected |
|---|---|---|
| 16b.1 | In a Python REPL with the venv active:<br>`from summary_client import _word_count, _truncate_to_word_limit, WORD_LIMIT`<br>`_word_count("one two three")` | Returns `3`. |
| 16b.2 | `_truncate_to_word_limit(" ".join(["w"] * 60), 50)` | Returns a string whose `_word_count` is `≤ 50` and which ends in `…`. |
| 16b.3 | Temporarily monkey-patch `summary_client._generate_with_gemini` to return a 60-word string. Call `get_30day_summary()`. | The function calls `_generate_with_gemini` a **second** time with the retry-instruction suffix. Confirm via a counter or a captured-args list. |
| 16b.4 | Same as 16b.3, but make the stub return 60 words on **both** calls. | The returned `word_count` is `≤ 50` and the `summary` ends with `…` — truncation fallback. |

### 16c. Backend issue-list shaping

| ID | Steps | Expected |
|---|---|---|
| 16c.1 | In a REPL: `from summary_client import _extract_prefix`. `_extract_prefix("feat: thing")` / `"fix(infra): thing"` / `"chore: x"` / `"docs: y"` / `"random title"`. | Returns `"feat"`, `"fix"`, `"chore"`, `"docs"`, `"other"` respectively (lowercased). |
| 16c.2 | In a REPL: `from summary_client import _fetch_recent_closed_issues`. `asyncio.run(_fetch_recent_closed_issues())` | Returns a list of dicts with `title`, `closed_at`, `number`. All entries have `closed_at` within the last 30 days. No entry has `pull_request` set. Length ≤ 50. Sorted by `closed_at` desc. |
| 16c.3 | `from summary_client import _build_prompt`. Build a prompt with a fake list. Confirm shape. | Prompt body lists each issue as `- [<prefix>] <title>` and ends with an explicit-cap instruction. |

### 16d. Frontend cache-hit path

| ID | Steps | Expected |
|---|---|---|
| 16d.1 | DevTools Console:<br>`localStorage.setItem('firstcontact:summary-30d:v1', JSON.stringify({ summary: 'Fresh cached summary text.', generated_at: new Date().toISOString(), ttl_hours: 24 }))`<br>Reload the page. DevTools → Network filter "summary". | The `#summary-30d` panel renders `Fresh cached summary text.` immediately. **No** request to `localhost:8001/summary/30days` appears in the Network panel. |
| 16d.2 | Inspect `#summary-30d` in Elements. | Single `<h2>Last 30 days</h2>` + single `<p>Fresh cached summary text.</p>`. No `.footnote` span present. |

### 16e. Frontend cache-miss path

| ID | Steps | Expected |
|---|---|---|
| 16e.1 | Console: `localStorage.removeItem('firstcontact:summary-30d:v1')`. Reload with backend up. | Network shows exactly one `GET http://localhost:8001/summary/30days` (status 200). The panel renders the backend's prose. |
| 16e.2 | Console: `JSON.parse(localStorage.getItem('firstcontact:summary-30d:v1'))` | Returns `{summary: "<text>", generated_at: "<recent ISO>", ttl_hours: 24}`. `Date.now() - new Date(generated_at).getTime() < 60_000` (timestamp is ≈ now). |

### 16f. Frontend cache-expiry path

| ID | Steps | Expected |
|---|---|---|
| 16f.1 | Console:<br>`localStorage.setItem('firstcontact:summary-30d:v1', JSON.stringify({ summary: 'Stale prose from yesterday.', generated_at: new Date(Date.now() - 25 * 3600_000).toISOString(), ttl_hours: 24 }))`<br>Reload with backend up. | The stale prose renders instantly (first paint). Then one network call to `localhost:8001/summary/30days` fires, and the prose is replaced with the fresh response. The new cache entry's `generated_at` is now ≈ current time. |

### 16g. Frontend backend-down

| ID | Steps | Expected |
|---|---|---|
| 16g.1 | Console: `localStorage.removeItem('firstcontact:summary-30d:v1')`. Block `localhost:8001` (Appendix C) **or** simply stop the backend. Reload. | The panel renders the message `Backend unreachable at http://localhost:8001 — start the local server (see api/server/README.md).`. No `.footnote` span. No throw. |
| 16g.2 | Console (with backend still blocked):<br>`localStorage.setItem('firstcontact:summary-30d:v1', JSON.stringify({ summary: 'Stale cached prose.', generated_at: new Date(Date.now() - 25 * 3600_000).toISOString(), ttl_hours: 24 }))`<br>Reload. | The stale prose renders. Below it, a smaller muted line reads `(showing cached summary; backend unreachable)`. |
| 16g.3 | Re-enable backend, clear cache, reload. | Returns to the happy path of 16e.1. Unblock and clear when done. |

### 16h. Word-count cap at the rendered DOM

| ID | Steps | Expected |
|---|---|---|
| 16h.1 | After any successful render (cache-hit or fresh):<br>`document.querySelector('#summary-30d p').textContent.trim().split(/\s+/).length` | Integer ≤ 50. |

### 16i. XSS defense

| ID | Steps | Expected |
|---|---|---|
| 16i.1 | Override the backend response (Appendix E) so `summary` is the literal string `<img src=x onerror=alert('XSS')>`. Clear cache, reload. | The angle-bracket text renders **as text** inside the `<p>`. **No** alert dialog. Elements panel shows the `<p>` containing a single Text node whose content is the literal string (no `<img>` element materialized). Disable the override when done. |

### 16j. Layout collision-avoidance

| ID | Steps | Expected |
|---|---|---|
| 16j.1 | Desktop 1440×900. | `#summary-30d` is `position: fixed; bottom: 1rem; left: 50%; transform: translateX(-50%)` — anchored to **bottom-center** of the viewport. Width is `min(20rem, calc(100vw - 2rem))` (same formula as `#recent-tasks`) so on desktop it's exactly 20rem and doesn't change when the window resizes. `max-height: 25vh` with `overflow-y: auto` for long Gemini summaries. Hero (Hello, World + device + quote) is centered in the upper portion. No overlap with `#recent-tasks` (top-right) or `.tool-links` (bottom-right) on viewports ≥ ~42rem wide. |
| 16j.2 | DevTools device toolbar → 375×667 (iPhone SE). | `#summary-30d` width = `min(20rem, calc(100vw - 2rem))` ≈ 328 px on a 375-px viewport. The bottom-center panel may visually collide with `.tool-links` (bottom-right) on narrow viewports — both are pinned to bottom. Document this trade-off for future iteration. No horizontal scrollbar on the body. |
| 16j.3 | Device toolbar → 360×640. | Same as 16j.2. The bottom-center summary panel + bottom-right tool-links may overlap at this viewport width. A follow-up issue could collapse the tool-links into a hamburger or reposition the summary panel on narrow screens. |
| 16j.4 | Wide desktop, resize the window from 1920×1080 down to 1024×768. | `#summary-30d` width stays at 20rem throughout — the panel **does not resize** as the viewport shrinks (until the viewport is narrower than ~22rem, at which point the `min()` formula clamps the width to `100vw - 2rem`). Matches `#recent-tasks` behavior. |

### 16k. Code-shape regression guards

| ID | Steps | Expected |
|---|---|---|
| 16k.1 | `grep -n 'GEMINI_API_KEY' api/server/.env.example api/server/README.md api/server/summary_client.py` | Three or more matches across at least these three files. Confirms the env var is documented in both setup README and `.env.example`, and read from the client module. |
| 16k.2 | `grep -nF 'gemini-2.5-flash-lite' api/server/summary_client.py` | Exactly one match (the `GEMINI_MODEL` constant). |
| 16k.3 | `grep -nF "'firstcontact:summary-30d:v1'" web/index.html` | At least one match (storage key string literal). |
| 16k.4 | `grep -cE 'WORD_LIMIT = 50' api/server/summary_client.py` | Returns `1`. |
| 16k.5 | `grep -cE 'TTL_HOURS = 24' web/index.html` | Returns `1`. |

### 16l. View rotation mechanic (issue #79)

`#summary-30d` is tappable: each tap (or `Enter` / `Space` while focused) cycles the panel body through three views, then back to view 1. View 2 and view 3 are placeholder lines for this issue — the body reads `View 2: Work in progress` and `View 3: Work in progress` respectively.

| ID | Steps | Expected |
|---|---|---|
| 16l.1 | Hard-refresh with backend up + fresh cache. | View 1 renders the Gemini prose paragraph (existing § 16d.1 / § 16e.1 behavior). |
| 16l.2 | Click the panel. | View 2 — the `<p>` inside `#summary-30d` now reads `View 2: Work in progress`. Any pre-existing `.footnote` span is removed. |
| 16l.3 | Click again. | View 3 — body reads `View 3: Work in progress`. The view number distinguishes it from view 2. |
| 16l.4 | Click again. | Cycles back to view 1. The original prose re-renders. If the page-load state included a `(showing cached summary; backend unreachable)` footnote (the stale-with-failed-refresh path from § 16g.2), that footnote is re-attached. |
| 16l.5 | View 1 visible. Drag-select a few words inside the prose paragraph (mousedown, drag across text, mouseup). | Text is selected and can be copied. **The view does not advance** — the `window.getSelection().toString().length > 0` guard rejects the click that fires on mouseup. |
| 16l.6 | Tab to focus the panel (focus indicator: background-brightness shift via `:focus-visible`). Press `Enter`. Press `Space`. | Each press advances one view, parallel to a tap. |
| 16l.7 | DevTools → Elements → select the `<section id="summary-30d">` node. Confirm attributes: `role="button"`, `tabindex="0"`, `aria-live="polite"`, `aria-label="Summary of the last 30 days. Tap to cycle view."`. | All four present. The `<span class="cycle-glyph" aria-hidden="true">⟳</span>` child is present right after the opening `<section>` tag. |
| 16l.8 | After cycling to view 3, hard-refresh. | Panel returns to view 1. View counter is in-memory only — no `localStorage` entry created for it (only the existing `firstcontact:summary-30d:v1` key is set, unrelated to the view counter). |
| 16l.9 | Wait for view 1's Gemini prose to render (full paragraph, not the `Loading summary…` placeholder). Tap to view 2. | Panel height is **unchanged** — the `View 2: Work in progress` placeholder occupies a panel of the same height as the prose, with empty space below. `#summary-30d` shows an inline `style="min-height: <Npx>"` matching the view-1 height. Tap to view 3 → same. Tap back to view 1 → same height (prose re-renders within the locked size, possibly with a stale-cache footnote if applicable). |

## 17. Persistent day-position and cursor memory across page refreshes (issue #68)

Issue #68 adds `localStorage` persistence on top of the existing in-memory `lastIndexByDay` (#66, § 13) and `cursorByPromptIndex` (#67, § 14) dicts. The dicts are hydrated from `localStorage` **before** the first `render()` call so initial rendering honors saved state, and they are written through (with insertion-order eviction) on every modification. Storage shape: two keys under the prefix `firstcontact:transcripts-viewer:v1:` — `:lastIndexByDay` and `:cursorByPromptIndex`. Caps: 100 days and 500 prompts respectively. All `localStorage` reads/writes are try/catch-wrapped and parsed entries are shape-validated (whole dict rejected on any malformed entry).

The pre-existing § 10m.3 / § 13e.1 / § 14a.3 / § 14c.3 cases were updated to reflect the new survives-refresh behavior. § 17 below is the new persistence-specific coverage.

### 17a. Hydrate-on-load

| ID | Steps | Expected |
|---|---|---|
| 17a.1 | DevTools Console: `localStorage.setItem('firstcontact:transcripts-viewer:v1:lastIndexByDay', JSON.stringify({'2026-05-25': 4}))`. Hard-refresh. In Console: `lastIndexByDay`. | Object includes `{'2026-05-25': 4}`. Then press ← or → to navigate to 2026-05-25 — landing prompt is index 4 (not the day's `first_prompt_index`). |
| 17a.2 | Console:<br>`localStorage.setItem('firstcontact:transcripts-viewer:v1:cursorByPromptIndex', JSON.stringify({3: {line: 7, col: 2}}))`<br>Hard-refresh, then navigate to prompt 3 (e.g. arrow keys or `?prompt=3` URL). | Cursor on prompt 3 lands at `(7, 2)`, not `(1, 1)`. |
| 17a.3 | Console with both keys pre-seeded as above, hard-refresh, **don't** navigate yet. Inspect `lastIndexByDay` and `cursorByPromptIndex` immediately. | Both dicts are populated from storage **before** `render(startIndex)` runs — confirms the hydration call sits ahead of `render` in the load IIFE. |

### 17b. Write-on-modify (round-trip)

| ID | Steps | Expected |
|---|---|---|
| 17b.1 | Console: `localStorage.clear()`. Hard-refresh. Navigate ↓ several prompts. After each press, in Console: `localStorage.getItem('firstcontact:transcripts-viewer:v1:lastIndexByDay')`. | Each navigation that crosses a day boundary updates the storage immediately (storage call fires inside `render` after `lastIndexByDay[p.day] = clamped`). Same-day navigation also writes (every render with a day-bearing prompt writes). |
| 17b.2 | Same setup. On prompt A, press `5G`. Press ↓ to prompt B. In Console: `JSON.parse(localStorage.getItem('firstcontact:transcripts-viewer:v1:cursorByPromptIndex'))`. | Storage contains `{A: {line: 5, col: 1}}` — the leaving-A save fired and persisted. (Writes fire in the same `currentIndex !== clamped` branch that updates the in-memory dict.) |
| 17b.3 | After 17b.2, hard-refresh. Navigate back to prompt A. | Cursor restores to `(5, 1)` from the persisted entry. |

### 17c. Refresh-survives-day-position (end-to-end)

| ID | Steps | Expected |
|---|---|---|
| 17c.1 | Visit day D, then within D navigate to prompt P (not D's first). Hard-refresh. Press ← (or → if D is the first day). | Lands at P, not D's `first_prompt_index`. |
| 17c.2 | Visit days D1, D2, D3 at distinct in-day prompts. Hard-refresh. ← / → cycle through D1 → D2 → D3. | Each day lands at the pre-refresh saved prompt. |

### 17d. Refresh-survives-cursor (end-to-end)

| ID | Steps | Expected |
|---|---|---|
| 17d.1 | On prompt A press `5G` then `l` × 3 (cursor at `(5, 4)`). ↓ to prompt B (saves A). Hard-refresh, then navigate back to A. | Cursor on A restored to `(5, 4)`. |
| 17d.2 | Visit five prompts with distinct cursor positions. Hard-refresh. Re-visit each. | Each restored to its pre-refresh `(line, col)`. |

### 17e. Schema-version-mismatch graceful ignore

| ID | Steps | Expected |
|---|---|---|
| 17e.1 | Console: `localStorage.setItem('firstcontact:transcripts-viewer:v0:lastIndexByDay', JSON.stringify({'2025-01-01': 99}))`. Hard-refresh. In Console: `lastIndexByDay`. | The v0 key is ignored (the hydration code only reads `:v1:`). `lastIndexByDay` does NOT contain `'2025-01-01': 99`. Remove the stale key when done. |
| 17e.2 | Read [web/transcripts-viewer.html](web/transcripts-viewer.html): the `STORAGE_PREFIX` constant. | Equals `'firstcontact:transcripts-viewer:v1:'`. To migrate to a new schema, bump the prefix to `:v2:` — old `:v1:` entries are then ignored without explicit cleanup. |

### 17f. Quota-exceeded fallback

| ID | Steps | Expected |
|---|---|---|
| 17f.1 | Console:<br>`const orig = Storage.prototype.setItem; Storage.prototype.setItem = function(){ throw new Error('quota'); };`<br>Then navigate ↓ in the viewer. | No JS error surfaces. The viewer still works — in-memory dicts still update, only the persist step swallows the throw. Restore: `Storage.prototype.setItem = orig`. |

### 17g. Corrupted-entry fallback

| ID | Steps | Expected |
|---|---|---|
| 17g.1 | Console: `localStorage.setItem('firstcontact:transcripts-viewer:v1:lastIndexByDay', '{not valid json')`. Hard-refresh. In Console: `lastIndexByDay`. | The malformed entry is rejected (`JSON.parse` throws, caught). Dict starts empty. No alert / no thrown error to the user. Storage entry stays as-is until the next legitimate write replaces it. |
| 17g.2 | Console: `localStorage.setItem('firstcontact:transcripts-viewer:v1:cursorByPromptIndex', JSON.stringify({5: {line: 'not-a-number', col: 2}}))`. Hard-refresh. In Console: `cursorByPromptIndex`. | The whole dict is rejected (one bad entry → entire dict ignored, per the issue's "reject the entire dict, not entry-by-entry" rule). `cursorByPromptIndex` is empty. |
| 17g.3 | Console: `localStorage.setItem('firstcontact:transcripts-viewer:v1:lastIndexByDay', JSON.stringify('not an object'))`. Hard-refresh. | Top-level type check (`typeof parsed === 'object' && !Array.isArray`) rejects it. Dict starts empty. |
| 17g.4 | Console: `localStorage.setItem('firstcontact:transcripts-viewer:v1:lastIndexByDay', JSON.stringify([1, 2, 3]))`. Hard-refresh. | Array is rejected by the same top-level check. Dict starts empty. |

### 17h. Eviction trigger — insertion-order, capped at 100 / 500

| ID | Steps | Expected |
|---|---|---|
| 17h.1 | Console:<br>`const big = {}; for (let i = 0; i < 105; i++) big['2026-' + String(i).padStart(3,'0')] = i;`<br>`localStorage.setItem('firstcontact:transcripts-viewer:v1:lastIndexByDay', JSON.stringify(big));`<br>Hard-refresh, then navigate (any ↑/↓/←/→). After the first day-update render, in Console: `Object.keys(lastIndexByDay).length`. | After the first write-through, eviction trims to `DAY_CAP === 100`. The five oldest-inserted entries (`'2026-000'` through `'2026-004'`) are dropped first; the navigation just performed appends a new key (or updates an existing one). Net: ≤ 100. |
| 17h.2 | Same flow but pre-seed cursor dict with 510 entries: `for (let i = 0; i < 510; i++) big[i] = {line: 1, col: 1}`. | After first cursor write-through, `Object.keys(cursorByPromptIndex).length === CURSOR_CAP === 500`. |
| 17h.3 | Manually walk the eviction with both dicts under cap. Trigger a single render that adds one entry, putting the dict at exactly `CAP + 1`. | One entry dropped: the oldest-inserted (front of `Object.keys()`). The newly-added entry remains. |
| 17h.4 | Pre-seed cursor dict with 600 entries (well over cap), hard-refresh, observe initial state. | Initial `cursorByPromptIndex` has all 600 entries until the first `render()` write triggers eviction. (Hydration doesn't evict on its own.) |

### 17i. Code-shape regression guards

| ID | Steps | Expected |
|---|---|---|
| 17i.1 | `grep -nF 'firstcontact:transcripts-viewer:v1:' web/transcripts-viewer.html` | Exactly one match (the `STORAGE_PREFIX` constant). |
| 17i.2 | `grep -nE 'hydrateMemory\(\)' web/transcripts-viewer.html` | Exactly two matches: the function definition and a single call inside the load IIFE. The call must sit **before** `render(startIndex)`. |
| 17i.3 | `grep -nE 'persistDay\(\)\|persistCursor\(\)' web/transcripts-viewer.html` | At least four matches: the two function definitions plus at least one call site each (inside `render`). |
| 17i.4 | Read the load IIFE. The order is: `prompts = …; days = …; hydrateMemory(); render(startIndex);` | The hydration call must precede `render` so the initial render honors the persisted cursor for the starting prompt. |
| 17i.5 | `grep -nE 'DAY_CAP = 100\|CURSOR_CAP = 500' web/transcripts-viewer.html` | Both constants present (exactly once each). |
| 17i.6 | Read `safeRead`, `safeWrite`, `isValidDayDict`, `isValidCursorDict`. | All four are present and shaped per the description. `safeRead` returns `null` on parse failure, non-object top-level, or array top-level. `isValid*Dict` walk all values and return `false` on any malformed entry (whole-dict rejection). |

## 18. First-line-only prompt on the prompt-line (issue #85)

Issue #85 collapses any multi-line user prompt (typically `/ship` and other slash commands that carry trailing context lines) to its first line on the prompt-line. The underlying `prompts[i].user_text` is unchanged — only the rendered prompt-line is truncated. Search and cursor coordinates continue to use the full text.

Implementation: a single change inside `render(index)` in [web/transcripts-viewer.html](web/transcripts-viewer.html) — `userText` is now `(p.user_text || '').split('\n', 1)[0].replace(/\s+$/, '')`. Both the `Claude: … User: …` branch (when the previous response ends with `?`) and the bare `User: …` branch use the same collapsed `userText`.

### 18a. Rendering

| ID | Steps | Expected |
|---|---|---|
| 18a.1 | Open `transcripts-viewer.html`. Navigate (↑/↓) to a prompt whose `user_text` starts with a slash command (e.g. `/ship`) followed by `\n\n` and additional context lines. | Prompt-line shows `… User: /ship` only. The context lines do not appear on the prompt-line. |
| 18a.2 | Same as 18a.1 but the previous response ends with `?` (so the `Claude: <question> User: …` form is active). | Prompt-line shows `… Claude: <question> User: /ship`. Trailing context still suppressed. |
| 18a.3 | Navigate to a single-line prompt (no `\n` anywhere). | Prompt-line is unchanged from prior behavior — the entire prompt is shown. |
| 18a.4 | Navigate to a prompt whose first line ends with trailing spaces or tabs (e.g. `"/ship   \nbody"`). | Prompt-line shows `… User: /ship` with the trailing whitespace stripped. No double space before any following text. |
| 18a.5 | Navigate to an empty `user_text` (defensive — `prompts[i].user_text === ''`). | Prompt-line shows `… User: ` with nothing after. No JS error. |

### 18b. Underlying data preserved

| ID | Steps | Expected |
|---|---|---|
| 18b.1 | DevTools console: navigate to a multi-line prompt at index `i`, then evaluate `prompts[i].user_text`. | Returns the full multi-line string, unchanged — newlines and trailing content intact. The truncation is render-only. |
| 18b.2 | `/<text-from-line-2-of-a-multiline-prompt><Enter>` to search for a substring that only exists past the first line of some prompt's `user_text`. (Note: search scope is `response_text`, not `user_text` — see § 10. So this test is to confirm that confining the prompt-line render doesn't alter that scope.) | Search behavior is unchanged from § 10. The result is whatever the existing `response_text`-only search returns. |
| 18b.3 | Press `j` / `k` to move the cursor down/up through a response whose prompt happens to be multi-line. | Cursor motion is identical to a single-line-prompt case. Cursor coordinates are tied to the response body, not the prompt-line. |

### 18c. Code-shape regression guards

| ID | Steps | Expected |
|---|---|---|
| 18c.1 | `grep -nF "split('\n', 1)" web/transcripts-viewer.html` | Exactly one match — inside `render(index)`, building `userText`. |
| 18c.2 | `grep -nF 'p.user_text || ' web/transcripts-viewer.html` | Exactly one match — the same line. No other code path bypasses the first-line collapse for the prompt-line. |
| 18c.3 | Read the two `buildPromptLine(...)` calls in `render(index)`. | Both branches pass the same `userText` variable. Neither re-derives a multi-line version. |

## 19. "Changes made this week" last-known-good cache (issue #136)

Issue #136 makes the homepage "Changes made this week" panel resilient to a failing GitHub fetch. The fetch is unauthenticated and browser-side, so it can fail on the anonymous 60/hr rate limit (403) or a transient 5xx/offline blip — previously that blanked the panel to "Could not load recent changes." Now the panel caches its last successful list in `localStorage` (key `firstcontact:recent-changes:v1`), renders it immediately on mount, and falls back to it on fetch failure; the error message only shows when there is no cache.

Implementation: `readRecentCache`/`writeRecentCache` helpers in [app/page.tsx](app/page.tsx) (mirroring the 30-day-summary `readCache`/`writeCache`), and a rewritten recent-changes `useEffect` — cache-first render, `writeRecentCache(recent)` on a non-empty success, and a `catch` that only sets the `error` state when `cached` is null.

### 19a. Cache-first render + revalidation

| ID | Steps | Expected |
|---|---|---|
| 19a.1 | Fresh browser (no `firstcontact:recent-changes:v1` in Local Storage). Load `/`. | Panel shows "Loading…" briefly, then the live list of issues closed this week (PRs filtered out). Application → Local Storage now holds the key with an `items` array + `generated_at`. |
| 19a.2 | With a populated cache, hard-refresh `/`. | Panel shows the cached list immediately (no "Loading…" flash), then updates in place when the live fetch resolves. |
| 19a.3 | Fetch succeeds but returns no issues closed this week (override the `/issues` response to `[]` per Appendix E, or pick a quiet week). | Panel shows "No changes this week." The cache is **not** overwritten with an empty list (an empty success leaves the prior last-known-good intact). |

### 19b. Failure fallback

| ID | Steps | Expected |
|---|---|---|
| 19b.1 | With a populated cache, block `*api.github.com*` (Appendix C) and hard-refresh. | Panel shows the cached list. **No** "Could not load recent changes." message. No blank panel. |
| 19b.2 | Same as 19b.1 but with the Network throttle set to **Offline** (Appendix D). | Same as 19b.1 — cached list shown, no error. |
| 19b.3 | Clear Local Storage (no cache), then block `*api.github.com*` and hard-refresh. | Panel shows "Could not load recent changes." (the only path that still surfaces the error). |
| 19b.4 | Override the `/issues` response to malformed JSON (Appendix E) with a populated cache. | Cached list shown, no error (parse failure is caught like any other). |

### 19c. Corrupted / partial cache tolerance

| ID | Steps | Expected |
|---|---|---|
| 19c.1 | Set `localStorage['firstcontact:recent-changes:v1'] = 'not json'` via console, then reload with the fetch blocked. | No JS error. `readRecentCache` returns null → "Could not load recent changes." (no cache to fall back to). |
| 19c.2 | Set the key to `{"items":[{"id":1},{"title":"x"},{"id":2,"title":"ok"}]}` (mixed valid/invalid entries), reload with fetch blocked. | Only the well-formed entry (`id:2,"ok"`) renders; malformed entries are dropped by the type-guard filter. No error, no crash. |

### 19d. Code-shape regression guards

| ID | Steps | Expected |
|---|---|---|
| 19d.1 | `grep -nF 'firstcontact:recent-changes:v1' app/page.tsx` | Exactly one match — the `RECENT_STORAGE_KEY` constant. |
| 19d.2 | `grep -nF 'writeRecentCache(recent)' app/page.tsx` | Exactly one match — inside the non-empty success branch only. The empty branch does not write the cache. |
| 19d.3 | Read the recent-changes `useEffect` `catch` block. | It sets the `error` state only inside `if (!cached)`. With a cache present, the catch is a no-op (the cached list rendered before the fetch stays on screen). |

## 20. GitHub Treemap embed at `/ghstars` (issue #139)

Issue #139 ports the third-party `xiaoxiunique/1k-github-stars` treemap into the webapp as a client-rendered route at `/ghstars`, fetching its dataset at runtime. Source under `components/treemap/` + `lib/treemap/`; `lib/treemap/data.ts` is pure functions over a fetched `RepoData`; tabs + language/tier drill are client state (no router). Dataset (`public/treemap-data/repos.json`) is gitignored — present in `npm run dev`, absent on Vercel (graceful empty state).

### 20a. Route + data loading

| ID | Steps | Expected |
|---|---|---|
| 20a.1 | `npm run dev`, open `/ghstars` with `public/treemap-data/repos.json` present. | Brief "Loading treemap…", then the interactive treemap renders (language blocks sized by stars). |
| 20a.2 | DevTools Network: confirm the dataset request. | `GET /treemap-data/repos.json` → 200. |
| 20a.3 | Remove/rename `public/treemap-data/repos.json` (simulate Vercel), hard-refresh. | "Treemap dataset unavailable" empty state. No crash, no console error thrown past the caught fetch. |
| 20a.4 | From the homepage, click "GitHub Treemap →". | Navigates to `/ghstars`. |

### 20b. Views, drill-down, search

| ID | Steps | Expected |
|---|---|---|
| 20b.1 | Click the **Daily** then **Awesome** then **Projects** tabs. | View switches each time; breadcrumb/info line update; drill state resets to overview. |
| 20b.2 | Click a language block in overview. | Drills into that language (detail mode); breadcrumb shows `All Languages › <Lang>`. |
| 20b.3 | In a language detail with >36 repos, click a tier header / "More". | Drills into the tier; breadcrumb shows `All Languages › <Lang> › <tier>`. |
| 20b.4 | Click "All Languages" (and the `<Lang>` crumb) in the breadcrumb. | Returns to overview (resp. back one level to the language). |
| 20b.5 | Type in the Search box. | Treemap filters to matching repos; `?q=` reflects in the URL; "No repositories match" shown when empty. |
| 20b.6 | Switch metric Stars/30d Growth/Forks (Projects view). | Block sizes re-layout by the chosen metric. Daily view has no metric switcher (growth-only). |
| 20b.7 | Hover a repo rectangle. | Tooltip shows repo metadata; created/updated dates load (fetched from `github-treemap.pages.dev/repo-meta.json`). |
| 20b.8 | Click a repo rectangle. | Opens `https://github.com/<owner/repo>` in a new tab. |

### 20c. Isolation + credit

| ID | Steps | Expected |
|---|---|---|
| 20c.1 | Visit `/` (homepage) after visiting `/ghstars`. | Homepage retains its light theme — the treemap's dark styling did not leak (no upstream `globals.css` import). |
| 20c.2 | Inspect the `/ghstars` header. | A visible "Original by xiaoxiunique ↗" link to `https://github.com/xiaoxiunique/1k-github-stars`. |

### 20d. Code-shape regression guards

| ID | Steps | Expected |
|---|---|---|
| 20d.1 | `grep -rnF '@/data/repos.json' lib/treemap components/treemap app/ghstars` | No matches — no build-time dataset import remains. |
| 20d.2 | `grep -rnF 'next/navigation' components/treemap` | No matches — routing replaced by client-state callbacks. |
| 20d.3 | `grep -nF 'public/treemap-data/' .gitignore` | One match — the dataset dir is gitignored. |

### 20e. Star-range tier colors (issue #141)

Detail-view star-range tiers are colored by a webapp-side Viridis ramp (`tierColor` in `lib/treemap/colors.ts`) keyed to star rank — brightest yellow = highest-star tier, purple = lowest. Overview language blocks keep their linguist colors.

| ID | Steps | Expected |
|---|---|---|
| 20e.1 | Drill into a language with several tiers (e.g. JavaScript). | Each `★ a–b` tier is a distinct Viridis color; the highest-star tier is bright yellow (≈`#fde725`), descending toward purple (`#440154`) for the lowest. |
| 20e.2 | Compare the same view across two languages. | Tier colors depend only on star rank, not language — the highest tier is the same yellow in both. |
| 20e.3 | Return to overview (any tab). | Language blocks still use their GitHub-linguist colors (e.g. TypeScript blue, Go cyan) — the Viridis scheme applies only to tiers. |
| 20e.4 | Hover/click tiers; click a tier to sub-drill. | Hover lighten/darken shading and black/white label contrast still work; sub-tiers are themselves Viridis-colored by rank. |
| 20e.5 | Inspect `lib/treemap/data.ts` color logic + `repos.json`. | Unchanged — the override is webapp-only; dataset colors are untouched. |

## 21. Bottom repo-detail panel on `/ghstars` (issue #145)

A persistent, hover-driven bar (`RepoDetailBar` in `components/treemap/Treemap.tsx`) is pinned to the bottom of `/ghstars`. Its first line shows **name**, **owner**, **language** (color dot + name), **★ stars**, **⑂ forks**, **Growth**, **Created**, **Updated**, and the **description** wraps below. The transient floating tooltip is now slimmed to just **name + description** (the bar carries everything else); clicking a cell still opens GitHub.

| ID | Steps | Expected |
|---|---|---|
| 21.1 | Load `/ghstars` (local dev with `repos.json` present); don't hover anything yet. | A fixed-height bar at the bottom shows the placeholder "Hover a repo to see its details". |
| 21.2 | Hover a repo cell in the overview. | First line shows the repo's name (bold) + owner (muted) on the left and language, ★ stars, ⑂ forks, Growth (green when positive), Created and Updated dates on the right; description wraps on line 2 (clamped to ~2 lines). Values match the floating tooltip for the same repo. |
| 21.3 | Hover several repos in turn, comparing the right-hand stats column. | Each stat (language, stars, forks, growth, created, updated) stays at the **same x-position** regardless of name/owner length or value width — fixed-width slots, no horizontal jitter. |
| 21.4 | Move the cursor off the canvas (away from any cell). | The bar keeps showing the last-hovered repo — it persists, it does not revert to the placeholder. |
| 21.5 | Drill into a language (click a group header), then hover a repo cell. | The bar updates for repos in the detail/tier view too; the language dot uses the language color (not the Viridis tier color). |
| 21.6 | Hover a repo, then hover it again after a moment (lets the `repo-meta.json` index load). | Created/Updated show "—" only until the meta index resolves, then fill in with `YYYY-MM-DD` dates (backfilled while still hovering the same repo). |
| 21.7 | Hover repos with very long descriptions. | Description is clamped (no overflow); the canvas above does not reflow — bar height is fixed. |
| 21.8 | Click a repo cell. | GitHub opens in a new tab as before — the bar does not change click behavior. |
| 21.9 | Hover a repo and inspect the floating tooltip near the cursor. | Tooltip shows only the repo **name** (bold) and **description** — no owner, language, stars, forks, growth, or dates (those live only in the bottom bar). |

## 22. DigiKey search product image (issue #162)

The DigiKey search result (`public/digikey-search.html` → local backend `/digikey/pricing`) shows the part's product photo above the price. The backend fetches DigiKey's ProductMedia endpoint best-effort and returns `image_url` (the "Product Photos" `SmallPhoto`); the page renders it on a white chip, and silently omits it when absent. Requires the local backend running (`localhost:8001`).

| ID | Steps | Expected |
|---|---|---|
| 22.1 | With the backend running, open `/digikey-search.html` and search `STM32F407VGT6`. | A product photo (the LQFP chip) appears on a white rounded chip above the `Qty → $price` headline; price and part numbers render as before. |
| 22.2 | Search a part DigiKey has no photo for (or temporarily point the image at a 404). | No image is shown; the price/part-number result still renders normally (no broken-image icon, no error). |
| 22.3 | Inspect the `/digikey/pricing` JSON response (DevTools Network, or curl). | Response includes an `image_url` field — a `mm.digikey.com` `…_sml(200x200).jpg` URL for parts with a photo, `null` otherwise. |
| 22.4 | Stop the backend and search. | Unchanged from before: the "backend unreachable" error message shows (the image feature doesn't affect the offline path). |

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
