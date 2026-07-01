# Changelog

## 2026-06-29

### feat: fork-stars drill-down treemap (issue #176)

- `/ghstars` Forks view: while the **Forks** metric is active, re-activating a repo whose README panel is already open now closes the panel and drills into a **fork-stars treemap** — that repo's actual forks, fetched live from `GET /repos/{owner}/{repo}/forks?sort=stargazers&per_page=100` (top 100), sized/ordered by *their* stars. The fork-stars treemap reuses the existing canvas/interaction engine (hover, tap-to-README, tooltip, detail bar), so it behaves like the main and zoom-in views.
- `webapp/app/ghstars/ForksTreemap.tsx`: new client component — fetches the forks (mirroring `ReadmePanel.tsx`'s 403/404/error + loading handling), maps each to a `Repo`, builds one `GroupData`, and renders a `mode="detail"` `Treemap` with a back-chevron header (back + metric switcher + presentational search) replacing the standard tabs/breadcrumb header.
- `webapp/components/treemap/Treemap.tsx`: added `onDrillForks`/`onBack`/`backTitle` props; a new `activateRepo` helper routes a repo activation to the forks drill (when re-activating the locked tile under the Forks metric) or to `openReadme` otherwise, wired into desktop click, touch tap, and the hint's `onActivate`. Added the back-chevron header variant and the `"size"` ("Repo size") metric to `METRIC_OPTIONS`/`formatMetricValue`.
- `webapp/lib/treemap/types.ts` + `metrics.ts`: new `size` metric (`Repo.size`, KB) — present only on live-fetched forks, so it stays out of the main treemap's metrics; offered alongside Stars in the fork-stars switcher (default Stars).
- `webapp/app/ghstars/page.tsx`: `forksTarget` client state + `onDrillForks` wiring + a render branch for the fork-stars view.
- Search box in the fork-stars header ships controlled-but-inert (logic deferred to #175). Follow-ups filed: #174 (raw-CDN README fetch), #175 (fork-stars README-content search, depends on #174).
- `webapp/TEST-PLAN.md`: added § 28.

## 2026-06-28

### fix: README panel in-page anchor links now scroll (issue #172)

- `webapp/components/treemap/ReadmePanel.tsx`: a README's table-of-contents links (`#books` etc.) opened a new browser tab at the app URL with the hash appended (e.g. `/ghstars#books`) instead of scrolling to the heading — the `a` component applied `target="_blank"` to **every** link, and `react-markdown` didn't slug headings so there was no target anyway. Added `rehype-slug` (after `rehype-sanitize`, so heading ids stay clean and un-prefixed) to give headings GitHub-style ids, and special-cased `href="#…"` links in the `a` component to `preventDefault` and `scrollIntoView` the matching heading within the panel (scoped via a `data-readme-scroll` marker on the scroll container). External/relative links are unchanged (still open in a new tab).
- `webapp/package.json`: added `rehype-slug`.
- `webapp/TEST-PLAN.md`: added § 27.

### feat: render raw-HTML images in the treemap README panel (issue #170)

- `webapp/components/treemap/ReadmePanel.tsx`: README markdown is rendered by `react-markdown`, which silently drops all raw HTML — so images that READMEs embed as raw HTML (centred logos via `<p align="center"><img>`, `<picture>` blocks, badge rows) never appeared. Added `rehype-raw` (parses the raw HTML into nodes the `img` styling + `urlTransform` apply to) followed by `rehype-sanitize` with a schema that additionally allows `<picture>`/`<source>` and the `align` attribute on `img`/`p`/`div` (READMEs are untrusted, so raw HTML must be sanitised). Added a `<source>` component override that rewrites relative `srcSet` candidates to `raw.githubusercontent.com` (react-markdown's `urlTransform` only runs on `src`/`href`). Markdown-syntax images and the existing relative-URL rewriting are unchanged.
- `webapp/package.json`: added `rehype-raw` + `rehype-sanitize`.
- `webapp/TEST-PLAN.md`: added § 26.

### feat: README side panel on the treemap (issue #168)

- `webapp/components/treemap/ReadmePanel.tsx`: new component. Activating a `/ghstars` repo tile now opens the project's README in an in-app panel instead of opening github.com. The panel occupies one half of the screen (full height, scrollable body, top bar with the repo name + a close button; Esc also closes), fetches the README from the GitHub API (`/repos/{full_name}/readme`, `Accept: application/vnd.github.raw`), and renders it with `react-markdown` + `remark-gfm` (React elements, no `dangerouslySetInnerHTML`). README-relative image/link URLs are resolved against the repo; loading/missing/rate-limited states degrade gracefully.
- `webapp/components/treemap/Treemap.tsx`: the three "open on GitHub" actions (desktop click, touch second-tap, tap on the floating hint) now call `openReadme`. The panel opens on the half **opposite** the activated tile (`tileCenterX`), and the floating hint is re-anchored to the tile and slid horizontally out of the panel's half. While the panel is open the selection is **locked** (`lockedRef`): hover/mouse-leave no longer move the highlight or hint off the open repo's tile. Tiles stay selectable though — clicking (desktop) or tapping (touch) another tile replaces the panel with that tile's README and re-locks onto it; closing clears the lock and resets the highlight/hint. Re-selecting the already-open tile (or tapping its hint) is a no-op, so a dragged hint keeps its position instead of snapping back to the tile.
- `webapp/components/treemap/Tooltip.tsx`: `show` takes an `avoid` side and there's a new `nudgeIntoHalf` so the hint stays clear of the panel; `onActivate` now passes the hint's center x.
- `webapp/package.json`: added `react-markdown` + `remark-gfm`.
- `webapp/TEST-PLAN.md`: added § 25.

## 2026-06-27

### feat: treemap tile hints on touch devices (issue #166)

- `webapp/components/treemap/Treemap.tsx`: the `/ghstars` treemap is canvas-rendered and only surfaced hints via `onMouseMove`, so iPad/iOS (no pointer) never showed them usably. Added pointer-event handlers (gated on `pointerType`; the synthesized post-tap mouse events iOS fires are ignored so desktop hover/click is unchanged): a first tap reveals a tile's hint — bottom detail bar + an interactive floating hint near the tap — and highlights the tile. Opening the repo happens via a second tap on the same tile or a tap on the floating hint; the floating hint can be dragged to uncover the tiles it covers. Taps on headers/groups/"more" navigate as before; a tap on empty space dismisses. Taps are distinguished from drags by movement, and the canvas gets `touch-action: manipulation`.
- `webapp/components/treemap/Tooltip.tsx`: the floating hint takes an optional `interactive` mode (pointer-events enabled, "Drag to move" affordance) with its own tap/drag pointer handlers and an `onActivate` callback; hover mode stays click-through. The locked hint shown while a panel is open is interactive on **both** mouse and touch, so it's draggable with the mouse too.
- `webapp/TEST-PLAN.md`: added § 24.

## 2026-06-26

### feat: product image in Mouser search result (issue #164)

- `api/server/mouser_client.py`: `get_pricing` returns the matched part's inline `ImagePath` as `image_url` (Mouser includes the photo on the Part, so no extra request — unlike DigiKey's separate media call); `null` when absent.
- `webapp/public/mouser-search.html`: renders `image_url` on a white rounded chip above the price headline; silently omits it when absent or unloadable. Mirrors the DigiKey tool page (#162).
- `webapp/TEST-PLAN.md`: added § 23.

### feat: product image in DigiKey search result (issue #162)

- `api/server/digikey_client.py`: `get_pricing` now also calls DigiKey's ProductMedia endpoint (`/products/v4/search/{pn}/media`) best-effort in the same session and returns the product photo URL as `image_url` (the "Product Photos" `SmallPhoto`, 200×200; falls back to full-res `Url`/`Thumbnail`). A media failure returns `null` and never blocks pricing. Refactored the request headers into a shared `_api_headers` helper.
- `webapp/public/digikey-search.html`: renders `image_url` on a white rounded chip above the price headline; silently omits it when absent or if the image fails to load.
- `webapp/TEST-PLAN.md`: added § 22.

## 2026-06-22

### perf: skip WKWebView retry when reopening a Safari-only article (issue #160)

- `ios/FirstContact/FirstContact/ContentView.swift`: `loadFullText` now records (session-scoped `safariOnlyArticleURLs`) any article whose full-text fetch failed and fell back to the "Open full article in Safari" link. Reopening that same article skips the ~9s hidden-`WKWebView` retry — which can't clear an interactive Cloudflare challenge anyway — and lands straight on the Safari link. First-time behavior (URLSession → WKWebView → Safari) is unchanged; the fast URLSession path still runs on reopen, so a recovered site still loads inline.

### feat: cream/dark color scheme for the news views (issue #158)

- `ios/FirstContact/FirstContact/ContentView.swift`: the news views — article cards, the full-article detail screen, the related-news feed, and news loading/empty/failed states — now render on a warm cream background (`#F0EDE6`) with dark text (`#292826`) for a clean reading-app look, replacing the indigo/purple gradient + white text on those screens. The selectable body switches to dark text with a dark-gray selection tint; the image placeholder and "Open in Safari" affordance adapt to the light theme. The home screen (quote, 30-day summary, issues) keeps the gradient. Added `newsBackground`/`newsText` palette constants.

### feat: selectable full-text article body (issue #156)

- `ios/FirstContact/FirstContact/ContentView.swift`: the loaded full-text body is now rendered by a read-only, selectable `UITextView` (`SelectableText`, a `UIViewRepresentable`) instead of `Text`, giving native cursor-based selection — draggable selection handles, a bright-cyan selection highlight + cursor tint (legible over the indigo/purple gradient, where the default system tint is muddy), and the magnifier loupe — for selecting/copying article text. Non-scrolling so it still sizes to content inside the detail ScrollView. The detail screen's swipe-to-dismiss gesture is suspended (via `GestureMask` keyed off a selection-active flag the text view reports) while the selection handles are in use, so dragging a cursor horizontally is no longer misread as a dismiss swipe.

### feat: WebKit fallback + "Open in Safari" for blocked article fetches (issue #154)

- `ios/FirstContact/FirstContact/ContentView.swift`: the full-text scraper now has a three-tier fetch. (1) `URLSession` GET (fast path, unchanged for most publishers). (2) On failure/non-200, a hidden `WKWebView` (`WebPageFetcher`) retries with a real Safari fingerprint — recovering sites that 403 `URLSession` on its client fingerprint but aren't behind an interactive challenge. (3) When both fail — e.g. phys.org's Cloudflare "checking your connection" challenge, which a hidden web view can't clear (verified on simulator + device) — the detail screen's `.failed` state now shows an **"Open full article in Safari"** link alongside the truncated `content`, so the article is still reachable in a browser that passes the challenge natively. `WebPageFetcher` detects challenge interstitials and bails fast rather than blocking.

## 2026-06-21

### fix: full-text scraper misses body on multi-`<article>` pages (issue #152)

- `ios/FirstContact/FirstContact/ContentView.swift`: `extractReadableText` no longer blindly scopes to the first `<article>` region. It now compares the richest `<article>` region against the whole stripped document and only scopes to the article when it holds ≥ half the page's readable text — otherwise harvests from the whole doc. Fixes Business Insider (and similar) pages that scatter many small `<article>` promo cards with the real body outside all of them; the detail screen previously fell back to GNews's truncated `content`. No regression on single-`<article>` or no-`<article>` pages.

## 2026-06-17

### docs: document local-dev setup gotchas (issue #144)

- `webapp/README.md`: added a Node.js ≥ 20.9 prerequisite note and a Troubleshooting section for the WSL failure (old system Node + npm-9 optional-deps bug → Next refusing to start / Tailwind "Cannot find native binding"), with the nvm-based fix.
- `webapp/README.md`: documented the `/ghstars` treemap dataset with a verified `curl` command to fetch `repos.json` into `public/treemap-data/`.
- `api/server/README.md`: noted that an existing `.venv` must be re-synced (`pip install -r requirements.txt`) when `requirements.txt` changes, since a missing dep surfaces as a runtime `ModuleNotFoundError`, not a startup error.

### feat: bottom repo-detail panel on /ghstars (issue #145)

- `webapp/components/treemap/Treemap.tsx`: added a persistent, hover-driven detail bar (`RepoDetailBar`) pinned to the bottom of the `/ghstars` page. It mirrors the hover tooltip's fields — name, owner, description, plus language (color dot + name), ★ stars, ⑂ forks, Growth, Created and Updated dates. The stats sit in fixed-width slots on the first line so they hold the same x-position as you move between repos; the description wraps below (clamped to 2 lines). Sourced from new `detailRepo` state set inside `showRepoTooltip` (so it reuses the language label/color and the lazily-fetched created/updated meta, backfilling once the meta index resolves). Persists the last repo after the cursor leaves the canvas; placeholder before any hover; fixed height keeps the canvas layout stable. Clicking a cell still opens GitHub.
- `webapp/components/treemap/Tooltip.tsx`: slimmed the floating hover tooltip to just the repo **name + description** now that the bottom bar carries the rest — dropped owner, language, stars, forks, growth, and created/updated from it. `TooltipHandle.show` simplified to `(x, y, repo)`; removed the now-dead `ActiveTooltip`/`activeTooltipRef` and the meta-driven tooltip re-render in `Treemap.tsx` (the bar's date backfill stays).
- `webapp/TEST-PLAN.md`: added § 21 covering the detail bar.

## 2026-06-16

### feat: color /ghstars star-range tiers with a Viridis ramp (issue #141)

- `webapp/lib/treemap/colors.ts`: added `viridis(t)` (6-stop perceptually-uniform ramp, dark purple → bright yellow) and `tierColor(rank, count)`, which maps a tier's star rank to the ramp (highest-star tier → bright end).
- `webapp/components/treemap/Treemap.tsx`: the detail-view star-range tiers now color by rank via `tierColor(...)` instead of reusing the single GitHub-linguist `detailGroup.color`. The tier layout loop is indexed (`squarify` preserves star-descending order). A webapp-side override only — `repos.json` / dataset generation untouched, and language-overview blocks keep their linguist colors.
- `webapp/TEST-PLAN.md`: added § 20e covering tier coloring.

## 2026-06-15

### feat: embed GitHub treemap as /ghstars route in webapp (issue #139)

- Ported the third-party **`xiaoxiunique/1k-github-stars`** treemap app into `webapp/` as a new client-rendered route at `/ghstars`, with prominent credit to the original author (header byline linking to the source repo).
- `webapp/lib/treemap/*` + `webapp/components/treemap/*`: copied the source, namespaced under `treemap/`. `lib/treemap/data.ts` refactored from a build-time `import "@/data/repos.json"` into pure functions taking the fetched `RepoData`. `Treemap.tsx` drops `next/navigation` routing — language/tier drill and the Projects/Daily/Awesome tabs are now client state via new callbacks; `Header.tsx` tabs became buttons. Hover metadata fetch repointed to `github-treemap.pages.dev`.
- `webapp/app/ghstars/{layout,page}.tsx`: client page fetches `/treemap-data/repos.json` on mount and degrades to a "dataset unavailable" empty state when absent (Vercel). Dark theme scoped via Tailwind on the page wrapper — `app/globals.css` untouched.
- `webapp/app/page.tsx`: added a "GitHub Treemap →" homepage tool link.
- `webapp/.gitignore`: ignore `public/treemap-data/` (the ~9.4 MB dataset is fetched at runtime, never committed). Known limitation: real data shows only in local `npm run dev`.
- Docs: `webapp/CLAUDE.md` + `webapp/TEST-PLAN.md` (§ 20).

## 2026-06-14

### chore: bump Next.js 16.2.7 → 16.2.9 (issue #135)

- `webapp/package.json`: bumped `next` and `eslint-config-next` from `16.2.7` to `16.2.9` (latest on the Next 16 patch line); refreshed `webapp/package-lock.json`.
- Verified with a clean `npm run build` on Next 16.2.9.

### fix: keep "Changes made this week" panel populated when GitHub fetch fails (issue #136)

- `webapp/app/page.tsx`: the homepage "Changes made this week" panel now caches its last successful list in `localStorage` (`firstcontact:recent-changes:v1`) and renders it cache-first. The unauthenticated, browser-side GitHub fetch can fail on the anonymous 60/hr rate limit (403) or a transient 5xx/offline blip; previously that blanked the panel to "Could not load recent changes." Now the fetch falls back to the cached list, and the error only shows when there is no cache. New `readRecentCache`/`writeRecentCache` helpers mirror the 30-day-summary cache; the cache is written only on a non-empty success.
- `webapp/TEST-PLAN.md`: added § 19 covering cache-first render, failure fallback, corrupted-cache tolerance, and code-shape guards.

### feat: cache key-term panel's Gemini result per article (issue #133)

- `ios/FirstContact/FirstContact/ContentView.swift`: the long-press key-term panel (`loadKeyword`) now caches its Gemini-extracted term per `article.url` in a new `keywordTermCache` session dictionary, mirroring the drill-down's `spawnCache`. Reopening the panel for the same headline reuses the cached term (instant pre-fill, no spinner) instead of re-running Gemini; the term is stored on first successful extraction. Session-memory only — no persistence across launches.

### feat: include article content in news search (issue #131)

- `ios/FirstContact/FirstContact/ContentView.swift`: GNews keyword search now matches article content, not just title/description. Both the home category feed (`fetchNews`, `top-headlines`) and the related-news drill-down (`searchNews`, `/search`) send `in=title,description,content`. Added `max=10` to the `top-headlines` request (the free-tier ceiling) to match the search request.
- The Gemini key-term extraction now feeds article content alongside headline + description: both `fetchSpawnState` (cross-swipe drill-down) and `loadKeyword` (long-press keyword panel) append a `Content:` line, and `keywordSystemPrompt` was updated to reference headline, description, and content.

### feat: cross-swipe a headline to drill into related news (issue #131)

- `ios/FirstContact/FirstContact/ContentView.swift`: a cross-axis swipe on a news headline now spawns a feed of related news — GNews `search` results for that article's Gemini key term — with a top-left back chevron to return. New `NewsFeed` model + `spawnedFeed`/`spawnCache` state, `searchNews(query:key:)` (the `/search` endpoint via `URLComponents`), `spawn(from:)` + `fetchSpawnState(for:)` (reusing `generateKeyword`), `spawnedFeedPager`, and a `currentArticle` helper. The base `swipeGesture` cross-axis branch calls `spawn`.
- The spawned feed is articles-only and inherits swipe navigation, tap→detail, and long-press→keyword panel; cross-swipe inside it is a no-op (one level only). Feeds are cached in session memory by `article.url`, so re-cross-swiping the same headline reuses the result (no repeat Gemini/GNews call). Factored `newsStatusScreen` into a shared `statusScreen(for:)`.

### docs: document iOS device-deploy verification convention (issue #119)

- `ios/CLAUDE.md`: expanded the brief script mention into a "Deploying to a physical device" subsection under "Verifying UI changes" — documents deploying debug builds to the connected iPhone for real-hardware testing (the simulator can't drive gestures), the one-command `scripts/deploy-device.sh`, the equivalent manual `xcodebuild -sdk iphoneos` build + `devicectl install`/`launch` steps with generic auto-detection (no hardcoded UDID), and the gotchas (check device connected, ~7-day free-signing expiry, benign `Code=1002` noise, locked-device `Code=10002` launch refusal).

### feat: one-command device-deploy helper script (issue #118)

- `ios/FirstContact/scripts/deploy-device.sh`: new helper that builds the app for the connected iPhone (Debug, `-sdk iphoneos`, generic destination) and installs + launches it via `devicectl` in one command. Auto-detects the connected device's identifier from `xcrun devicectl list devices` (no hardcoded name/UDID) and fails with a clear message if none is connected; resolves the built `.app` and bundle id from `xcodebuild -showBuildSettings`; launch failure (e.g. locked device) warns rather than erroring since the install already succeeded.
- `ios/CLAUDE.md`: mentioned the script under "Verifying UI changes".

## 2026-06-13

### feat: GNews q expression from keyword bubbles (issue #127)

- `ios/FirstContact/FirstContact/ContentView.swift`: the saved keywords now drive the news feed. New `keywordQuery()` builds a GNews boolean expression — each term double-quoted; blue (included) terms are `OR`-ed inside one parenthesized group, then `AND`-ed with each `NOT`-prefixed red (excluded) term (e.g. `("Quantum computing" OR "Superconductors") AND NOT "Bitcoin"`); empty string when there are no keywords. `loadNews` passes it as `q` to all three category `fetchNews` calls; `fetchNews(category:key:query:)` now builds the URL with `URLComponents`/`URLQueryItem` (correct percent-encoding) and always includes the `q` item (value may be empty → unfiltered, same as before). Applied on next news load (launch); `top-headlines` endpoint + category grouping unchanged.
- Added a 200-character warning: `warnIfQueryTooLong()` (called from `sendKeyword()` and from `toggleExcluded(_:)` when a keyword is newly excluded) shows an alert when the built expression exceeds GNews's 200-char `q` limit. The keyword is still added/excluded — the alert is informational.
- The keyword panel can now be opened from the news **status screen** (e.g. "No news right now." when the filter is too narrow) via long-press — the escape hatch to fix an over-restrictive filter. Decoupled the panel's presentation from `keywordArticle` into a `showKeywordPanel` flag; `keywordPanel()` no longer requires an article (no article → no term pre-fill, no spinner). Long-pressing an article still opens it pre-filled with that article's term.

### feat: exclude/include a keyword (red bubble) from long-press menu (issue #125)

- `ios/FirstContact/FirstContact/ContentView.swift`: added an **Exclude**/**Include** toggle above **Delete** in a keyword bubble's long-press context menu. A normal (blue) bubble shows "Exclude" (turns it red); a red bubble shows "Include" (turns it back blue). Backed by the keyword's new `excluded` flag (`keyword.excluded ? Color.red : Color.blue`) and a `toggleExcluded(_:)` helper that flips the flag and persists via `saveKeywords()`. `Keyword` gained a `var excluded: Bool = false` with a custom `init(from:)` (`decodeIfPresent`) so keywords saved before the field existed still load.
- Bubbles render via a `sortedKeywords` computed view that lists non-excluded (blue) first and excluded (red) last (stable within each group), so a newly added keyword slots in among the blues and toggling exclude/include moves a bubble between the groups. Storage order is unchanged.

### feat: compose-style key-term panel with its own keyword list (issue #123)

- `ios/FirstContact/FirstContact/ContentView.swift`: turned the key-term half-sheet into a compose UI — a scrollable thread of saved keyword bubbles above an input box pre-filled with the Gemini term, with long-press-to-delete per bubble. New `Keyword` model, `keywords`/`keywordDraft`/`keywordFieldFocused` state, `firstcontact.keywords.v1` cache key, and `sendKeyword`/`deleteKeyword`/`loadKeywords`/`saveKeywords` helpers (mirroring the compose-message ones). `loadKeyword` now sets `keywordDraft` to the term on success.
- The keyword list is its own persisted store, separate from the home compose messages; the panel placeholder reads "Keyword". Replaced the Close bar with the input bar (dismiss still via drag or tapping the dimmed peek) and shrank `keywordContent` to a compact loading/error status line. Half-sheet shell, `ComposeMessage`, and the home compose screen are unchanged.
- The keyword thread is a static (non-scrolling) stack — no `ScrollView` — so the panel-wide drag-to-dismiss has nothing to conflict with. (Trade-off: a long thread can overflow the half-panel.)
- Keyword bubbles now lay out as wrapping chips via a new `FlowLayout` (`Layout` protocol): left-to-right, wrapping top-to-bottom from the top-left corner, instead of one right-aligned bubble per row.

### feat: half-size key-term sheet over the article (issue #121)

- `ios/FirstContact/FirstContact/ContentView.swift`: reworked the Gemini key-term screen from a full-screen overlay into a half-size sheet that peeks over the (dimmed) article. Portrait occupies the bottom half and slides up from the bottom; landscape occupies the right half and slides in from the right (`.containerRelativeFrame`, `UnevenRoundedRectangle` rounding only the inner corners). The pager renders behind as a frozen peek (`.allowsHitTesting` off) with a `Color.black.opacity(0.35)` scrim.
- Three dismiss paths: drag the sheet down/right past a threshold (`keywordDismissDrag` + `keywordDragOffset` offset, grabber-handle affordance), tap the dimmed area outside the sheet, or a **Close** bar pinned to the panel bottom. Removed the back chevron. `loadKeyword`/`keywordContent` unchanged.

### feat: delete saved compose messages via long-press (issue #117)

- `ios/FirstContact/FirstContact/ContentView.swift`: long-pressing a message bubble in the compose screen now shows a native context menu with a destructive **Delete** action. Added a `.contextMenu` on the bubble and a `delete(_:)` helper that removes the message by `id` and re-persists via the existing `saveComposeMessages()`. Per-message only — no clear-all, no confirmation dialog, no layout change.

### feat: rework long-press gestures (issue #115)

- `ios/FirstContact/FirstContact/ContentView.swift`: the long-press that opens the compose screen now fires only on the welcome (home) screen — moved the `.simultaneousGesture(LongPressGesture)` off the pager/overlay group and onto `homeScreen` (with `.contentShape(Rectangle())` so the whole area is pressable).
- The Gemini key-term screen now opens on a **long-press of an article** instead of a cross-axis swipe: added a `.simultaneousGesture(LongPressGesture)` to `articleScreen` that sets `keywordArticle`, dropped the cross-axis branch (and the now-unused `currentArticle` helper) from `swipeGesture`. Pager navigation swipes and tap-to-open-detail are unchanged.

## 2026-06-11

### feat: long-press opens iMessage-style compose screen (issue #113)

- `ios/FirstContact/FirstContact/ContentView.swift`: a long-press (0.5s) on any non-compose screen now opens a new `composeScreen` resembling the iOS Messages app — a scrollable thread of right-aligned blue bubbles above a bottom input bar, dismissed via a top-left back chevron. Tapping the field raises the keyboard; an `arrow.up.circle.fill` send button appears only when the field holds non-whitespace text; sending appends the text as a bubble and clears the field. New `ComposeMessage` model, `showCompose`/`messages`/`draft` state, and a `composeFieldFocused` focus binding.
- Messages persist across launches via `UserDefaults` (`firstcontact.compose.v1`), mirroring the 30-day summary cache (`loadComposeMessages`/`saveComposeMessages`). The long-press is attached as a `.simultaneousGesture(LongPressGesture)` on the pager/overlay group only, so it coexists with the pager drag and panel taps while leaving the compose field's native text-selection long-press intact.

## 2026-06-10

### feat: cross-axis swipe shows Gemini key term for article (issue #111)

- `ios/FirstContact/FirstContact/ContentView.swift`: a swipe on the axis opposite to navigation (horizontal in portrait, vertical in landscape) on an article now opens a new `keywordScreen` showing a Gemini-extracted key word/term for that article, centered, with a top-left exit arrow. New `KeywordState` (`loading`/`loaded`/`failed`/`missingKey`), `keywordArticle`/`keywordState` state, and a `currentArticle` helper.
- Refactored `swipeGesture` to route by axis: a swipe whose dominant axis matches the nav axis (`horizontal == isLandscape`) navigates as before; the cross-axis swipe (>50pt) opens the key-term screen for the current article (no-op on home/status). `loadKeyword`/`generateKeyword` call Gemini (`gemini-2.5-flash-lite`, temp 0.2) with a dedicated `keywordSystemPrompt` using only the headline + description; the back chevron mirrors the detail screen's dismiss.
- Verified: `xcodebuild` (simulator) succeeds; the keyword prompt was validated against the Gemini API (e.g. "background apps", "Whale graveyard", "Knicks vs. Spurs"); an iPhone SE (3rd gen) screenshot shows the real Gemini term ("background apps") centered with the exit arrow. The cross-axis gesture itself was verified by code review (gestures aren't capturable in a still).

### feat: swipe to dismiss full-text detail screen (issue #109)

- `ios/FirstContact/FirstContact/ContentView.swift`: added a horizontal swipe (left or right) on `articleDetailScreen` that dismisses back to the pager — same as the back chevron (`withAnimation { detailArticle = nil }`). Implemented as a `.simultaneousGesture(DragGesture(minimumDistance: 20))` that only acts on horizontal-dominant swipes (`abs(width) > abs(height)` and `> 50pt`), so the body's vertical scrolling is unaffected.
- Verified: `xcodebuild` (simulator) succeeds; iPhone SE (3rd gen) screenshot confirms the detail screen still renders/scrolls (the swipe-dismiss gesture verified by code review — not capturable in a still).

### feat: remove swipe-pager transition animation (issue #107)

- `ios/FirstContact/FirstContact/ContentView.swift`: removed the slide animation on the swipe pager so the article screen's image/title/description no longer animate when paging — content swaps instantly (no slide or fade). Dropped the `.transition(.asymmetric(.move…))` on `currentScreen` and the `withAnimation(.easeInOut)` wrapper around the `screenIndex` change in `swipeGesture`, and removed the now-dead `goingForward` state. Applies to the whole pager (home screens swap instantly too). Swipe navigation (next/prev, wrap-around, portrait + landscape axes) is unchanged; the tap-to-open detail-screen slide is unaffected.
- Verified: `xcodebuild` (simulator) succeeds; iPhone SE (3rd gen) screenshot confirms the article screen still renders correctly (animation absence verified by code review — not capturable in a still).

### feat: landscape layout + swipe mapping for iOS article pager (issue #105)

- `ios/FirstContact/FirstContact/ContentView.swift`: added landscape-specific behavior to the swipe-pager article screen. New `@Environment(\.verticalSizeClass)` + `isLandscape` (compact height = landscape on iPhone). In landscape, `articleScreen` lays the image on the left half (`geo.size.width * 0.5`, full height) with the headline/description on the right half; portrait keeps the image across the top 35% with text below. Extracted the shared headline+description into an `articleText(_:)` helper.
- Remapped pager navigation by orientation: landscape swipes on the horizontal axis (swipe-left = forward, mirroring portrait's swipe-up; swipe-right = back), portrait stays vertical. The page-transition slide also follows the axis (horizontal move in landscape) so a horizontal swipe doesn't animate vertically. The gesture is shared by the whole pager, so home screens navigate the same way in landscape.
- Verified: `xcodebuild` (simulator) succeeds; confirmed the landscape layout on an iPhone SE (3rd gen) simulator (temporarily forced landscape-only to launch rotated) — image fills the left half, headline + description fill the right half.

### feat: shrink iOS article screen image to top 35% (issue #103)

- `ios/FirstContact/FirstContact/ContentView.swift`: on the swipe-pager `articleScreen`, changed the headline image height from `geo.size.height / 2` (top 50%) to `geo.size.height * 0.35` (top 35%), giving the headline + description more room above the fold. Detail-screen image (fixed 200pt) unchanged.
- Verified: `xcodebuild` (simulator) succeeds; iPhone SE (3rd gen) simulator screenshot confirms the image occupies the top ~35% with the headline/description filling the space below.

### fix: pin iOS article detail column width (issue #101)

- `ios/FirstContact/FirstContact/ContentView.swift`: fixed the article detail screen clipping its left margin and bleeding the image full-width on narrow devices (iPhone SE) for certain articles. Cause: a long unbreakable token in the extracted body (e.g. a bare URL) that the device's iOS won't wrap widened the leading-aligned content column past the screen, dragging the `.frame(maxWidth: .infinity)` image full-bleed with it. Wrapped the detail `ScrollView` in a `GeometryReader` and pinned the content column with `.frame(width: geo.size.width, alignment: .leading)` (padding applied inside the pin) so no body content can exceed the screen width; long tokens now wrap within the column. Added `.fixedSize(horizontal: false, vertical: true)` to the title and body text as belt-and-suspenders against horizontal expansion.
- Also fixed the detail image bleeding into the right margin: a `scaledToFill` image with `.frame(maxWidth: .infinity)` applied directly to it overflowed its column on the trailing edge. Re-anchored the image on a `Color.clear` box (`.frame(maxWidth: .infinity).frame(height: 200)`) with the image as a clipped `.overlay`, so the box defines the exact column width and the image can't exceed it — the image now keeps equal 20pt margins on both sides.
- Verified: `xcodebuild` (simulator) succeeds; reproduced and confirmed the fix on an iPhone SE (3rd gen) simulator with a synthetic long-token body — title, inset rounded image, and wrapped body all keep their 20pt side margins. (iOS 26.4 auto-breaks long tokens so the original overflow only shows on the older device OS; the width pin makes overflow impossible regardless of OS wrapping behavior.)

## 2026-06-09

### feat: drop redundant description from iOS article detail (issue #98 follow-up)

- `ios/FirstContact/FirstContact/ContentView.swift`: removed the standalone `description` block from `articleDetailScreen` — the full body scraped from the linked URL already contains it, so showing the GNews `description` above it was redundant. The detail screen now flows title → image → full body. Simplified `truncatedContent`'s fallback to always show the "No further text available" message when there's no `content` (the previous `article.description == nil` guard only mattered while the description was rendered).
- Verified: `xcodebuild` (simulator) succeeds; simulator screenshot of the detail screen confirms the description is gone and title + image + full body render correctly (verified via a temporary launch-env hook, removed before commit).

### feat: iOS full-text article detail from linked URL (issue #98)

- `ios/FirstContact/FirstContact/ContentView.swift`: the article detail screen (from #96) now fetches the **entire article body from the article's linked URL** instead of only GNews's ~160-char truncated `content`. New `ArticleTextState` (`loading`/`loaded`/`failed`) and `@State articleTextState`; a `.task(id: article.url)` on `articleDetailScreen` runs `loadFullText`, which fetches the page with a Safari-like `User-Agent` (15s timeout) and feeds the HTML to a pure-Swift readability heuristic.
- `extractReadableText(from:)` strips non-content blocks (`script`/`style`/`head`/`nav`/`header`/`footer`/`aside`/`form`/`figure`/…), prefers the first `<article>…</article>` region, collects `<p>/<h1-3>/<li>` text, decodes HTML entities (named + numeric `&#NN;`/`&#xNN;`), drops sub-40-char scraps and any fragment still carrying markup signatures (`href=`/`src=`/`</`/`/>`), and joins surviving paragraphs. All regex via `NSRegularExpression` (case-insensitive, dot-matches-newlines).
- Detail body now switches on `articleTextState`: shows the truncated `content` immediately while loading (plus a "Loading full article…" spinner), swaps to the full extracted text on success, and falls back to the truncated `content` (else the existing "no further text" message) on failure. Title/image/description unchanged.
- Verified: `xcodebuild` (simulator) succeeds; the extraction was validated standalone against real article pages (clean multi-paragraph body; non-200 → graceful fallback); a simulator screenshot of the detail screen confirms title + image + description + full scrollable body render correctly (verified via a temporary launch-env hook, since there's no reliable CLI swipe injection — hook removed before commit).

## 2026-06-07

### feat: iOS swipe-driven news reader (issue #96)

- `ios/FirstContact/FirstContact/ContentView.swift`: added a gnews.io-backed news experience navigated by vertical swipes. New `Article`/`NewsResponse` models and `NewsState`; `loadNews()` fetches `general`/`technology`/`science` concurrently (`async let`) and concatenates them in that order (partial failures degrade; all-fail/empty → status screen). Refactored `body` into a circular swipe pager (`screenIndex` over `[home] + articles`, `(i±1) % total` so the last article wraps to home and home swipes to the last article). New `articleScreen` (image fills the top half via `GeometryReader`, headline + description below; tap anywhere opens detail), `articleDetailScreen` (scrollable title + image + description + gnews `content`, top-left `chevron.left` back button), and `newsStatusScreen` (loading/missing-key/failed/empty). One root `DragGesture` distinguishes vertical swipes (>50pt) from taps; the home panels' tap-to-cycle Buttons still work.
- `ios/FirstContact/scripts/generate-secrets.sh` + `Secrets.example.xcconfig`: extended the secrets pipeline to also embed `GNEWS_API_KEY` as `GeneratedSecrets.gnewsAPIKey` (same pattern as `GEMINI_API_KEY`; no `project.pbxproj` change). Empty key → news screen shows a setup hint.
- Verified: `xcodebuild` (simulator) succeeds; simulator screenshots confirm the home screen is unchanged and an article screen renders image-top-half + headline + description with a real gnews article. Swipe transitions/wrap and the tap→detail→back flow need a manual device/simulator check (no reliable CLI swipe injection).

### feat: TTS button pause/resume + hold-to-restart (issue #94)

- `webapp/app/news/TTSButton.tsx`: rewrote the single-action "Read Aloud" button into a play/pause/resume control with a hold-to-restart gesture. State machine: **idle** (`🔊 Read Aloud`, click → speak from start) → **playing** (`⏸️ Pause`, click → `speechSynthesis.pause()`) → **paused** (`🔊 Read Aloud`, click → `speechSynthesis.resume()`). A long-press (~500ms `HOLD_MS`) from any state restarts from the beginning (`cancel` + `speak`); the click that follows a hold is suppressed via `heldRef`.
- Uses pointer events (`onPointerDown`/`Up`/`Leave`) for the hold timer; `userSelect: none` + `touchAction: manipulation` + `onContextMenu` preventDefault to keep long-press clean on touch. Detaches utterance handlers on restart/unmount so a `cancel()` can't `setState` on a stale/unmounted instance; starting one button cancels any other so only one reads at a time.
- Verified: `npm run lint` + `npm run build` clean; `/news` renders 10 buttons at initial `Read Aloud` state. Click/hold/audio transitions require manual browser verification (SpeechSynthesis is unavailable headless).

### feat: Read Aloud buttons on the Latest News page (issue #92)

- `webapp/app/news/page.tsx`: imported `TTSButton` and rendered `<TTSButton text={`${article.title}. ${article.description}`} />` after each article's "Read more" link, matching the `/news/technology` and `/news/science` pages. The general `/news` feed previously had no TTS button.
- Verified: `npm run lint` + `npm run build` clean; `/news` renders one Read Aloud button per article (10/10 with a live `GNEWS_API_KEY`).

### feat: switch news topics to Technology and Science (issue #90)

- Renamed the two category routes: `webapp/app/news/economy/` → `technology/` and `webapp/app/news/health/` → `science/` (via `git mv`).
- `app/news/technology/page.tsx`: fetches gnews `category=technology`, heading "Technology News", helper `getTechnologyNews`, empty-state "No technology articles found." (was `category=business` / Economy).
- `app/news/science/page.tsx`: fetches gnews `category=science`, heading "Science News", helper `getScienceNews`, empty-state "No science articles found." (was `category=health` / Health).
- `app/news/page.tsx`: category nav now links `/news/technology` and `/news/science` with matching labels.
- `webapp/CLAUDE.md`: route list updated to the new paths.
- Verified: `npm run lint` + `npm run build` clean; `/news/technology` and `/news/science` return 200 with correct headings, old routes 404, `/news` nav points to the new routes.

### feat: migrate web to a Vercel-hosted Next.js app (`webapp/`, issue #88)

- New top-level `webapp/` target: the `news-voice` Next.js 16 / React 19 / Tailwind 4 app copied in (source only, fresh history). Renamed package to `firstcontact-webapp`; set real `metadata` title/description; cleaned the merge-conflicted README; typed the news pages' article param (`app/news/types.ts`) so the target lints clean.
- `webapp/app/page.tsx`: the former static `web/index.html` homepage ported 1:1 into a `"use client"` component — hero + dummyjson quote, 30-day-summary panel (`localhost:8001` + 24h `localStorage` cache + unreachable fallback), changes-this-week panel (GitHub closed-issues REST, PRs filtered), tap-to-cycle (`VIEW_COUNT=3`) and panel height-lock, plus a new "Latest News →" link to `/news`. Styles in `app/page.module.css` (scoped so `/news` keeps its look).
- Tool pages (`digikey-search.html`, `mouser-search.html`, `transcripts-viewer.html`) served verbatim from `webapp/public/`.
- `api/server/main.py`: CORS now allows `http://localhost:3000` and `https://*.vercel.app` (`allow_origin_regex`); docstring frontend paths updated `web/*` → `webapp/...`.
- Retired GitHub Pages: deleted `.github/workflows/pages.yml` and the old `web/` directory; moved `web/TEST-PLAN.md` → `webapp/TEST-PLAN.md`.
- Docs: root `CLAUDE.md` targets list (`web/` → `webapp/`, Vercel), new `webapp/CLAUDE.md`, `api/server/README.md` frontend + CORS sections.
- News headlines still fetched server-side directly from `gnews.io` (`GNEWS_API_KEY`) — not through the local backend. Tagged `pre-vercel-migration` on `main` as a rollback point before the change.

### fix: tool-page Home links target the Next.js root (issue #88)

- `webapp/public/{digikey-search,mouser-search,transcripts-viewer}.html`: the `← Home` link pointed at `index.html` (correct under the old GitHub Pages flat site, broken under the Next.js app where the homepage is the root route). Changed `href="index.html"` → `href="/"`. Deployed to Vercel production and verified all three resolve to `/`.

## 2026-06-06

### feat: collapse multi-line user prompts to first line on the prompt-line (issue #85)

- `web/transcripts-viewer.html`: inside `render(index)`, `userText` is now `(p.user_text || '').split('\n', 1)[0].replace(/\s+$/, '')`. Slash-command entries (e.g. `/ship` followed by trailing context lines) and any other multi-line prompts render only their first line on the prompt-line. The underlying `prompts[i].user_text` is unchanged, so cursor/search logic continue to use the full text (and search-scope is `response_text` anyway, per § 10). Both the `Claude: <question> User: …` branch and the bare `User: …` branch consume the same collapsed `userText`.
- `web/TEST-PLAN.md`: new § 18 with rendering, data-preservation, and code-shape regression guards.

### feat: symmetric iOS home panel layout (issue #83)

- `ios/FirstContact/FirstContact/ContentView.swift`: two small visual-symmetry adjustments to the home screen after #81 landed. (1) `recentChangesPanel`'s positioning frame in `body` changed from `alignment: .topTrailing` to `alignment: .top` — `.top` is `Alignment(horizontal: .center, vertical: .top)`, which horizontally centers the panel at the top of the screen instead of pinning it to the top-right corner. (2) `summary30dPanel`'s `.padding(12)` moved from *after* `.frame(maxWidth: 320, minHeight: 120, alignment: .topLeading)` to *before* the frame. Previously the padding added 12pt outside the framed view → total visual width 344pt; now the padded VStack is what gets sized by the frame → total visual width 320pt, matching `recentChangesPanel`. Both panels now mirror each other above and below the centered hero with identical widths.
- The `minHeight: 120` floor on `summary30dPanel` still applies to the framed-and-padded view; content shorter than 120pt won't shrink the panel below that floor. The `.topLeading` alignment is preserved to keep the LAST 30 DAYS heading anchored to the top across view cycles (per the in-review fix from #81).
- Verification: `xcodebuild` succeeded; simulator screenshot confirms both panels render at the same width, symmetric above and below the hero.

### feat: tap iOS home panels to cycle through view angles (issue #81)

- `ios/FirstContact/FirstContact/ContentView.swift`: iOS sibling of #79's web tap-to-cycle. Both `recentChangesPanel` and `summary30dPanel` are now wrapped in `Button { advance } label: { … }` with `.buttonStyle(.plain)` so the panel chrome (`.ultraThinMaterial` background, rounded-rectangle stroke, padding) stays unchanged. New `@State` properties `recentChangesView: Int = 0` and `summary30dView: Int = 0` hold the per-panel view index. New static helpers `viewCount = 3` and `wipText(_ view: Int) -> String` that returns `"View \(view + 1): Work in progress"` (string-identical to the web's `wipText` helper). View 0 renders the existing real content; views 1 / 2 render a single `Text(Self.wipText(view))` placeholder. View-state is per-launch — a cold start resets both panels to view 0.
- `summary30dPanel` gets `.frame(maxWidth: 320, minHeight: 120, alignment: .topLeading)` so view 1 / 2 don't shrink the panel below the typical Gemini-prose height. The `.topLeading` alignment (rather than the original `.leading`, which is `Alignment(horizontal: .leading, vertical: .center)`) is the key — without it, the VStack would center vertically in the 120pt frame when its content is shorter than 120pt, causing the "LAST 30 DAYS" heading to slide down on view 1 / 2. With `.topLeading`, the heading stays pinned to the top of the panel regardless of which view is showing. `recentChangesPanel` already had `.frame(maxWidth: 320, maxHeight: 200, alignment: .leading)` — its built-in `ScrollView` already fills the frame so the heading-repositioning issue doesn't apply there. Mirrors the web side's `lockPanelHeight` JS, but via static SwiftUI frame constraints rather than a dynamic snapshot (the static value is simpler and panel content is bounded enough that dynamic measurement isn't needed).
- Both panels gain an `.overlay(Text("⟳")…, alignment: .topTrailing)` decorative discoverability glyph at `opacity(0.5)`, `font(.system(size: 11))`, with `.accessibilityHidden(true)`. Parallel to the web's `.cycle-glyph` span.
- Accessibility: each `Button` carries an `.accessibilityLabel("…. Tap to cycle view.")` and `.accessibilityHint("Cycles through alternate views of the panel's data.")`. Using `Button` rather than `.onTapGesture` gives VoiceOver the correct "Button" trait, focusability, and free hardware-keyboard support on iPad — no manual `.accessibilityAddTraits(.isButton)` workaround needed.
- Verification: `xcodebuild -scheme FirstContact -sdk iphonesimulator … build` succeeded; simulator screenshot at view 0 confirms both panels render with the `⟳` glyph in the top-right and existing content intact. View 1 / 2 placeholder rendering is a straightforward state-machine path (`(view + 1) % 3` plus a `switch` in the body) — user manual-tap verification recommended for the cycle behavior.

### feat: tap home page panels to cycle through view angles (issue #79)

- `web/index.html`: both home-page information panels (`#recent-tasks` and `#summary-30d`) become tappable surfaces that cycle through three views on each tap. View 1 is the existing content (numbered list of recent issues / Gemini prose paragraph). Views 2 and 3 render the placeholder lines `View 2: Work in progress` and `View 3: Work in progress` respectively (the 1-based view number is embedded so the user can tell at a glance which view they're on, without a separate `(N/M)` indicator) — real angles (relative timestamps, commit-type counts, cache metadata, etc.) land in follow-up issues, one per view, so each future change is scope-bounded and revertible. View state is module-level (`recentTasksView`, `summaryView`) and in-memory only; a page reload resets both panels to view 0.
- `#summary-30d` re-positioned: anchored **bottom-center** via `position: fixed; bottom: 1rem; left: 50%; transform: translateX(-50%)`. Width formula matches `#recent-tasks` exactly — `width: min(20rem, calc(100vw - 2rem))` — so the panel doesn't resize when the window resizes (constant 20rem on viewports wider than ~22rem). `max-height: 25vh` + `overflow-y: auto` for scrolling long Gemini summaries, same pattern as `#recent-tasks`. `box-sizing: border-box` so padding/border don't push the panel past the declared width. The DOM placement also moved — the `<section>` is now a sibling of `<aside id="recent-tasks">` instead of being inside the centered hero `<div>`, since `position: fixed` makes the in-flow location moot and the sibling placement matches the actual visual layering.
- The script-block was restructured around a small state-machine pattern. New module-level functions `renderRecentTasksPanel()` and `renderSummaryPanel()` are the single source of truth for what each panel displays — they switch on the view index and render either the current view-1 state (numbered list / prose) or the `Work in progress` placeholder. Loaders (`loadRecent` and `loadSummary30d`) no longer touch the DOM directly; they update module-level state (`recentTasksState`, `summaryView1`) and call the renderers, which keeps the data and view layers separable.
- New helper `attachCycleHandler(panel, getView, setView, rerender)` wires a single panel's `click` and `keydown` (Enter / Space) listeners. The click handler skips when `window.getSelection().toString().length > 0` so drag-to-select inside the summary prose doesn't accidentally cycle views.
- New helper `lockPanelHeight(panel)` captures the panel's natural rendered height after each view-1 render and applies it as inline `min-height`, so cycling to the shorter view-2 / view-3 `Work in progress` placeholders doesn't shrink the surface. Called via `requestAnimationFrame` to read post-layout dimensions. `min-height` is a floor — view 1 can still grow past it later (e.g. when async data lands and the panel naturally expands), and the next snapshot raises the floor accordingly.
- Visual affordance: `cursor: pointer` + a faint `:hover` / `:focus-visible` background-brightness shift (rgba 0.16 → 0.18) on each panel, plus a small decorative `⟳` glyph at the top-right (`opacity: 0.5`, `pointer-events: none`, `aria-hidden="true"`). `#summary-30d` gained `position: relative` so the glyph anchors correctly; `#recent-tasks` is already `position: fixed` and serves as its own positioning context.
- Accessibility: both panels get `role="button"`, `tabindex="0"`, `aria-live="polite"`, and an updated `aria-label` that mentions the cycle action ("Changes made this week. Tap to cycle view." / "Summary of the last 30 days. Tap to cycle view."). Enter and Space keypresses trigger the same advance as a tap, with `event.preventDefault()` to suppress page-scroll on Space.
- `web/TEST-PLAN.md` § 4a.4 updated to reflect the new panel-level hover affordance (cursor changes, ⟳ glyph present). New § 4f (8 cases) covers the cycle mechanic on `#recent-tasks` — initial view, view-2 placeholder render, view-3 placeholder render, cycle-back-to-view-1, keyboard Tab+Enter / Tab+Space, refresh resets, error-state cycle (with API blocked), aria-attribute verification. New § 16l (8 cases) covers the same mechanic on `#summary-30d` — initial prose render, view-2 / view-3 placeholders, cycle-back restoring prose plus any stale-cache footnote, text-selection drag does NOT cycle the view, keyboard support, aria-attribute verification, in-memory-only view counter.

## 2026-06-05

### feat: 30-day work summary on iOS home screen via direct Gemini call + UserDefaults cache (issue #77)

- `ios/FirstContact/FirstContact/ContentView.swift`: new `summary30dPanel` view section placed under the quote in the centered hero `VStack`, mirroring the web home screen's `#summary-30d` layout (issue #74). Uses the same `.ultraThinMaterial` background, `0.5rem`-equivalent rounded-rectangle, white-25 stroke chrome as the existing `recentChangesPanel`. Heading "LAST 30 DAYS" in the uppercase / tracked style that matches "CHANGES MADE THIS WEEK". Four render states via a `SummaryState` enum: `.loading`, `.missingKey` (renders "Set GEMINI_API_KEY in Secrets.xcconfig — see ios/CLAUDE.md."), `.ready(prose, stale:)` (renders the prose plus an optional muted "(showing cached summary; refresh failed)" footnote when `stale: true`), and `.failedNoCache` ("Could not load summary."). New `loadSummary()` async task alongside `loadQuote()` and `loadIssues()`. Cache-first / stale-paint-then-refresh flow: read `UserDefaults.standard` under the key `firstcontact.summary30d.v1` (shape `{ summary, generatedAt, ttlHours }` — same JSON shape as the web cache to keep schema-bump coordination simple) → if fresh (age < 24 h), render and skip both the GitHub fetch and the Gemini call → otherwise render the stale value first (instant paint) if any, then fire `fetchClosedIssues30d()` (mirrors `summary_client._fetch_recent_closed_issues`: PR-filtered, 30-day window, cap 50, sorted by `closedAt` desc) and `callGemini()` in sequence → on success write the new entry, on failure surface the stale-cache or no-cache fallback. Word-count helpers `wordCount` / `truncateToWordLimit` and the prompt builder `buildSummaryPrompt` / `extractPrefix` mirror their Python counterparts in `api/server/summary_client.py` so the prose framing stays consistent across targets. The 50-word cap is enforced in the same shape: one retry with an explicit shorter-prompt suffix, then word-boundary truncation with `…`.
- `ios/FirstContact/FirstContact.xcodeproj/project.pbxproj`: added `XCRemoteSwiftPackageReference` for `https://github.com/google/generative-ai-swift` (kind `upToNextMajorVersion`, `minimumVersion 0.5.6`), `XCSwiftPackageProductDependency` for the `GoogleGenerativeAI` product, wired into the `FirstContact` target's `packageProductDependencies` and `Frameworks` build phase. Added `PBXFileReference` entries for `Config.xcconfig` and `Secrets.example.xcconfig`. Set `baseConfigurationReference = Config.xcconfig` on both the project's Debug + Release `XCBuildConfiguration` blocks. Added a `PBXShellScriptBuildPhase` named "Generate Secrets" that invokes `ios/FirstContact/scripts/generate-secrets.sh` before the `Sources` phase — the script writes `GeneratedSecrets.swift` with the `GEMINI_API_KEY` value from the xcconfig-injected build env. Set `ENABLE_USER_SCRIPT_SANDBOXING = NO` on both project Debug + Release configurations so the Run Script can read its own .sh file. New UUIDs in the `7700A0B0C0D0E0F00100000*` range.
- `ios/FirstContact/scripts/generate-secrets.sh` (new, committed, +x): reads `$GEMINI_API_KEY` from the xcconfig-injected build environment, escapes any backslashes / double-quotes for safe embedding in a Swift string literal, and writes `ios/FirstContact/FirstContact/GeneratedSecrets.swift` with a single `enum GeneratedSecrets { static let geminiAPIKey = "..." }` constant. Empty key is permitted — the generated file always exists, and Swift's empty-string check at the call site (`ContentView.geminiAPIKey()`) decides between the setup-hint state and the actual Gemini call.
- `ios/FirstContact/FirstContact.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` (new): SwiftPM lockfile pinning `generative-ai-swift` to `0.5.6` at revision `44b8ce120425f9cf53ca756f3434ca2c2696f8bd`. Commits alongside the project file so future builds resolve to the same version across machines.
- `ios/FirstContact/Config.xcconfig` (new, committed): single-line `#include? "Secrets.xcconfig"`. The optional include (`?`) means the build still succeeds when `Secrets.xcconfig` is missing — `GEMINI_API_KEY` resolves to empty string and the `summary30dPanel` falls into the `.missingKey` setup-hint state.
- `ios/FirstContact/Secrets.example.xcconfig` (new, committed): documented stub showing the expected shape (`GEMINI_API_KEY =`). A fresh clone copies this to `Secrets.xcconfig` and pastes the key.
- `.gitignore`: added `ios/FirstContact/Secrets.xcconfig` (the actual secrets file, never committed) and `ios/FirstContact/FirstContact/GeneratedSecrets.swift` (regenerated on every build by the "Generate Secrets" Run Script phase; secret embedded at build time, never committed).
- `ios/.gitignore`: un-ignored `Package.resolved` (the boilerplate Xcode template excluded it; for application targets it should be committed as the SPM lockfile).
- `ios/CLAUDE.md`: new "API keys and Secrets.xcconfig" subsection covering the xcconfig wire-up (`Config.xcconfig` → optional `#include? "Secrets.xcconfig"` → "Generate Secrets" Run Script phase → `GeneratedSecrets.swift` → Swift constant), the `cp Secrets.example.xcconfig → Secrets.xcconfig` bootstrap step, the `ENABLE_USER_SCRIPT_SANDBOXING = NO` requirement, the "second build resolves the GeneratedSecrets symbol" first-build wrinkle, and the recommendation to set the AI Studio iOS-Bundle-ID restriction as a second line of defense. Documents that the `INFOPLIST_KEY_*` mechanism does **not** carry custom keys — Xcode silently drops any key outside Apple's whitelist — which is why this implementation uses the Run Script pattern instead.
- Verification: `xcodebuild -resolvePackageDependencies` resolved `generative-ai-swift @ 0.5.6` cleanly; simulator build succeeded after the first-build "Generate Secrets" phase materialized `GeneratedSecrets.swift`; with a real key in `Secrets.xcconfig`, the simulator screenshot shows the LAST 30 DAYS panel rendering a live Gemini-generated prose summary (34 words on this run, well under the 50-word cap) pinned to the bottom of the screen. The earlier `INFOPLIST_KEY_GeminiAPIKey` Info.plist-injection path was dropped after `PlistBuddy -c "Print :GeminiAPIKey"` showed the key never reached the built `Info.plist` — Xcode only emits Apple-whitelisted `INFOPLIST_KEY_*` keys.

### docs(infra): allow SwiftPM dependencies in iOS app

- `ios/CLAUDE.md`: relaxed the opening "no third-party dependencies" line. New rule: "Swift Package Manager dependencies are allowed when they earn their weight — prefer official first-party SDKs (Apple, Google) over community packages." Motivated by the upcoming #77 (iOS 30-day-summary surface) which will pull in `google-generative-ai-swift` for the Gemini call — the SDK's type-safety / streaming / future-feature benefits beat a hand-rolled `URLSession` REST client for that use case, even though the existing iOS network calls (`loadQuote` / `loadIssues`) remain pure-URLSession. The convention encourages each new dep to clear the same bar.

### feat: persist viewer day-position and cursor memory across page refreshes (issue #68)

- `web/transcripts-viewer.html`: added a localStorage persistence layer on top of the existing in-memory `lastIndexByDay` (#66, § 13) and `cursorByPromptIndex` (#67, § 14) dicts. New module-level constants: `STORAGE_PREFIX = 'firstcontact:transcripts-viewer:v1:'`, `DAY_KEY` / `CURSOR_KEY` (composed under the prefix), `DAY_CAP = 100`, `CURSOR_CAP = 500`. New helpers: `safeRead(key)` (try/catch on `JSON.parse`, top-level type check rejects non-objects and arrays), `safeWrite(key, obj)` (try/catch on `setItem` to survive quota / private-browsing), `evictTo(obj, cap)` (insertion-order eviction — drops oldest `Object.keys()` entries until length ≤ cap), `isValidDayDict` / `isValidCursorDict` (whole-dict shape validators — reject the entire dict if any value is malformed, per the issue's "not entry-by-entry" rule), `hydrateMemory()` (one-shot call), `persistDay()` / `persistCursor()` (each evicts then writes). Hydration call sits **before** `render(startIndex)` in the load IIFE so the initial render honors any restored cursor for the starting prompt. Write-throughs added inside `render()` at the two existing modification sites: after `cursorByPromptIndex[currentIndex] = {line, col}` (the save-before-swap branch gated by `currentIndex !== clamped`) and after `lastIndexByDay[p.day] = clamped` (the day-bearing-prompt branch gated by `if (p.day)`). The 24-hour-TTL pattern from #74's cache is **not** used here — the issue scopes "survives refresh", not "stale after N hours". Eviction caps act as the bound on storage growth instead.
- `web/TEST-PLAN.md`: § 10m.3, § 13e.1, § 14a.3, § 14c.3 updated to reflect the new survives-refresh behavior (each now describes how to exercise the in-memory-only fallback by removing the relevant localStorage key). New § 17 (sub-sections 17a–17i, ~22 cases) covering hydrate-on-load (both dicts independently, ordering verified), write-on-modify round-trip, end-to-end refresh-survives behavior, schema-version-mismatch graceful ignore (the `:v0:` / `:v2:` migration story), quota-exceeded fallback (`Storage.prototype.setItem` monkey-patched to throw), corrupted-entry fallbacks (invalid JSON / wrong-shape value / wrong-shape top-level / array top-level — all four rejected), eviction-trigger behavior (DAY_CAP and CURSOR_CAP enforced after the first write, not at hydration time), and code-shape regression guards (grep counts on `STORAGE_PREFIX`, `hydrateMemory`, `persistDay` / `persistCursor`, the load-IIFE call ordering, and the cap constants).

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
