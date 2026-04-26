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

### Commit hygiene

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
