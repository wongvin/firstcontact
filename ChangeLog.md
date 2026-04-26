# Changelog

## 2026-04-26

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
