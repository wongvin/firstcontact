# First Contact — repo conventions

This repo contains two top-level targets:

- [`web/`](web/) — static homepage deployed to https://wongvin.github.io/firstcontact/. Web-specific conventions in [web/CLAUDE.md](web/CLAUDE.md).
- [`ios/`](ios/) — native iOS app (early development, free Apple ID signing for personal use). Target conventions will live in `ios/CLAUDE.md` once they emerge.

The `web/` target is deployed by the GitHub Actions workflow at [.github/workflows/pages.yml](.github/workflows/pages.yml).

## Repo-wide conventions

### Issue tracking

Every non-trivial change to this repo is tracked by a GitHub issue in
[Project 1](https://github.com/users/wongvin/projects/1). File the issue
**before** starting work when you can; if work has already begun or is
already shipped, file a retroactive issue so the project board stays
complete (see issue #5 for an example).

Counts as non-trivial:

- New features in any target (`web`, `ios`)
- Repo restructures / infra changes (CI workflows, Pages source switches,
  splitting/merging targets)
- Bug fixes that change user-visible behavior
- Multi-file refactors

Does not require an issue:

- Single-line typo or lint fixes
- A small tweak immediately following a freshly-closed issue (comment on
  that issue instead)
- Reformatting / wording-only doc edits

Format issue bodies with a short rationale and a `### Requirements` checklist —
match the style of issues #1–#5.

### Tracking active work

The project board's Status field tracks where each issue is in its lifecycle:

| Status | Trigger |
|---|---|
| Backlog | default — new issues land here |
| Ready | manually queued for the next session |
| In progress | implementation has begun |
| In review | implementation done, awaiting commit consent |
| Done | issue closed (set automatically by project automation on close) |
| Rejected | issue will not be implemented — declined outright, or implementation was tried but not merged (any tried-then-rejected branch is preserved for reference, e.g. #12) |

When implementation begins on an issue:

1. Move status from Backlog/Ready → **In progress**.
2. Set the **Start date** custom field to today. Set it once — don't update on subsequent revisions.

When implementation is complete and the diff is ready for commit:

3. Move status from In progress → **In review**.
4. Pause for explicit user consent before staging, committing, or pushing (see Commit hygiene below).

Both the status transition and the Start date can be set from the GitHub UI (project board → click the item → fields panel on the right) or via the `gh` CLI:

```bash
PROJECT_ID=$(gh project view 1 --owner wongvin --format json --jq .id)
ITEM_ID=$(gh project item-list 1 --owner wongvin --format json --limit 50 \
  --jq '.items[] | select(.content.number == <ISSUE_NUMBER>) | .id')

# Status -> In progress (or "In review")
STATUS_FIELD=$(gh project field-list 1 --owner wongvin --format json \
  --jq '.fields[] | select(.name == "Status") | .id')
OPT_ID=$(gh project field-list 1 --owner wongvin --format json \
  --jq '.fields[] | select(.name == "Status") | .options[] | select(.name == "In progress") | .id')
gh project item-edit --id "$ITEM_ID" --field-id "$STATUS_FIELD" \
  --project-id "$PROJECT_ID" --single-select-option-id "$OPT_ID"

# Start date -> today
START_DATE_FIELD=$(gh project field-list 1 --owner wongvin --format json \
  --jq '.fields[] | select(.name == "Start date") | .id')
gh project item-edit --id "$ITEM_ID" --field-id "$START_DATE_FIELD" \
  --project-id "$PROJECT_ID" --date YYYY-MM-DD
```

The CLI path requires the `project` scope on your `gh` token. The default
`read:project` scope is read-only and insufficient for writes; refresh with
`gh auth refresh -s project` once if you hit a scope error.

### Commit hygiene

**Never commit or push without explicit user consent.** When implementation
is complete, move the issue to **In review** (see Tracking active work) and
pause for review before staging or committing. The user approves the change
explicitly before code lands on the remote — every time, including doc-only
commits.

Update the root [ChangeLog.md](ChangeLog.md) in the same commit as any code
change in any target. Add an entry under today's date heading (create the
heading if one doesn't exist yet) with a prefix matching the commit type
(`feat:`, `fix:`, `docs:`, …) and 1–4 short bullets describing the change.
Stage `ChangeLog.md` alongside the code so both land in one commit. Cross-target
changes (touching both `web/` and `ios/`) get one entry that mentions both.

### Closing issues

When closing an issue, include an implementation summary in the close comment —
not a bare "shipped in `<sha>`" line. Cover:

- what files changed (or note that the change was infra-only);
- the key code, markup, CSS, and script pieces;
- any verification done.

For infra-only work, describe the commands / API calls made and how they were
verified. Exclude `ChangeLog.md` noise — focus on the functional change. For
long markdown bodies, post via `gh issue comment N --body-file -` with a
stdin heredoc (avoids bash parse errors on backticks/quotes). The same
`-F -` heredoc pattern is the safe form for `git commit` messages that
contain shell metacharacters like parentheses.
