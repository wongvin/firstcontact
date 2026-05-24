---
name: ship
description: Commit staged changes, push to origin, and post an implementation-summary comment on the branch's issue. The user invoking /ship IS the explicit commit consent CLAUDE.md normally gates on.
---

`/ship` is the explicit user consent for the commit+push step that CLAUDE.md
normally gates on. Run this sequence:

1. Show `git status` and `git diff --staged` so the user sees what's about to ship.
2. Check that `ChangeLog.md` is staged. If not, ask the user for a one-line
   summary and add an entry under today's date heading with the matching
   conventional prefix (`feat:`, `fix:`, `docs:`, …).
3. Write the commit using a HEREDOC commit message — never inline — so backticks
   and parentheses parse correctly. Append `(#N)` to the subject (for
   multi-issue commits: `(#N, #M)`); do **not** add `Closes #N` or any other
   `#N` reference in the body. **Keep the whole subject ≤50 chars** so the
   trailing `(#N)` stays visible in `git log --oneline`, GitHub PR-title
   fields, and other narrow UIs — if the summary is running long, tighten
   the wording rather than letting the issue tag get clipped:
   ```bash
   git commit -m "$(cat <<'EOF'
   <conventional prefix>: <summary> (#N)

   <body>
   EOF
   )"
   ```
   If a heredoc fails to parse (rare, with certain shell environments),
   fall back to `git commit -F <file>` after writing the message to a file.
4. `git push` to origin.
5. Derive the issue number from the branch name (`<N>-<slug>`) and post an
   implementation-summary comment via heredoc stdin:
   ```bash
   gh issue comment N --body-file - <<'EOF'
   <summary covering: files changed, key code pieces, verification done.
   Skip ChangeLog noise — focus on the functional change.>
   EOF
   ```
   If the branch name doesn't match `<N>-<slug>`, or the commit addresses
   multiple issues, ask the user which issues to comment on before posting.
   Closing the issue itself is handled separately (PR merge, or manual
   `gh issue close`) — `/ship` only posts the summary.
6. Report the commit SHA, push result, and which issue(s) received a summary
   comment.

Rules:

- Never `--no-verify`.
- Never write `Closes #N` in the commit message. The subject's `(#N)` suffix
  is the only `#N` reference; the body stays free of issue numbers. Closing
  the issue happens elsewhere (PR body, manual `gh issue close`).
- Subject budget ≤50 chars total (including the `(#N)` suffix) — if it spills,
  shorten the summary, not the suffix.
- Never bypass the heredoc commit-message path — inline `-m` mangles
  backticks/parens.
- Don't delete branches as part of `/ship` — that's `/cleanup-branches`.
