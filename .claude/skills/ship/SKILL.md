---
name: ship
description: Commit staged changes, push to origin, post an implementation-summary comment on the branch's issue, and ensure a PR exists (creating one if needed). The user invoking /ship IS the explicit commit consent CLAUDE.md normally gates on.
---

`/ship` is the explicit user consent for the commit+push step that CLAUDE.md
normally gates on. Run this sequence:

1. Show `git status` and `git diff --staged` so the user sees what's about to ship.
2. Check that `ChangeLog.md` is staged. If not, ask the user for a one-line
   summary and add an entry under today's date heading with the matching
   conventional prefix (`feat:`, `fix:`, `docs:`, …).
3. Write the commit message to a file (via the Write tool) and commit with
   `git commit -F <file>` — never inline `-m`, and never a heredoc. Writing the
   message to a file sidesteps shell-quoting entirely, so backticks,
   parentheses, and apostrophes (e.g. `repo's`) all survive verbatim. Append
   `(#N)` to the subject (for multi-issue commits: `(#N, #M)`); do **not** add
   `Closes #N` or any other `#N` reference in the body. **Keep the whole subject
   ≤50 chars** so the trailing `(#N)` stays visible in `git log --oneline`,
   GitHub PR-title fields, and other narrow UIs — if the summary is running
   long, tighten the wording rather than letting the issue tag get clipped.
   Message file contents:
   ```
   <conventional prefix>: <summary> (#N)

   <body>
   ```
   Then: `git commit -F /tmp/<file>` (any path outside the repo is fine).
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
6. Ensure a PR exists for the branch and surface its URL:
   ```bash
   gh pr view --json url,state  # check first
   ```
   If no PR exists, create one against `main`. PR title follows the same
   `<prefix>: <summary> (#N)` shape as the commit subject (single-commit
   branch: reuse the commit subject; multi-commit branch: summarize across
   commits). PR body should include a short summary and `Closes #N` so the
   issue auto-closes on merge — this is the one place `Closes #N` is
   allowed (PR body, not commit message):
   ```bash
   gh pr create --base main --title "<prefix>: <summary> (#N)" \
     --body-file - <<'EOF'
   <one-paragraph summary>

   Closes #N
   EOF
   ```
   Print the resulting URL so the user can click through.
7. Report the commit SHA, push result, which issue(s) received a summary
   comment, and the PR URL.

Rules:

- Never `--no-verify`.
- Never write `Closes #N` in the commit message. The subject's `(#N)` suffix
  is the only `#N` reference; the body stays free of issue numbers. Closing
  the issue happens elsewhere (PR body, manual `gh issue close`).
- Subject budget ≤50 chars total (including the `(#N)` suffix) — if it spills,
  shorten the summary, not the suffix.
- Always commit via `git commit -F <file>` with the message written to a file
  first — never inline `-m` (mangles backticks/parens) and never a heredoc
  (an apostrophe in the body trips the shell eval wrapper).
- Don't delete branches as part of `/ship` — that's `/cleanup-branches`.
