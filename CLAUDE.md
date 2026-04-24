# Project conventions for Claude

Personal static-site hosted on GitHub Pages at https://wongvin.github.io/firstcontact/.
A single `index.html` — no build step, no dependencies, no backend.

## Data source for project/task state

Project-board "Done" items are kept in sync with closed GitHub issues via the
board's built-in workflow automation. When the homepage needs task/issue data,
fetch the public REST endpoint directly from the browser:

```
https://api.github.com/repos/wongvin/firstcontact/issues?state=closed
```

- No auth required. CORS is open. 60 req/hr per visitor IP is plenty for a
  personal page.
- `/issues` returns both issues **and** PRs — always filter out entries with
  `pull_request` set.

Do **not** reach for GraphQL (requires a token, even for public data) or a
GitHub Actions cron that pre-generates a `tasks.json` — both are
over-engineered at this scale.

## Rendering API-sourced text

When rendering any text pulled from the GitHub API (titles, bodies, labels)
into the DOM, construct nodes with `document.createElement` +
`textContent` — never `innerHTML` with API strings.

Cheap defense-in-depth against any future issue title containing HTML
characters. No HTML-escape helper needed.

## Commit hygiene

Update `ChangeLog.md` in the same commit as the code change. Add an entry
under today's date heading (create the heading if one doesn't exist yet) with
a prefix matching the commit type (`feat:`, `fix:`, `docs:`, …) and 1–4 short
bullets describing the change. Stage `ChangeLog.md` alongside the code so
both land in one commit.

## Closing issues

When closing an issue, include an implementation summary in the close comment —
not a bare "shipped in `<sha>`" line. Cover:

- what files changed (or note that the change was infra-only);
- the key code, markup, CSS, and script pieces;
- any verification done.

For infra-only work, describe the commands / API calls made and how they were
verified. Exclude `ChangeLog.md` noise — focus on the functional change. For
long markdown bodies, post via `gh issue comment N --body-file -` with a
stdin heredoc (avoids bash parse errors on backticks/quotes).
