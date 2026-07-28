# Changing shared infrastructure: stage it, don't ship it

A change to this repo — or to [glyph](https://github.com/akira-toriyama/glyph),
whose binary decides the commit lint, the semver verdict and the release notes of
every repo — does not land in one repo. It lands in all of them, at once, the
moment a pin moves. **The blast radius of a mistake here is the fleet.**

So: **do not roll a change out until you are convinced it is right. Building a
POC, or verifying something small first, is encouraged — it is not a detour.**
"It should work" is not conviction, and neither is a green run (see
[Green is not delivered](#green-is-not-delivered)).

This is the account-wide rule. The glyph-specific sequence — which four pins
exist, in what order they move — lives in
[`glyph-rollout-runbook.md`](glyph-rollout-runbook.md). The ref policy for this
repo's own reusables is in [`reusable-versioning.md`](reusable-versioning.md).

## The stages

Each stage answers a question the previous one cannot. Skipping one means
answering its question in production, across every repo.

| # | Stage | Question it answers | Evidence that it passed |
|---|---|---|---|
| 0 | **Local, headless** | Does the logic do what I think? | `go test ./...`, `scripts/check.sh`, the CLI run with real input |
| 1 | **POC / spike** | Is the mechanism even possible? | A throwaway branch, repo or script that demonstrates the load-bearing step end to end |
| 2 | **Live ammunition in `glyph-test`** | Does the *real* CI, on the *real* GitHub, reach the verdict I expect? | A PR in [`glyph-test`](https://github.com/akira-toriyama/glyph-test) whose job log shows the verdict — **fired both ways** |
| 3 | **Canary: one repo** | Does it survive a repo that was not built for the demo? | The pin moved in exactly one consumer, its next PR and release observed |
| 4 | **Fleet** | — | The audit green, and the real pins counted |

Stage 1 is the one people skip. When a step has never been done before — a token
that may not trigger a workflow, an API whose failure mode is guessed at, a
format no renderer has been asked about — **build the smallest thing that proves
it, before designing around the assumption.** A POC that costs an hour is cheaper
than a fleet-wide rollback.

Stage 2 means both halves: the thing that should now fail must fail, and the
escape hatch must pass. A rule that rejects everything is as broken as one that
rejects nothing. Close the PR without merging.

## Green is not delivered

Two failure modes have actually happened here, more than once:

- **A green run that did nothing.** `fleet-sync`'s manual trigger defaults to
  `dry-run: true`. A plain `gh workflow run fleet-sync.yml` reports what it
  *would* do, exits success, and changes nothing. On 2026-07-21 that success was
  read as "rolled out"; the real pins showed 34 of 35 repos still on the old
  version. Pass `-f dry-run=false`, then **count the pins on GitHub**.
- **A green test that proved nothing.** When code models an external system's
  behaviour, a test that checks glyph's output against glyph's own model proves
  only that glyph agrees with itself. Ask the real system —
  `gh api -X POST /markdown …` for GFM rendering, a real PR for a CI verdict —
  and keep the oracle independent of the implementation.

So the completion criterion for a rollout is never a workflow conclusion. It is
**the artefact, read back and counted**.

## What this rule does not cover

A change confined to one repo — its own tests, its own README, a fix that no
other repo consumes — is ordinary work. Ship it normally. This policy is about
anything that reaches other repos: the `fleet/` canonicals, the reusable
workflows, the composite actions, and every glyph release.

## What is enforced by machine, and what is not

Being honest about this is the point — an unenforced rule that reads as enforced
is worse than no rule.

**Enforced today**

- `glyph-pin-audit.yml` fails while any repo's real `uses:` — or the `version:`
  its glyph install step passes — disagrees with the canonical pin (daily, and on
  canonical-pin changes). Stage 4's "audit green". Its own reader is table-tested
  (`tests/glyph-pin-scan.test.sh`), because a check that silently stops SEEING a
  pin is indistinguishable from a level fleet.
- What it does NOT see: anything outside `.github/**.yml`, and any repo the
  runner's token cannot list (29 of 35, on 2026-07-22). Green means level as far
  as it looks.
- `fleet-sync`'s dry-run default. It cannot write by accident; it can only fail
  to write while looking like it wrote. `glyph-pin-rewrite.yml` — the repair path
  for the three glyph pins fleet-sync cannot byte-copy — takes the same default,
  and never writes outside a pull request.
- Confinement of that repair. `scripts/glyph-pin-rewrite.sh` compares its output
  against its input line by line and writes **nothing at all** if a line outside
  a glyph pin moved, then re-reads the result through the audit's own scanner to
  confirm the pin actually landed. Both refusals are pinned by mutation in
  `tests/glyph-pin-rewrite.test.sh`: a guard that only ever runs on correct input
  proves nothing about the case it exists for.
- Branch protection on the repos that have it: fleet-sync opens a PR instead of
  pushing, so a bad canonical cannot land silently there.
- **Stage 3 → 4, for the `fleet/` canonicals: the rollout ledger** (t-yyfv).
  Every fleet-sync apply run — scheduled ones included — first passes
  `scripts/fleet-rollout-gate.sh` against `fleet/rollout.json`. A canonical
  change cannot distribute until its ledger entry covers exactly the bytes on
  disk (and `tests/fleet-rollout-gate.test.sh` fails the PR that edits a
  canonical without updating the ledger), a canary-scoped apply has run, its
  read-back was machine-recorded as evidence — the gate verifies the recorded
  run id names a real, successful fleet-sync run, so a typed-in evidence block
  does not pass — and a 48-hour soak has elapsed. Merging to the hub's main is
  no longer the deploy. Mechanics: `fleet/README.md`, "Rollout ledger".
- **Read-back after an apply** (t-dk1e): an apply run re-fetches every managed
  file from every repo and fails on any mismatch — "counting the artefact" is
  no longer a discipline for fleet-sync-managed files; it is the last step of
  the run. The canary evidence above is this read-back, recorded.

**Not enforced — carried by whoever is doing the work**

- Stages 1 and 2. Nothing checks that a POC was built or that `glyph-test` was
  fired at — the ledger's stage field can say `"glyph-test"`, and while it does
  nothing distributes, but nothing verifies the rehearsal actually happened
  before the stage advanced to `"canary"`.
- "Both halves" in stage 2. A one-directional test looks identical to a
  two-directional one from outside.
- The same sequence for the **other** rollout path: the three glyph pins that
  `glyph-pin-rewrite.yml` moves via PRs live outside `fleet/`, so the ledger
  does not see them. Their safety net is the daily `glyph-pin-audit` (with the
  blind spots named above), not a staged gate.

Closing the stage-2 gap is tracked work, not a footnote: the rehearsal that
fires the release path at real GitHub is an open task. Until it exists, stages
1–2 are a discipline — write down which ones you actually performed, and say
plainly which you skipped.
