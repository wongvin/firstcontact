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

---

## 1. HTTPS / redirect (issue #1)

| ID | Steps | Expected |
|---|---|---|
| 1.1 | `curl -sI https://wongvin.github.io/firstcontact/` | First line is `HTTP/2 200`. `content-type: text/html` present. |
| 1.2 | `curl -sI http://wongvin.github.io/firstcontact/` | First line is `HTTP/1.1 301 Moved Permanently`. `Location:` header points to `https://…`. |
| 1.3 | In Chrome address bar, type `http://wongvin.github.io/firstcontact/` and submit | Browser silently navigates to `https://…`. Padlock icon shown. |

## 2. Hero & device line

| ID | Steps | Expected |
|---|---|---|
| 2.1 | Load homepage on desktop | "Hello, World!" heading visible, centered horizontally and vertically. |
| 2.2 | Same | Gradient background (purple→indigo) covers full viewport. |
| 2.3 | Same | A line below reads `You are on: <something>` (e.g. `Macintosh; Intel Mac OS X 10_15_7`). The token between parens of the user-agent should appear. |
| 2.4 | Load on iPhone Safari | Same hero/device line render; nothing overflows the viewport horizontally. |
| 2.5 | DevTools → toggle JS off → reload | Hero heading still renders. Device line keeps placeholder text "Loading device info…" (acceptable degradation). |

## 3. Quote of the day (issue #2)

| ID | Steps | Expected |
|---|---|---|
| 3.1 | Load homepage | A quote and `— <author>` line render below the device line, italicized, with a thin top border. |
| 3.2 | Open DevTools → Console → run<br>`for (let i=0;i<7;i++){ const d=new Date(Date.UTC(2026,0,1+i)); const day=Math.floor((d-Date.UTC(2026,0,0))/86400000); console.log(day%7); }` | Output is `1 2 3 4 5 6 0` (or similar full sweep of 0–6). Confirms day-of-year mod 7 covers all 7 quotes. |
| 3.3 | Hard-refresh on consecutive UTC days | Quote text changes between days. Same quote on repeated loads same UTC day. |
| 3.4 | View source / DevTools → check `<blockquote>` markup | Contains a `<span id="quote-text">` and a `<footer>` with `<span id="quote-author">`. Both populated. |
| 3.5 | iPhone Safari | Quote card readable; doesn't push hero off-screen on a 375-px-wide viewport. |

## 4. Changes made this week (issue #3)

### 4a. Happy path

| ID | Steps | Expected |
|---|---|---|
| 4a.1 | Load homepage | Top-right panel visible. Heading "CHANGES MADE THIS WEEK" in uppercase, bold, with a thin underline border. |
| 4a.2 | Same | Body is a **numbered** list (`<ol>`, decimal markers visible). |
| 4a.3 | Same | List items are titles of issues closed in the last 7 days, **most recent first**. Currently expect issue #3 ("Display tasks completed in the last 7 days"), then #2 ("Add quote of the day to homepage"), then #1 ("HTTPS homepage"). |
| 4a.4 | Same | Each entry is **plain text** — no link, no `(Xh ago)` timestamp. |
| 4a.5 | DevTools → Network tab, hard refresh | Exactly one request to `https://api.github.com/repos/wongvin/firstcontact/issues?state=closed&per_page=30&sort=updated&direction=desc`. Status `200`. |

### 4b. Layout / sizing

| ID | Steps | Expected |
|---|---|---|
| 4b.1 | Resize window to 1440 wide | Panel sits in top-right, ~20rem (320px) wide, with ~16px padding from the edges. |
| 4b.2 | Resize window to 360 wide | Panel width shrinks to `100vw - 2rem` (≈ 328 px) and stays in the top-right corner without overlapping the right edge. |
| 4b.3 | DevTools → Inspect `#recent-tasks` → check computed style | `max-height` = `25vh`. `overflow-y` = `auto`. |
| 4b.4 | Manually add 30 fake `<li>` entries via DevTools | Panel does not exceed 25vh; internal vertical scrollbar appears. |

### 4c. Empty path

| ID | Steps | Expected |
|---|---|---|
| 4c.1 | DevTools → Sources → set a breakpoint inside `loadRecent`, modify `cutoff = Date.now() + 1e9` (future), resume | Panel shows "No changes this week." (un-bulleted, dimmed). |

### 4d. Error path

| ID | Steps | Expected |
|---|---|---|
| 4d.1 | DevTools → Network → block the URL `*api.github.com*` → reload | Panel shows "Could not load recent changes." (un-bulleted, dimmed). No console error spam beyond the blocked-request log. |
| 4d.2 | Throttle to "Offline" → reload | Same as 4d.1: graceful "Could not load recent changes." |

### 4e. Defense-in-depth

| ID | Steps | Expected |
|---|---|---|
| 4e.1 | DevTools → Inspect a list item | Title is rendered as a Text node, not an `<a>` and not raw HTML. (Confirms `textContent` path; protects against any future title containing `<script>` or markup.) |
| 4e.2 | Manually craft a fetch response in DevTools (e.g. via overrides) where one issue title is `<img src=x onerror=alert(1)>` and reload | The literal string is shown in the list; **no alert fires**, no image loaded. |

## 5. Cross-browser / accessibility quick checks

| ID | Steps | Expected |
|---|---|---|
| 5.1 | Repeat 2.1, 3.1, 4a.1 in Safari (desktop) | All pass. `backdrop-filter` (`-webkit-` prefix) renders the panel as translucent / blurred. |
| 5.2 | Repeat 2.1, 3.1, 4a.1 in Mobile Safari (iPhone) | All pass. |
| 5.3 | Tab through the page with the keyboard | Focus visits the (empty) hero, then the recent-tasks list. No focusable elements should trap. |
| 5.4 | DevTools → Accessibility tree | `<aside>` has `aria-label="Changes made this week"`. `<h2>` is reachable via headings landmark. |
| 5.5 | DevTools → Lighthouse → Accessibility audit | Score ≥ 90. (Soft target; investigate any flag.) |

## Exit criteria

A change ships when:

1. All test cases above for **affected features** pass.
2. `gh api /repos/wongvin/firstcontact/pages/builds/latest --jq .status` returns `built` for the commit under test.
3. iPhone visual smoke test (open production URL on a real iPhone over cellular) confirms the headline + new feature both render.

## Notes

- This plan is manual-execution only. No automated test runner is set up (and none is justified at the project's current size).
- For each new issue, append a section above (e.g. `## 5. Foo feature (issue #N)`) and update the in-scope list. Don't delete sections for shipped features — they're regression-coverage.
