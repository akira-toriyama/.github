<!--
Title = gitmoji + Conventional Commits (see CONTRIBUTING.md):
  :sparkles: feat(scope): add the thing
A single-commit PR squash-merges with the commit message as the title — keep them in sync.
-->

## What & why

<!-- The change in a sentence or two, and the reason for it. -->

Closes #

## Verification

<!-- How you know it works. Replace this with the repo's real checks. -->

- [ ] Build & tests pass

## Notes for reviewers

<!-- Anything subtle, deferred, or risky — state it explicitly rather than leaving it implicit. -->

<!--
Translation: if this PR carries a description that becomes the squash-commit body, end it with a
`---（和訳）` separator and add a Japanese translation of the subject and body, per CONTRIBUTING.md.
A subject-only PR needs no translation.

Task tracker (optional): link a furrow task so its status follows this PR. One footer line:
  SetStatus-task: https://github.com/akira-toriyama/projects/blob/main/.furrow/bodies/<id>.md <lane>
PR open → the task is nudged to in-progress; merge → applies <lane> (e.g. `done`). Omit <lane> to
just reference it. Lanes: inbox → backlog → ready → in-progress → done → icebox. Non-blocking:
a bad id/lane comments on the PR but never blocks the merge.
-->
