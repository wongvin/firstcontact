---
name: ship
description: Commit staged changes, push to origin, and close any "Closes #N" issues with an implementation summary. The user invoking /ship IS the explicit commit consent CLAUDE.md normally gates on.
---

`/ship` is the explicit user consent for the commit+push step that CLAUDE.md
normally gates on. Run this sequence:

1. Show `git status` and `git diff --staged` so the user sees what's about to ship.
2. Check that `ChangeLog.md` is staged. If not, ask the user for a one-line
   summary and add an entry under today's date heading with the matching
   conventional prefix (`feat:`, `fix:`, `docs:`, …).
3. Write the commit using a HEREDOC commit message — never inline — so backticks
   and parentheses parse correctly:
   ```bash
   git commit -m "$(cat <<'EOF'
   <conventional prefix>: <summary>

   <body>

   Closes #N
   EOF
   )"
   ```
4. `git push` to origin.
5. For each `Closes #N` referenced in the commit body, post an
   implementation-summary comment via heredoc stdin:
   ```bash
   gh issue comment N --body-file - <<'EOF'
   <summary covering: files changed, key code pieces, verification done.
   Skip ChangeLog noise — focus on the functional change.>
   EOF
   ```
   The issue itself closes automatically because of the `Closes #N` in the
   commit (GitHub's "linked PR/commit closes issue" behavior). Project board
   automation moves it to Done.
6. Report the commit SHA, push result, and which issues were closed.

Rules:

- Never `--no-verify`.
- Never bypass the heredoc commit-message path — inline `-m` mangles
  backticks/parens.
- Don't delete branches as part of `/ship` — that's `/cleanup-branches`.
- If `Closes #N` references the wrong issue or there are none, ask the user
  before posting anything to issues.
