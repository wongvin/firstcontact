# Changelog

## 2026-05-23

### docs(infra): refine /ship commit-subject convention (issue #38)

- `.claude/skills/ship/SKILL.md`: subject template now `<prefix>: <summary> (#N)` with a ≤50-char total budget so the issue tag stays visible in narrow UIs (`git log --oneline`, GitHub PR titles); body must not contain `Closes #N` or other `#N` refs; implementation-summary comment trigger derives the issue number from the branch name (`<N>-<slug>`) instead of scanning the commit body for `Closes #N`.

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
