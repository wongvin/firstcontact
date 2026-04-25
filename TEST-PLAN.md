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

## 3. Quote of the day (issue #2)

| ID | Steps | Expected |
|---|---|---|
| 3.1 | Load homepage. | A quote and `— <author>` line render below the device line, italicized, with a thin top border separating them from the hero. |
| 3.2 | Open DevTools → **Console** (Cmd-Option-J). Paste and run:<br>`for (let i=0;i<7;i++){ const d=new Date(Date.UTC(2026,0,1+i)); const day=Math.floor((d-Date.UTC(2026,0,0))/86400000); console.log(day%7); }` | Console prints seven lines: `1 2 3 4 5 6 0`. Confirms the day-of-year modulo-7 mapping covers all seven `QUOTES` indices. |
| 3.3 | Easiest: set a breakpoint inside the IIFE that picks the quote (Appendix B), at the `const quote = QUOTES[dayOfYear % QUOTES.length];` line. In the Console, evaluate `dayOfYear` to confirm today's value, then set `dayOfYear = dayOfYear + 1` and resume — quote text changes. Repeat for `+2`, `+3`. (Alternative: change your system clock to the next day, hard-refresh, observe.) | A different quote and author appear after each `dayOfYear` shift. Repeated reloads on the same UTC day always show the same quote. |
| 3.4 | DevTools → Elements panel, locate `<blockquote id="quote">`. | Contains `<span id="quote-text">` (non-empty) and a `<footer>` with `<span id="quote-author">` (non-empty). Both spans show today's quote text and author. |
| 3.5 | Open the URL on a real iPhone (Appendix J). | Quote card readable. Doesn't push the hero off-screen on a 375-px-wide viewport. |

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
