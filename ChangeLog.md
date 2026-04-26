# Changelog

## 2026-04-25

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
