# Web target — conventions

Static homepage at https://wongvin.github.io/firstcontact/. A single `index.html` — no build step, no dependencies, no backend. Deployed by `.github/workflows/pages.yml` (uploads the contents of this folder).

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

When rendering any text pulled from any external API (titles, bodies, quotes,
authors) into the DOM, construct nodes with `document.createElement` +
`textContent` — never `innerHTML` with API strings.

Cheap defense-in-depth against any future API response containing HTML
characters. No HTML-escape helper needed.

## Test plan

[TEST-PLAN.md](TEST-PLAN.md) covers manual test cases for this target. Update
it in the same commit as feature changes — add a new section per issue;
don't delete sections for shipped features (they're regression coverage).
