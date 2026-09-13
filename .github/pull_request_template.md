<!--
Title = <:gemoji:>[(scope)]<sigil> <subject> — your repo's glyph.toml decides
(see CONTRIBUTING.md). The sigil is the version signal and is never optional:
= none / ~ patch / ^ minor / ! major / % promote to 1.0.0.
  :sparkles:(scope)^ add the thing
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
Task tracker (optional): link a furrow task so its status follows this PR. One footer line:
  SetStatus-task: https://github.com/akira-toriyama/projects/blob/main/.furrow/bodies/<id>.md <lane>
PR open → the task is nudged to in-progress; merge → applies <lane> (e.g. `done`). Omit <lane> to
just reference it. Lanes: inbox → backlog → ready → in-progress → done → icebox. Non-blocking:
a bad id/lane comments on the PR but never blocks the merge.
-->
