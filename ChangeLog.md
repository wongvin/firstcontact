# Changelog

## 2026-06-05

### feat: 30-day work summary on home screen via backend API + localStorage cache (issue #74)

- `api/server/summary_client.py` (new): orchestrates the full summary generation. `get_30day_summary()` fetches closed issues from `https://api.github.com/repos/wongvin/firstcontact/issues` (unauthenticated) with a 30-day `since` window, filters out PRs, sorts by `closed_at` desc, caps at 50 issues, then builds a Gemini prompt listing each issue as `- [<commit-prefix>] <title>` (prefix parsed via a single regex covering `feat|fix|chore|docs|refactor|test|build|ci|perf`). Calls the Generative Language API via the `google-genai` SDK (`client.aio.models.generate_content`, model `gemini-2.5-flash-lite`, `temperature=0.4`) with a system instruction that bans bullet points, emojis, markdown, and "Here is the summary"-style preambles. Server-side word-count guard: if the response is >50 words, retry once with an explicit shorter-prompt suffix; if the retry still overshoots, fall back to a word-boundary truncation with an ellipsis. Returns `{summary, word_count, generated_at, issue_count}`. Empty-issue-list fast path returns a static "No issues were closed in the last 30 days." response without calling the API. `SummaryError` exception unifies all failure modes (missing key, GitHub fetch failed, Gemini call failed, empty response) into a 502 detail string. The Gemini SDK is imported lazily inside `_generate_with_gemini` so the module imports cleanly even if `google-genai` isn't installed yet.
- `api/server/main.py`: new `summary_router = APIRouter(prefix="/summary", tags=["summary"])` with `GET /summary/30days` calling `get_30day_summary()` and wrapping `SummaryError` as `HTTPException(502, ...)` — same shape as the DigiKey / Mouser handlers. App title updated to `"Part-pricing proxy + Claude Code transcript viewer + 30-day summary"`, version bumped to `0.4.0`. Module docstring updated to list the four frontends.
- `api/server/requirements.txt`: added `google-genai>=0.3` (unified Google GenAI SDK covering both AI Studio and Vertex AI).
- `api/server/.env.example`: added `GEMINI_API_KEY=` placeholder line.
- `api/server/README.md`: title and intro rewritten to cover the four frontends. Setup section adds the `GEMINI_API_KEY` step pointing at https://aistudio.google.com/apikey. New "GET /summary/30days" section documents the route shape and the 502 unset-key behavior. Notes section adds the Gemini-auth bullet calling out `gemini-2.5-flash-lite` and the 24-hour-TTL math.
- `web/index.html`: new `#summary-30d` `<section>` placed under the `<blockquote id="quote">` inside the centered hero column. CSS chrome matches the existing translucent panels (`rgba(255, 255, 255, 0.12)` background, `0.5rem` radius, `backdrop-filter: blur(8px)` with `-webkit-` prefix). New `loadSummary30d()` IIFE alongside `loadQuote()` and `loadRecent()`. Cache shape: `{ summary, generated_at: ISO, ttl_hours: 24 }` under key `firstcontact:summary-30d:v1`. Flow: read cache → if fresh (age < `ttl_hours * 3600_000`), render and return with no network call; if stale-or-missing, render stale value first (if any) for instant paint, then fetch `http://localhost:8001/summary/30days` in the background — on success replace the prose and write to cache, on failure either keep stale + a muted `(showing cached summary; backend unreachable)` footnote span or render the `Backend unreachable at http://localhost:8001 — start the local server (see api/server/README.md).` fallback. All `localStorage` reads/writes wrapped in try/catch for quota / private-browsing safety. Prose rendered via `textContent` (defense-in-depth against any `<script>`-laden backend response).
- `web/CLAUDE.md`: opening paragraph rewritten to note that the static page calls into the local backend for the 30-day summary, with graceful fallback when the backend isn't reachable. New paragraph in the data-source section explicitly carves out `#summary-30d` from the "static-only" rule and explains the 24-hour-TTL caching trade-off.
- `web/TEST-PLAN.md`: new § 16 (sub-sections 16a–16k, ~22 cases) covering backend smoke (happy path, missing-key 502, GitHub-fetch-failure 502), backend word-count guard (unit-level `_word_count` / `_truncate_to_word_limit` checks, monkey-patched retry / truncate paths in `get_30day_summary`), backend issue-list shaping (`_extract_prefix`, `_fetch_recent_closed_issues`, `_build_prompt`), frontend cache-hit (no network call), cache-miss (one network call + cache populated), cache-expiry (stale-first paint then replacement), backend-down with and without cache, word-count cap at the rendered DOM, XSS defense (literal angle-bracket text via `textContent`), layout collision-avoidance at 1440 / 375 / 360 viewports, and code-shape regression guards (greps for `GEMINI_API_KEY`, `gemini-2.5-flash-lite`, cache key, `WORD_LIMIT = 50`, `TTL_HOURS = 24`).

## 2026-06-03

### feat: remove tool_call lines from transcripts viewer (issue #65)

- `api/server/claudecode_client.py`: assistant `tool_use` content blocks are now dropped at parse time, alongside the already-dropped `thinking` blocks. The `🔧 tool_call: Read... Bash... Edit...` lines that used to appear inside `response_text` between prose paragraphs are gone — the viewer surfaces only the user-facing prose Claude produced. The previous `_TOOL_CALL_PREFIX` constant, the `('text', …) | ('tool', …)` tuple shape returned by the old `_extract_assistant_items`, the `tool_buffer` / `flush_tools` grouping logic, and the leading-tool-call-line dropper are all removed — joining is now a plain `"\n\n".join(texts)` inside `_parse_session.flush`. Function renamed: `_extract_assistant_items` → `_extract_assistant_text_blocks` (now returns `list[str]`).
- Frontend (`web/transcripts-viewer.html`) is unchanged — it renders whatever `response_text` it receives. An assistant turn that consisted only of tool calls (no text blocks) now produces `response_text = ""`, falling through to the existing `(no response captured)` placeholder.
- `web/TEST-PLAN.md`: new § 15 (sub-sections 15a–15d, 14 cases) covering backend response-shape regression (`curl | jq | grep '🔧'` returns nothing), frontend rendering (prose-only / tool-only / mixed prompts), cursor / search / navigation invariants under the lower total-line count, and code-shape regression guards (greps for `🔧`, `_TOOL_CALL_PREFIX`, `'tool'` literal).

### feat: initial load opens first prompt of last day (issue #66 follow-up)

- `web/transcripts-viewer.html`: changed the page-load default in the load IIFE so that when no `?prompt=` URL parameter is present, `startIndex = days[days.length - 1].first_prompt_index` (the **first prompt of the most-recent day**) instead of `Math.max(0, prompts.length - 1)` (most-recent prompt globally, which on a multi-prompt last day landed mid-day). This makes #66's "initialize prompt location of each day to be the first prompt of the day" apply at load time too, not only on the first ← / → visit to an unvisited day. Explicit URL override (`?prompt=N`) still wins. Empty-`days[]` payload falls through to the existing empty-state path (no crash).
- The per-day position memory `lastIndexByDay` and the `targetForDay` indirection are **unchanged** — once you navigate around in-session, the memory is populated by `render` and used by ←/→ exactly as before. The only behavior change is which prompt is shown on the very first render.
- `web/TEST-PLAN.md` § 13: updated preamble to call out the new load-default behavior alongside the existing in-session machinery. § 13a renamed to "Initialization — load default + unvisited-day fallback both land on first prompt of the day". § 13a.1 flipped from asserting the OLD `prompts.length - 1` landing to asserting the new `days[lastDay].first_prompt_index` landing. Added 13a.1-bis (explicit `?prompt=N` URL override still wins) and 13a.1-ter (empty-days fallback).

### docs: regression coverage for per-prompt cursor-position memory (issue #67)

- `web/TEST-PLAN.md`: new § 14 (sub-sections 14a–14g, ~24 cases) locking in the existing `cursorByPromptIndex` behavior introduced in #45 and unchanged across #50 / #54 / #66. Covers each of #67's three requirements (initialize to `(1, 1)`, remember on visit, restore on transition), cursor-validity clamp safety against corrupted memory, interaction with intra-prompt motions (`h`/`j`/`k`/`l`/`G`/`<num>G`/`H`/`M`/`L`) vs prompt-swaps (↑/↓/←/→/search/cross-response), search auto-jump override behavior (§ 10n), and code-shape regression guards (greps for `cursorByPromptIndex` occurrence count, save-before-swap / restore-after-swap ordering invariant inside `render`).
- No code change. Same shape as #66 — the behavior was already implemented; § 14 makes its preservation testable.

### docs: regression coverage for per-day prompt-position memory (issue #66)

- `web/TEST-PLAN.md`: new § 13 (sub-sections 13a–13g, ~22 cases) locking in the existing `lastIndexByDay` / `targetForDay` behavior introduced in #35 and unchanged across #45 / #50 / #54. Covers each of #66's three requirements (initialize to first prompt, remember on visit, transition to saved location), clamp safety against corrupted memory, memory boundaries (refresh, single-day, day-less prompts), interaction with all other motion types (`/` search auto-jump, cross-response jk, H/M/L, `<num>G`), and code-shape regression guards against re-attempts of #63's removal (greps for `lastIndexByDay` / `targetForDay` occurrence counts).
- No code change. #66 was filed and accepted after #63 was rejected (which would have removed this behavior). This section is the regression coverage that makes the rejection durable — future changes that delete `lastIndexByDay` or `targetForDay` will fail § 13g tests.

## 2026-06-02

### feat: VIM screen-position motions H / M / L (issue #54)

- `web/transcripts-viewer.html`: added three VIM-style "screen position" motions on top of the existing `hjklG/nN` keybinds. `H` jumps the cursor to the first rendered line whose top is at or below the `#output-card` viewport top ("High"); `M` jumps to the rendered line whose vertical center is closest to the viewport midpoint; `L` jumps to the last rendered line whose bottom is at or above the viewport bottom ("Low"). Cursor column resets to `1` on each motion (per issue spec — "cursor column position will be reset to beginning of the new line"). New helpers: `rectForLineStart(line)` builds a non-mutating `Range` over a single character to read its `getBoundingClientRect`; `findVisibleLineRange()` iterates over `1..totalLines()` to find top/mid/bot relative to the viewport, with sensible fallbacks (first / `ceil((1+total)/2)` / last) when the entire response fits inside the viewport. Keyboard handler dispatches `H`/`M`/`L` via `moveCursorAbs(target, 1)` and clears `numberPrefix` (no `<num>H` support). Shift's modifier-only keydown still short-circuits at the existing guard so the capital letters compose with the digit accumulator the same way `G` already does. The issue's note that `gg (top of file) will be implemented with other "g" functions` is out of scope for this commit — it will land in a separate `g`-family issue.
- Help text: `↑↓ prompts · ←→ days · hjklG/nN vim keybind` → `↑↓ prompts · ←→ days · hjklHMLG/nN vim keybind` (added `HML` between `hjkl` and `G`).
- `web/TEST-PLAN.md`: new § 12 (sub-sections 12a–12g, ~24 cases) covering each motion individually, the col-reset requirement, interaction with the number accumulator / search / arrows / G, visual + state side-effects (single cursor span invariant, `cursorByPromptIndex` save, help-text substring), and edge cases (placeholder responses, single-line responses, viewport-sized responses, window resize, cursor-position non-interference with measurement).

## 2026-05-30

### chore(infra): auto-allow `gh issue comment` + `gh pr create`

- `.claude/settings.json`: added `Bash(gh issue comment *)` and `Bash(gh pr create *)` to `permissions.allow` so the `/ship` workflow's "post implementation-summary comment" and "open PR" steps no longer prompt. Promoted from `.claude/settings.local.json` (where they applied only to this checkout) into the committed project settings so they apply for every contributor. Sits alongside the previously-promoted `Bash(gh project item-edit *)` (status transitions). Other `gh pr` and `gh issue` subcommands (`gh pr merge`, `gh issue close`, `gh issue create`) remain gated as separate deliberate decisions.

### chore(infra): generic test-plan + jsdom-runner agents (issue #60)

- `.claude/agents/test-plan-writer.md`: project-scoped subagent that authors a `## N. <Feature>` section in any project's test-plan markdown file (`TEST-PLAN.md`, `TESTS.md`, etc.) from a feature spec + impl reference. Generic — no firstcontact-specific patterns. System prompt describes the general shape (preamble → sub-sections lettered `a`/`b`/`c` → `| ID | Steps | Expected |` tables, IDs `N<letter>.<number>`), the typical coverage areas (happy path / edge / state / interaction / visual / defense), and the process (read existing file for style, find next section number, draft, verify uniqueness). Tools: `Read, Edit, Write, Bash, Grep, Glob`.
- `.claude/agents/test-runner-jsdom.md`: project-scoped subagent that executes a test-plan section against a project's client-side code (HTML + inline `<script>` or a standalone JS module) in a jsdom harness under `/tmp/test-runner-XYZ/`. Generic — describes the PATTERN (install jsdom, extract inline script via `awk`, strip network-call IIFEs, append a `window.__test = { setState, get, call, … }` closure-state shim with names matching the actual impl, build a minimal DOM matching the impl's expectations, dispatch synthesized keyboard events, assert observables) without referring to any specific impl's variable names. Known-skip categories enumerated (`scrollIntoView`, browser-chrome shortcuts, computed styles, real network I/O). Reports as a markdown table with FAIL rows including smallest repro. Tools: `Read, Write, Edit, Bash, Grep, Glob`.
- Both agents stay project-scoped (`.claude/agents/`) so they're versioned with the repo and available to anyone cloning it; their generic content is also copy-paste-portable to other projects' `.claude/agents/` directories. Invocable via `Agent({subagent_type: "test-plan-writer", prompt: …})` and `Agent({subagent_type: "test-runner-jsdom", prompt: …})`.

## 2026-05-29

### chore(infra): move local backend port 8000 → 8001 (issue #58)

- `web/transcripts-viewer.html`, `web/digikey-search.html`, `web/mouser-search.html`: `BACKEND_URL` constant updated from `http://localhost:8000` to `http://localhost:8001`. Port 8000 falls within Windows' WSL excluded-port range, so it isn't bindable for local development on a WSL host. 8001 is adjacent (easy to remember) and doesn't collide with 8080 used by the static `python -m http.server`.
- `api/server/README.md`: `uvicorn main:app --port 8001` example + the "listens on http://localhost:8001" line + the two `curl` examples updated.
- `web/TEST-PLAN.md`: 13 occurrences across § 6 (DigiKey), § 7 (Mouser), § 8 (Transcripts viewer) updated — curl examples, `Backend unreachable at http://localhost:8001` error-message expectations, and the `uvicorn main:app --port 8001` example in 7c.5.
- No code changes in `api/server/main.py` — the backend reads its port from the uvicorn command-line flag; CORS `allow_origins` lists FRONTEND origins (5500 / 8080 / GH Pages), none of which are 8000.

## 2026-05-25

### feat: vim cross-response navigation (issue #50)

- `web/transcripts-viewer.html` `moveCursor(dLine, dCol)`: four new branches at the top of the function detect cursor-at-extreme-boundary cases and cross to the adjacent prompt instead of clamping. `j` at the last line crosses to line 1 of the next response, col preserved (clamped to new line's length). `k` at the first line crosses to the last line of the previous response, col preserved. `h` at `(1, 1)` crosses to the last line / last col of the previous response. `l` at `(lastLine, lastCol)` crosses to `(1, 1)` of the next response. Implementation pattern mirrors search auto-jump: `render(newIdx)` (which auto-saves the leaving cursor and restores any remembered cursor for the destination) followed by an explicit `placeCursorAt(...)` that overrides with the cross-response target. At timeline boundaries (first prompt's `k`/`h`, last prompt's `j`/`l`), the `currentIndex ± 1 < N` / `>= 0` checks fail and the existing intra-response clamp keeps the cursor put.
- `web/TEST-PLAN.md`: new § 11 (sub-sections 11a–11g, 36 test cases) covering basic cross cases for each direction, column preservation under `j`/`k`, timeline boundaries, cursor-memory save/restore interaction, interaction with arrow keys / search / `G`, edge cases (empty destinations, placeholder responses, repeated forward walks), and visual + state side-effects (`#prompt-line` text update, `?prompt=N` URL update, single cursor span in DOM). Automated jsdom runner pass: 35 PASS, 0 FAIL, 0 SKIPPED (one initial 11f.2 mismatch was a test-plan wording error that has been corrected — the case is now consistent with the column-preservation rule for `k`).

### chore(infra): gitignore graphify-out (issue #46)

- `.gitignore`: added `graphify-out/` so the local graph artifacts (`graph.html`, `graph.json`, `GRAPH_REPORT.md`, `cache/`, `manifest.json`, `cost.json`) produced by the `/graphify` skill stay out of the repo. Verified with `git check-ignore -v graphify-out/graph.html`.

## 2026-05-24

### feat: VIM search + cursor navigation in transcripts viewer (issue #45)

- `web/transcripts-viewer.html`: layered VIM-style cursor navigation and search on top of the #35 layout. A `<span class="cursor">` WRAPS the single character at the cursor position with a darker-tint translucent-black background pill (`rgba(0, 0, 0, 0.55)`) — the character stays visible behind the pill; at end-of-line or on a `\n`, the span contains a synthetic space (`data-placeholder="1"`) to give the block visible width. The cursor uses **rendered-text** coordinates — `responseBodyEl.textContent` split by `\n` — so search and navigation operate in the space the user SEES on screen, with markdown markup (backticks, asterisks, link brackets) stripped. The renderer inserts synthetic `\n` text nodes between sibling blocks and between list items so block boundaries become real `\n`s in textContent (visually inert; browsers collapse whitespace between block-level siblings), making `j/k/G` step across paragraph and list-item breaks as expected. `removeCursorSpan` puts the wrapped character back into the DOM as a plain text node and calls `parent.normalize()` to merge adjacent text nodes (so repeated placements don't fragment or eat characters).
- VIM keys (only in normal mode, never with Ctrl/Alt/Meta): `h/l` move col ±1 (clamped to the source line's length), `j/k` move line ±1 (clamped to last/first source line; col re-clamped to the new line's length), `G` jumps to the last source line, `<num>G` consumes a digit accumulator and jumps to that line (clamped to `[1, lastLine]`). Any non-digit non-`G` keypress clears the accumulator.
- Search keys: `/` enters a modal search mode — every subsequent printable key appends to `searchString`, `Backspace` deletes a char (or exits if empty), `Enter` executes, `Escape` cancels. The search bar (`<div class="search-bar">` between `#output-card` and `.help`) displays `/<chars>` left-aligned, min-width 20ch. **In search mode, vim keys are inert** (typing `j` appends `j` to the search string).
- Search scope: `response_text` across **all prompts in the global timeline** (cross-session). `user_text` is NOT searched. The first match wins (forward search from cursor position; wraps the timeline). On match: if the matching prompt isn't current, `render(matchPromptIndex)` swaps the viewer to it, then `placeCursorAt(matchLine, matchCol)` lands on the match. On miss: search bar turns dark red (`rgba(140, 20, 20, 0.9)`) and shows `Pattern not found: <s>` (via `textContent` — never `innerHTML`); auto-clears after 2 seconds.
- `n`/`N` cycle through matches using the last search string, applying the same global-timeline + wrap logic in forward/backward direction.
- Cursor memory per prompt: every prompt-switch (arrow keys OR search auto-jump) saves the OLD prompt's `(line, col)` to `cursorByPromptIndex[oldIdx]` and restores the NEW prompt's remembered position (or defaults to `(1, 1)` if no memory). In-memory only — symmetric with the existing `lastIndexByDay` day-memory. Search auto-jump overrides the restored memory with the match position.
- Arrow keys (↑↓ prompts, ←→ days) are unchanged. Help line reads `↑↓ prompts  ·  ←→ days  ·  hjklG/nN vim keybind`; the search input sits centered above it (same horizontal alignment as the hints).
- Modifier-only keydowns (`Shift`, `Control`, `Alt`, `Meta`, `CapsLock`) short-circuit at the top of the handler so they don't clobber `numberPrefix` — fixed a bug where Shift's keydown (necessary to capitalize the next `G`) was clearing the accumulator and making `<num>G` jump to the last line instead of line `<num>`.
- All new DOM construction continues to use `createElement` + `textContent` / `createTextNode` — no `innerHTML` introduced; honors `web/CLAUDE.md`'s no-dependencies and no-innerHTML rules.
- `web/TEST-PLAN.md`: new § 10 covering cursor on load, h/j/k/l motion, G/`<num>G`, search entry + execution, cross-prompt search, timeline wrap, pattern-not-found error display, n/N navigation, user_text-not-searched negative case, Escape cancellation, modal-mode behavior (typing `j` mid-search), arrow-key regression, cursor memory across prompts, cursor memory + search auto-jump interaction, and defense-in-depth (search input echo via textContent).

### feat: refine transcripts viewer layout (issue #35)

- `web/transcripts-viewer.html`: single output box per prompt — a single `#prompt-line` followed by the markdown-rendered response body. The prompt line normally reads `<date> <time> User: <prompt>`; when the previous response (the previous prompt in the global timeline, even across session boundaries) ends with `?`, the line is prefixed with the Claude question and reads `<date> <time> Claude: <question> User: <prompt>` on the same line — no separate Claude row, same `User:` separator (with colon) in both cases. In the prefix case, the leading datetime is the previous prompt's timestamp (when Claude asked). The prompt line itself is styled as a near-white pill with bold dark-navy text; the time portion (`hh:mm AM/PM`, zero-padded hour) is wrapped in a `<span class="time-chip">` as a DOM hook (no special styling — kept in place so future tint/badge styling can be added without touching the JS). Built via DOM nodes (`createTextNode` + `createElement` + `textContent`) — no `innerHTML` on prompt content. Read-only prompt textarea removed; its CSS rules deleted; the keyboard handler's textarea-focus exemption removed with it.
- Response body is rendered by a hand-rolled in-file markdown subset — fenced code, inline code, markdown links (`[text](url)`), bare URLs, headings `#…######`, unordered (`-`/`*`) and ordered (`1.`) lists (flat), `**bold**`, `*italic*`, `_italic_`, **GFM tables** (header row + `|---|---|` separator + body rows; each cell runs through the inline tokenizer so cells can contain links, inline code, bold, etc.). Rendered links open in a new tab (`target="_blank"` + `rel="noopener noreferrer"` for safe outbound navigation). Inline code that matches an absolute plan-file path (`<home>/.claude/plans/<name>.md`, with optional trailing `:LINE` or `:LINE:COL`) is wrapped in a `vscode://file<path>` link so clicking opens the plan in VS Code; all other inline code stays as plain `<code>`. URL schemes restricted to `http(s)` and `mailto:` — `javascript:`, `data:`, etc. fall back to literal text. All DOM is built via `createElement` + `textContent` / `createTextNode`; no `innerHTML` anywhere, no external dependencies — honors `web/CLAUDE.md` conventions.
- CSS polish on `.response-body` children for visual parity with how a typical Claude.ai chat response reads. The two visual conventions on the page: **bold via font weight, hyperlinks via dark background** — never the reverse. Concretely: `.output-card` font-family removed (response body inherits the sans-serif system stack from `body`) and the response body is set to `font-weight: 300` (light) so bold elements stand out more; inline `<code>` and `<pre>` keep an explicit `ui-monospace` family **and `font-weight: 700`** — so code is distinguished from body prose by bold-monospace typography alone, no background tint. Headings (`<h1>`–`<h6>`) get explicit `font-weight: 700` to preserve their structural boldness against the lighter body. `<pre>` has a thin translucent border and rounded corners; no fill. `<a>` is a clearly marked dark pill (`rgba(0, 0, 0, 0.32)` background, `border-radius: 4px`, `#cfe0ff` text with a semi-transparent underline that brightens on hover). `<strong>` is `font-weight: 700` (no background). `<table>` uses `border-collapse: collapse` with bordered cells and a light tinted `<th>` background. Plan-path links wrap a `<code>` inside the `<a>`; the inner `<code>` inherits color/font from the link so the visual is a single dark pill, not stacked layers.
- Question extraction (`extractTrailingQuestion`): walks back from the trailing `?` to the previous sentence terminator (`.`, `!`, `?`, or `\n`) and returns just that fragment. Handles empty, no-`?`, lone-`?`, and trailing-whitespace cases.
- `web/TEST-PLAN.md`: new § 9 with cases for layout shape, AM/PM datetime, conditional Claude question line, markdown rendering (including GFM table case + a "pipe-without-separator" negative case), defense-in-depth (XSS + javascript:/data: URL schemes), state-preservation regression (replaces obsolete 8c.7), Safari cross-browser, and § 9h CSS-polish visual checks (inline-code border, table borders + tinted header, link underline, side-by-side Claude.ai comparison). § 8 preserved as regression coverage with a pointer to § 9.

### chore(infra): auto-allow gh project item-edit in committed settings (issue #42)

- `.claude/settings.json`: added `Bash(gh project item-edit *)` to `permissions.allow`. The wildcard covers all four project-board transitions (Status → In progress / In review / Done, plus Start date), all of which run the same `gh project item-edit ...` shape with different `--single-select-option-id` or `--date` values. The rule already existed in the gitignored `.claude/settings.local.json` — promoting it makes the auto-allow apply for every contributor and every fresh checkout without manual local-settings tweaks.

## 2026-05-23

### fix: /cleanup-branches handles current-branch delete (issue #40)

- `.claude/skills/cleanup-branches/SKILL.md` step 4: when a candidate is the currently-checked-out branch, switch to `main` and fast-forward via `git merge --ff-only origin/main` (or equivalently `git pull origin main`) before the delete. Documented why bare `git pull` / `git pull --ff-only` fails here — the step-1 `git fetch --prune` leaves `.git/FETCH_HEAD` with multiple for-merge entries, so `pull` aborts with `fatal: Cannot fast-forward to multiple branches`; specifying the source explicitly bypasses FETCH_HEAD.

### docs(infra): refine /ship skill conventions (issue #38)

- `.claude/skills/ship/SKILL.md` subject convention: template now `<prefix>: <summary> (#N)` with a ≤50-char total budget so the issue tag stays visible in narrow UIs (`git log --oneline`, GitHub PR titles); body must not contain `Closes #N` or other `#N` refs; implementation-summary comment trigger derives the issue number from the branch name (`<N>-<slug>`) instead of scanning the commit body for `Closes #N`.
- `.claude/skills/ship/SKILL.md` PR step: new step 6 — after push and the issue comment, ensure a PR exists for the branch (create one with `gh pr create --base main` if missing) and surface the URL. PR body is the one place `Closes #N` is allowed, so the issue auto-closes on merge.

### fix: /cleanup-branches checks origin/main instead of stale local main (issue #38)

- `.claude/skills/cleanup-branches/SKILL.md` step 2: `git branch --merged origin/main` (was `--merged main`). Local `main` lags `origin/main` between a PR merge and the next `git pull`, so the previous form undercounted candidates immediately after a merge — hit during the #36 cleanup itself.

### docs/infra: adopt Claude insights suggestions (issue #36)

- `CLAUDE.md`: add `### Branching` section (feature branch before first edit, `<N>-<slug>` naming); add `### Git branch cleanup` section (delete local + remote after merge, preserve Rejected branches, ask before force-deleting unmerged); add duplicate-issue close rule to `### Closing issues`; add step 4 to `### Tracking active work` requiring a pre-commit implementation-summary issue comment for review on github.com
- `.claude/skills/cleanup-branches/SKILL.md` — new `/cleanup-branches` skill: fetch-prune, list merged branches, cross-check against `[Rejected]` issues, pause before deletion
- `.claude/skills/ship/SKILL.md` — new `/ship` skill: invocation is the explicit commit consent gate; runs status/diff review, ChangeLog check, heredoc commit, push, then heredoc implementation-summary close comments for `Closes #N` refs
- `.claude/settings.json` — new committed post-edit hook: `markdownlint-cli2 --fix` runs only on the touched `.md` file via `$CLAUDE_FILE_PATHS`, not the whole tree
- GitHub MCP server installed at user scope (run-once setup; auth via `gh auth token`)

## 2026-05-22

### feat: Claude Code transcript viewer (issue #33)

- Add `api/server/claudecode_client.py` — JSONL parser that walks `~/.claude/projects/**/*.jsonl`, groups each session's events into `(user_prompt, assistant_response)` pairs (dropping `thinking` blocks, collapsing `tool_use` blocks, skipping `queue-operation` / `ai-title` / `attachment` / `file-history-snapshot` / `last-prompt` / `pr-link` noise), and merges every session into one flat timeline sorted by `timestamp`
- Add a third `APIRouter(prefix="/claudecode")` on `api/server/main.py`. One endpoint: `GET /claudecode/timeline` returns `{prompts: [{index, day, timestamp, session_id, user_text, response_text}], days: [{date, first_prompt_index, last_prompt_index}]}`
- Add new static page `web/transcripts-viewer.html` — response card on top (no `Response` label, minimal padding), datetime line, read-only `<textarea>` prompt editbox at the bottom; no sidebar, no session dropdown, no session-id chip, no "Prompt #N of M"
- Arrow-key navigation operates on the global timeline across session boundaries: ↑↓ moves prompts, ←→ jumps days. `document.activeElement` exemption keeps the textarea's own cursor navigation intact when focused inside it
- **Tool-call rendering tweaks:**
  - Consecutive `tool_use` blocks collapse onto a single line — `🔧 tool_call: Read... Bash... Edit...` — instead of one line per call
  - If the first line of a response (after grouping) is a tool-call line, it's dropped — the viewer leads with the assistant's first user-facing text rather than operational noise
- **Day-position memory** (in-memory only): when navigating away from a day via ←/→ and back, the viewer restores the last prompt you viewed within that day instead of jumping to the day's first prompt
- URL state: `?prompt=<N>` for deep-linking by global prompt index (default = newest prompt)
- Restructure `web/index.html` bottom-right nav into three stacked links: `DigiKey search →`, `Mouser search →`, `Transcripts viewer →`
- Document the new page in `web/TEST-PLAN.md` § 8 (homepage link, backend-unreachable, local-backend smoke including keyboard navigation across session boundaries, defense-in-depth on both response and prompt rendering)
- No new Python dependencies (stdlib `json`, `pathlib` only)

## 2026-05-18

### refactor: combine DigiKey + Mouser API servers into one (issue #26)

- Consolidate `api/digikey/server/` and `api/mouser/server/` into a single `api/server/` FastAPI app — one process, one port (8000), one `.env`, one venv, one CORS middleware block, one `/health`
- Routing namespaced by distributor: `GET /digikey/pricing?manufacturer_part_number=<MPN>` and `GET /mouser/pricing?manufacturer_part_number=<MPN>` (same `?manufacturer_part_number=` param, same response shape as before)
- `digikey_client.py` and `mouser_client.py` move unchanged via `git mv` (history preserved); the routing layer is the only new code (`api/server/main.py` is ~50 lines with two `APIRouter`s)
- `.env.example` now lists all three vars: `DIGIKEY_CLIENT_ID`, `DIGIKEY_CLIENT_SECRET`, `MOUSER_API_KEY`
- `README.md` rewritten to cover both routes; `api/digikey/digikey.postman_collection.json` and `api/mouser/mouser.postman_collection.json` stay (reference docs, not server code)
- Frontends: `web/mouser-search.html` port 8001 → 8000; both pages now fetch `/digikey/pricing` or `/mouser/pricing` instead of bare `/pricing`; error-message README pointers updated
- `web/TEST-PLAN.md` §§ 6 and 7 updated: §§ 6c, 7c hit the single port-8000 backend at different path prefixes; § 7c.5 reframed from "two backends side by side" to "one backend serving both"

## 2026-05-17

### feat: Mouser product search in web app (issue #24)

- Add local FastAPI backend at `api/mouser/server/` on **port 8001** (alongside the DigiKey backend on 8000 — both can run simultaneously) — reads `MOUSER_API_KEY` from `.env`, no OAuth2 token flow needed (Mouser auth is a per-request `?apiKey=` query string)
- New `GET /pricing?manufacturer_part_number=<MPN>` calls `POST https://api.mouser.com/api/v1/search/partnumber` and normalizes the response to match the DigiKey backend's shape: top-level `unit_price` / `tier_quantity` from `tiers[-2]` (second-to-last tier; same selection rule as DigiKey for UX parity), plus `tiers[]` sorted ascending and a `mouser_part_number` echo for reference
- Mouser-specific quirks handled: `Parts[]` can contain multiple matches → pick by exact `ManufacturerPartNumber` (case-insensitive), else first; `PriceBreaks[].Price` arrives as a string ("$0.51" or "0.51") → strip currency symbol and `float()`, tolerating comma-as-decimal locales; surfaces body-level `Errors[]` as 502s
- Add new static page `web/mouser-search.html` — near-clone of `web/search.html` with port 8001 and Mouser-specific labels (placeholder `NE555P`, `Mouser:` caption); displays only the selected tier as `Qty <N> → $<P> USD / unit`
- Restructure `web/index.html` bottom-right link area into a stacked two-link nav: rename the existing "Product search →" to "DigiKey search →" for clarity, add new "Mouser search →" beneath
- Document the new page in `web/TEST-PLAN.md` § 7 (homepage link, backend-unreachable, local-backend smoke including a "both backends side by side" case, defense-in-depth)
- Both backends remain intended for local development; the frontend's `BACKEND_URL` constant is the only edit needed to migrate to a hosted serverless function later
- Followed by issue #27 (sub-issue) entry below: `web/search.html` → `web/digikey-search.html` rename for naming symmetry

### refactor: rename web/search.html to web/digikey-search.html (issue #27, sub-issue of #24)

- `git mv web/search.html web/digikey-search.html` (preserves history)
- Inside the renamed file, update `<title>` and `<h1>` from "Product Search" to "DigiKey Product Search" for symmetry with `web/mouser-search.html`'s `<h1>Mouser Product Search</h1>`
- Update references: `web/index.html` anchor target; `web/TEST-PLAN.md` § 6 page name + URL examples; `api/digikey/server/main.py` module docstring; `api/digikey/server/README.md` relative link in the header
- Deployed URL `https://wongvin.github.io/firstcontact/search.html` will 404 after merge — the only known link was the homepage anchor (now updated); no redirect added since GH Pages doesn't support server-side redirects without a build step

## 2026-05-16

### feat: add Mouser API Postman collection (issue #25)

- Add `api/mouser/mouser.postman_collection.json` + `api/mouser/mouser.postman_environment.json` — Postman v2.1.0 collection covering Mouser Search API (`KeywordSearch`, `PartNumberSearch`, `ManufacturerList`); auth via `?apiKey={{api_key}}` query param (no OAuth2 token flow needed)
- Add `postman/collections/Mouser API/` YAML mirror (`Search/{KeywordSearch,PartNumberSearch,ManufacturerList}.request.yaml`) and `postman/environments/Mouser API Environment.environment.yaml` to match the dual-format layout established for DigiKey
- Endpoint selection: V1 `/api/v1/search/keyword` + `/api/v1/search/partnumber` (no required-manufacturer-name complication) and V2 `/api/v2/search/manufacturerlist` (clean api-key smoke test)
- Smoke-tested every URL with `curl` + a bogus `apiKey=PROBE` before committing — all three return HTTP 200 with a clean body-level error, confirming the paths exist and accept the expected body shape (no repeat of the #19 speculative-URL trap)

## 2026-05-13

### feat: DigiKey product search in web app (issue #20)

- Add local FastAPI backend at `api/digikey/server/` — proxies DigiKey's ProductPricing API with OAuth2 client-credentials, caching the access token in-memory until 60s before expiry; CORS allows `localhost:5500/8080` and `https://wongvin.github.io`
- New `GET /pricing?manufacturer_part_number=<MPN>` returns the resolved DigiKey part number, all normalized tiers (ascending by quantity), and a chosen tier (`tiers[-2]`, i.e. second-to-last) flattened to top-level `unit_price` + `tier_quantity`
- Add new static page `web/search.html` — gradient + glass-card aesthetic, manufacturer-part-number input, displays only the selected tier as `Qty <N> → $<P> USD / unit` (no full tier table)
- Add `Product search →` link bottom-right on `web/index.html`
- Document the new page + backend smoke + defense-in-depth test cases in `web/TEST-PLAN.md` § 6
- Credentials live in `api/digikey/server/.env` (already covered by `.gitignore` Python template); `.env.example` shipped with empty placeholders
- The backend is intended for local development today; the frontend's `BACKEND_URL` is a single JS constant for a future migration to a hosted serverless function (no code rewrite needed)
- Fix DigiKey Postman collection URLs — `ProductPricing` and `ProductDetails` were shipped speculatively in #19 as `?PartNumber=…` query-param requests that return 404. Corrected (both `api/digikey/digikey.postman_collection.json` and `postman/collections/DigiKey API/ProductSearch/*.yaml`) to the verified path-param form `/products/v4/search/{{part_number}}/pricing` and `…/productdetails`

## 2026-05-10

### feat: add DigiKey API Postman collection (issue #19)

- Add `api/digikey/digikey.postman_collection.json` and `api/digikey/digikey.postman_environment.json` — OAuth2 (Client Credentials + Authorization Code) and ProductSearch endpoints (KeywordSearch, ProductPricing, ProductDetails, Manufacturers, Categories) against `api.digikey.com`
- Add `postman/collections/DigiKey API/` — Postman's YAML resource layout for the same collection (one `.request.yaml` per endpoint, `.resources/definition.yaml` per folder)
- Add `postman/environments/DigiKey API Environment.environment.yaml` — placeholder credentials, locale settings, token URL
- Ignore `.DS_Store` and `.postman/` (Postman's local workspace-link state) in root `.gitignore`
- Verified: JSON syntax via `python -m json.tool`; production OAuth2 token acquisition and ProductSearch KeywordSearch confirmed working from Postman

## 2026-04-30

### docs: require `[Rejected]` title prefix on rejected issues

- Add steps 5–6 to root `CLAUDE.md` § Tracking active work: when an issue is rejected, move status to **Rejected** *and* prefix the title with `[Rejected] ` so the rejection shows in `gh issue list`, cross-references, and the issues page (not just the board)
- Retroactively prefix the three existing Rejected issues (#12, #14, #15) via `gh issue edit --title`

### chore: add Rejected status column to project board (issues #16, #17)

- Add a new Status option **Rejected** (red) to the project board via GraphQL `updateProjectV2Field`, alongside the existing Backlog / Ready / In progress / In review / Done (#16)
- Final description scoped to cover both rejection cases (#17): "issue will not be implemented (declined outright, or implementation tried but not merged)" — covers issues declined for any/no reason without code, and the tried-then-rejected pattern from #12 where a branch is preserved for reference
- Document the new status in root `CLAUDE.md` Tracking active work table
- Existing options preserved by ID during the GraphQL update — no items lost their assignment

## 2026-04-26

### feat: design and add iOS app icon (issue #13)

- Generate three 1024×1024 PNG icons via PIL — light (gradient + concentric rings + center dot), dark (same — gradient is dark-friendly), tinted (white-rings-on-transparent for iOS to system-tint)
- Visual style: purple-indigo `#667eea → #764ba2` gradient (matches the hero), concentric "transmission" rings + center dot — evokes "first contact" / radio-ripple metaphor
- Place PNGs in `ios/FirstContact/FirstContact/Assets.xcassets/AppIcon.appiconset/` and update `Contents.json` to reference each by `filename` (per appearance variant)
- Apple HIG compliance: no text in the icon, abstract geometry, readable at home-screen scale
- Verified with `xcodebuild build` → `BUILD SUCCEEDED` and `xcrun simctl io … screenshot` of the simulator home screen showing the FirstContact app with the new icon

### docs: require simulator-screenshot read for UI-touching iOS changes

- Add a "Verifying UI changes" section to `ios/CLAUDE.md` between "Wireless deployment" and "Capabilities not available on free signing"
- Spell out why `xcodebuild` succeeding is insufficient for layout correctness (frame alignment, ZStack layering, off-screen content, missing data states)
- Provide a portable recipe: build → look up the `.app` path and a simulator UUID via `xcodebuild -showBuildSettings` and `xcrun simctl list devices` → boot, install, launch, screenshot to `/tmp/firstcontact-sim.png`
- Add a "Surfacing screenshots in issue comments" subsection: when posting a review-completion comment, prep the PNG on the macOS clipboard via `osascript`, post the comment with a placeholder, open the URL, and instruct the user to paste at the placeholder via ⋯ → Edit
- Note that `xcrun simctl io ... screenshot` captures the device-only framebuffer (no Mac desktop chrome) and that the simulator does not replace real-device testing
- Explicitly forbid committing screenshots or hosting via releases as a workaround for embedding images in comments

### feat: port "Changes made this week" panel to SwiftUI (issue #11)

- Add `Issue` `Codable` struct decoding `id`, `title`, `closed_at` (ISO-8601 → `Date`), and a marker for `pull_request`
- Add `loadIssues()` async fetcher that hits `api.github.com/repos/wongvin/firstcontact/issues?state=closed&per_page=30&sort=updated&direction=desc`, filters out PRs, keeps the last 7 days, sorts by `closed_at` desc
- Add `recentChangesPanel` view: top-right glass card (`.ultraThinMaterial` + 1pt white-25 border, max width 320pt, max height 200pt with internal `ScrollView`) showing a numbered list with the bold "CHANGES MADE THIS WEEK" header and a thin underline
- Loading / empty / error states: "Loading…" / "No changes this week." / "Could not load recent changes." (mirrors the web's three muted states)
- Two `.task` modifiers run `loadQuote()` and `loadIssues()` concurrently
- Layout fix during review: original `ZStack(alignment: .topTrailing)` anchored both children to top-right and the panel covered the hero; reverted to default-centered ZStack with `frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)` on only the panel
- Verified with `xcodebuild build` → `BUILD SUCCEEDED` plus an `xcrun simctl io ... screenshot` read on iPhone 17 sim

### docs: add status-transition and consent gates to repo workflow

- Expand "Tracking active work" in `CLAUDE.md`: add the full status table (Backlog → Ready → In progress → In review → Done), require moving to **In progress** when implementation begins, and **In review** when ready to commit
- Update "Commit hygiene" to require explicit user consent before any commit or push (every time, including doc-only commits)
- Document the `gh project item-edit` CLI invocation for status transitions alongside the Start date set

### feat: port quote-of-the-day fetch to SwiftUI (issue #10)

- Add a `Quote` `Codable` struct (`{id, quote, author}`) matching `https://dummyjson.com/quotes/random`
- Fetch on view appear via `.task` using `URLSession` + `async/await`; populate `@State` quote, set error flag on non-200 or thrown error
- Render the quote text in italic 16pt with smart double-quotes; author below at 14pt with 0.8 opacity; thin 1pt white-40 divider above (visual parity with the web `blockquote`'s `border-top`)
- Error state: muted 14pt "Could not load today's quote." (matches web fallback)
- Verified with `xcodebuild -scheme FirstContact -sdk iphonesimulator build` → `BUILD SUCCEEDED`

### feat: port homepage hero to SwiftUI (issue #9)

- Replace the default Xcode template `ContentView` with a SwiftUI port of the web hero
- Full-bleed `LinearGradient` matching `web/index.html` (#667eea → #764ba2, top-leading → bottom-trailing) via `.ignoresSafeArea()`
- "Hello, World!" headline at 48pt bold; below it the device line `You are on: iOS <version>` from `UIDevice.current.systemName + systemVersion` at 20pt with 0.9 opacity
- Verified with `xcodebuild -scheme FirstContact -sdk iphonesimulator build` → `BUILD SUCCEEDED`

### docs: require project Start date when work begins on an issue

- Add a "Tracking active work" subsection to root `CLAUDE.md` between Issue tracking and Commit hygiene
- Document the trigger (status moves out of Backlog to Ready/In progress, or coding begins) and the one-shot semantics (set once, do not update on revisions)
- Include both UI and `gh` CLI paths; note that writing custom fields requires the `project` scope on the gh token (not the default `read:project`)
- Backfilled Start dates on issues #1–#8 the same day this rule was adopted

### docs: document iOS signing and device deployment (issues #7, #8)

- Add `ios/CLAUDE.md` with sections for: free-Apple-ID signing chicken-and-egg, first install on iPhone via USB (Trust + Developer Mode + reboot), wireless deployment (Window → Devices and Simulators → Connect via network), and a list of capabilities unavailable on free signing
- Cross-references the failure narrative from issue #6 so the rationale isn't lost

### chore: add empty SwiftUI Xcode project for iOS target (issue #6)

- Create `ios/FirstContact/` Xcode project — App template, SwiftUI, Swift, deployment target iOS 26.0
- Bundle identifier `com.vwong.FirstContact`, Personal Team signing (free Apple ID)
- Add `ios/.gitignore` covering Xcode build artifacts and per-user state (`build/`, `DerivedData/`, `xcuserdata/`, `*.xcuserstate`, `.DS_Store`, `.swiftpm/`)
- Verified on iPhone SE (3rd gen, iOS 26.3.1): default template app builds, installs, and launches on device
- Captured the free-Apple-ID provisioning gotcha (no profile generated until at least one device is registered to the team) as comments on issue #6 for future reference

## 2026-04-25

### docs: require a tracking issue for every non-trivial change

- Add an "Issue tracking" subsection to root `CLAUDE.md` listing the workflow: file an issue (retroactively if needed) for any feature, repo restructure, infra change, user-visible bug fix, or multi-file refactor; skip for typos and trivial doc tweaks
- Cross-references issue #5 as the retroactive-filing example
- Adopted after the issue #5 retroactive demonstration so the project board stays a complete record of repo evolution

### chore: split repo into `web/` and `ios/` targets

- Move `index.html` and `TEST-PLAN.md` into a new `web/` folder
- Move web-specific Claude conventions (data source, API-text rendering) into `web/CLAUDE.md`; slim the root `CLAUDE.md` down to repo-wide rules (commit hygiene, issue closing) and a structure overview
- Add empty `ios/` folder with a placeholder README to host an upcoming SwiftUI app target (free-Apple-ID signing for personal use)
- Add `.github/workflows/pages.yml` that uploads the `web/` directory as the Pages artifact, replacing the legacy "build from `main:/`" Pages source — same URL (https://wongvin.github.io/firstcontact/), unchanged content
- Update root `README.md` to describe the new layout


### feat: replace static quote array with live API fetch (issue #4)

- Remove the curated `QUOTES` array and day-of-year rotation logic from index.html
- Fetch a random quote on each page load from `https://dummyjson.com/quotes/random`; populate the existing `quote-text` / `quote-author` spans via `textContent` (per CLAUDE.md defense-in-depth rule)
- Show "Could not load today's quote." on fetch failure or non-200 response
- Trade-off recorded on issue #4: thematic-tag filtering is not available on the chosen API's free tier, so the previous "reflect on my current work" curation is relaxed to "any random inspirational quote"

### docs: refresh TEST-PLAN.md §3 for dynamic quote feature

- Replace day-of-year math test with API-fetch verification (Network tab check, response shape, randomness across reloads)
- Add empty/error-path coverage (block dummyjson, throttle offline) — both expect graceful "Could not load today's quote."
- Section heading now references issues #2 and #4 to capture the feature's history

## 2026-04-24

### docs: add executable instructions to TEST-PLAN.md manual cases

- Add an Appendix of reusable Chrome DevTools procedures (open, breakpoints, request blocking, network throttling, response overrides, JS toggle, device toolbar, computed styles / accessibility, Lighthouse, real-iPhone pairing)
- Cross-reference the appendix from the manual test cases by letter
- Expand inline steps for the empty/error/defense-in-depth and quote-rotation cases with concrete line locations, console snippets, and a sample XSS payload
- Note HSTS-cache pitfall on the HTTP→HTTPS redirect test (use incognito)
- Update expected ordering in 4a.3 to match the current `closed_at` order at commit 119b0e5 (#3 → #2 → #1)

### docs: add manual test plan

- Add TEST-PLAN.md covering HTTPS/redirect, hero/device line, daily quote rotation, and recent-changes panel (happy/empty/error/defense paths)
- Document required environments (Chrome, Safari, Mobile Safari) and exit criteria
- Note for future features: append a new section per issue rather than rewriting existing ones (regression coverage)

## 2026-04-23

### docs: add CLAUDE.md with project conventions

- Document the "closed issues via public REST API" data source for homepage task lists, with rationale for skipping GraphQL and Actions-generated JSON
- Document the `createElement` + `textContent` rule for rendering any GitHub-API-sourced text, as defense-in-depth against HTML in titles
- Document commit hygiene: ChangeLog.md updates ship in the same commit as the code change
- Document issue-close workflow: always post an implementation-summary comment at close time (not a bare "shipped" line), with guidance on `--body-file -` heredoc for long markdown bodies

### feat: display recent changes on homepage

- Add a top-right fixed panel ("Changes made this week") capped at 25vh with internal scroll
- Fetch closed issues from the public GitHub REST API at page load, filter to those closed in the last 7 days, sort most-recent-first
- Render entries as a plain numbered list of one-line summaries (no links, no timestamps)
- Handle empty and error states with muted placeholder text
- Use safe DOM construction (`document.createElement` + `textContent`) to avoid any injection from API data

### feat: add daily rotating quote of the day to homepage

- Add a blockquote section below the device info with styled italic text and a thin top border
- Curate seven inspirational quotes themed around starting, shipping, simplicity, and security to reflect recent work on this project
- Rotate quotes client-side using day-of-year modulo, so the displayed quote changes each UTC day with no backend
- Render the quote and author on page load via the existing inline script

## 2026-04-22

### feat: add hello world landing page

- Introduce index.html with a responsive "Hello, World!" page
- Use a full-viewport gradient background and centered layout
- Display the visiting device's user-agent string via a small inline script
- Include viewport meta tag for proper mobile rendering on iPhone
