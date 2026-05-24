---
name: cleanup-branches
description: Find merged local branches and delete both local + remote copies, preserving any branch tied to a Rejected issue per CLAUDE.md.
---

Follow this sequence to clean up branches:

1. Run `git fetch --prune` to drop stale remote refs.
2. Run `git branch --merged origin/main` to list local branches fully merged into the canonical remote main; exclude `main` itself from the candidate set. (Query the remote ref, not local `main`, because a PR merged on github.com doesn't fast-forward local `main` until the user runs `git pull` — checking local `main` would undercount candidates.)
3. For each candidate, check whether it is tied to a Rejected issue. The convention is that rejected branch names start with the issue number (e.g. `12-add-pull-to-refresh`) and the corresponding issue title is prefixed with `[Rejected] `. Cross-check with:
   ```bash
   gh issue list --state all --search '[Rejected] in:title' --json number,title
   ```
   Skip any branch whose leading number matches a Rejected issue — do not delete locally or remotely.
4. For the remaining candidates, show the user the proposed delete list and wait for explicit yes/no before running the deletes.

   If a candidate is the currently-checked-out branch, switch to `main` and bring local `main` up to date with `origin/main` first — the delete will fail otherwise. Use `git merge --ff-only origin/main` (or the equivalent `git pull origin main`), **not** bare `git pull` / `git pull --ff-only`: the step-1 `git fetch --prune` leaves `.git/FETCH_HEAD` with multiple for-merge entries (one per fetched branch), and bare `pull` consults FETCH_HEAD and aborts with `fatal: Cannot fast-forward to multiple branches`. Specifying the source explicitly bypasses FETCH_HEAD.

   ```bash
   # If the candidate is the current branch:
   git checkout main
   git merge --ff-only origin/main   # NOT `git pull` / `git pull --ff-only`

   # Then for each candidate:
   git branch -d <name>
   git push origin --delete <name>
   ```
5. If a branch fails `git branch -d` because it's unmerged, do NOT use `-D` automatically. Stop and ask the user.

Report what was deleted, what was skipped (and why), and what needed user attention.
