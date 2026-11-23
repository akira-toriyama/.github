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
Task tracker (optional), so a furrow task's status follows this PR: a footer line of its own that
starts with the directive SetStatus-task:, then the task's body URL
https://github.com/akira-toriyama/projects/blob/main/.furrow/bodies/<id>.md and an optional <lane>.
furrow reads this comment too, so no line in it starts with the directive. <lane> is where the task
should be once the PR lands (e.g. `done`); without it, open and merge only annotate the task body.
`furrow apply --help` has the rules, `furrow board` the lanes. Non-blocking: a bad id or lane
comments on the PR but never blocks the merge.
-->
