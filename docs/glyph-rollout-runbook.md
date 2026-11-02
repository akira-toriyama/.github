# Rolling out a glyph release across the fleet

glyph is shared infrastructure: the commit lint, the semver verdict and the
release notes for **every** repo come out of one binary. A rollout therefore
touches the whole fleet, and every step below exists because it was got wrong at
least once. (No repo count here on purpose — the loops print the live one:
`glyph-pin-audit` logs `auditing N repos (P private)` and `fleet-sync` logs
`candidate repos: N`. A hand-kept number in prose only ever disagrees with them.
The two `N`s must agree — both loops list with the same PAT, after a week in which
the audit's default token silently saw 29 repos to fleet-sync's 35: the six
private ones were never audited and nothing was red.) Machine checks come first; this document only covers what a check cannot.

This document is the **sequence**. Whether you have earned the right to run it —
how far to verify before a change reaches the fleet at all — is
[`fleet-change-policy.md`](fleet-change-policy.md): local → POC → live ammunition
in `glyph-test` → canary → fleet. Step 1 below is the earliest point at which
that staging is already over.

Related: [`reusable-versioning.md`](reusable-versioning.md) (why pins are concrete
tags), [`CONTRIBUTING.md`](../CONTRIBUTING.md) (the convention glyph enforces).

## What is pinned, and by whom

Six things reference glyph, and **no single mechanism moves all six**. The split
is not cosmetic: the first two are one canonical byte-copied everywhere, the last
four are lines inside files each repo owns and writes differently.

| Reference | Where the pin lives | Propagated by |
|---|---|---|
| `workflows/lint.yml` | `fleet/commit-lint.yml` | fleet-sync (copies the file) |
| `workflows/pr-verdict.yml` | `fleet/version-preview.yml` | fleet-sync (copies the file) |
| `workflows/release.yml` | each repo's own release workflow | glyph-pin-rewrite (**opens a PR**) |
| `actions/install` | each repo's release/CI workflows | glyph-pin-rewrite (**opens a PR**) |
| the **binary** that action installs | `with: version:` on that same step | glyph-pin-rewrite (**opens a PR**) |
| `actions/release-notes` | the release workflow of a repo that cuts tags by hand (glyph v6.1.0+) | glyph-pin-rewrite (**opens a PR**) |

Those bespoke references moved **only by hand** until 2026-07-28 — one pull request per
repo per glyph release, 22 references across 14 repos on the v0.11.2 rollout, with
the audit red for the four days it took. `glyph-pin-rewrite.yml` opens those pull
requests now, and `fleet-automerge.yml` (chained at the end of its run, and four
times a day) arms auto-merge on every one **below a major**, so each repo's
required checks merge it. **A major pin is still yours to merge**; until every
pull merges the audit is correctly red.

Do not look for those pins by filename. `sill` keeps its install step in
`.github/workflows/build.yml` while the eight other consumers call it
`release.yml` — the census that planned the v0.11.2 rollout keyed on the filename
and lost sill silently. Search by content (`akira-toriyama/glyph`), which is what
both the audit and the rewriter do.

`.github` also pins `lint.yml` in its own `self-commit-lint.yml`. fleet-sync
EXCLUDEs the hub, so that one is hand-maintained; glyph-pin-rewrite does **not**
exclude it, and `tests/fleet-manifest.test.sh` fails at PR time if it drifts.

The install action is the sneaky one, and its `version:` input is sneakier still —
it is a *fifth* reference hiding inside the fourth, two lines below it and easy to
leave behind when the `@tag` moves. A repo can have every *workflow* on the new
tag while still installing an **older binary**, so its CI enforces rules that no
longer match the workflows around it. dotfiles sat exactly like that in July 2026;
by the time anyone looked again, seven repos did, all on a **v0.8.0 binary behind a
v0.10.2 action** — three releases of convention enforced by nobody's decision. The
pin audit read `uses:` only, so none of it registered.

**Bump the `@tag` and the `version:` in the same edit, always.** They ship lockstep
from one glyph release; there is no combination of the two that is deliberate.

## Configuration precedes the pin

glyph embeds no grammar: every gate reads the repository's own committed
`glyph.toml` (CONTRIBUTING, "Commit messages"), and in a checkout without one
every gate answers usage, exit 2 — `lint` (`--stdin`, `--range`, `--pr`),
`bump`, `notes`, `preview` and `release --dry-run` each did on glyph 46909b3
(measured 2026-11-03; glyph's `TestMissingConfigStaysUsage` pins it for
`lint`). So the file lands in a repository before its first glyph pin, never
after: until a pin arrives nothing reads the file, while a pin that arrives
first reddens every push and pull request there.

Two mechanisms hold that order, one from each side. glyph-pin-rewrite's
**config arm** (in its "Move every unmanaged glyph pin to the canonical" step)
fetches glyph's own `glyph.toml` at the canonical tag — held byte-identical
to `glyph init --gemoji` output by glyph's
`TestGlyphOwnConfigIsTheGemojiPreset` — and adds it to every glyph consumer
that has none, in the same per-repo pull request as that repository's pins (a
config-only pull when no pin moves). It never overwrites an existing
`glyph.toml`: that file is the repository's own grammar to evolve.
`glyph-pin-audit` is red, by name, for a consumer of a v3+ canonical with no
committed `glyph.toml`. Neither closes the window fleet-sync opens: fleet-sync
moves `commit-lint.yml` by direct commit, and the arm's pull request follows
only on the rewriter's next run, so commit `glyph init --gemoji` output to a
new repository before fleet-sync first reaches it.

**A major that removes a `glyph.toml` key.** glyph's loader refuses a key it
does not know — with a `[commit] style` line in the file every one of those
gates answers exit 2, `unknown key commit.style`, on glyph 46909b3 (measured
2026-11-03) — so a major that drops a key from the schema stops loading every
`glyph.toml` that still carries it. The same order applies one level down: the
line leaves every copy first, under the current pin, which loads the file
without it, and only then does the major ship. The record is t-85y9
(2026-10-20 → 10-26: glyph v6.0.0 removing `[commit] style`).

- **Census the whole tree, not the root file.** On t-85y9 the key sat in
  three kinds of place: (1) the root `glyph.toml` (39 of 39 repositories);
  (2) a workflow-embedded fixture — glyph-test's `e2e-v2.yml` wrote its own
  `glyph.toml` carrying the line, which `gh search code` did not find and a
  tree-wide grep did (glyph-test#127 dropped it); (3) the two harnesses'
  frozen coordinates — glyph-test runs its walk tier in a worktree of tag
  `v0.3.0` and glyph-monorepo-test in a checkout of `380db9d`, the
  `glyph.toml` of that day still carried the key, and both walk tiers went red
  until each harness edited its frozen copy (glyph-test#130,
  glyph-monorepo-test#43). So shallow-clone the default branch of every
  non-archived, non-fork repository (`gh repo list <owner> --no-archived
  --source --limit 200`, the limit the hub's own loops pass — gh's default of
  30 listed 30 of this owner's 39 on 2026-11-03 — then
  `gh repo clone <repo> -- --depth 1 --branch <default>`), grep each whole
  tree outside `.git` with leading whitespace allowed (an embedded fixture is
  indented), read `glyph.toml` at the two frozen coordinates, and edit the
  harnesses first. fleet-preflight does not stand in for the census: it runs
  the candidate in each consumer's default-branch clone, which reads the root
  file alone, so a zero-move preflight says nothing about the other two kinds.
- **Then the sequence.** Under the current pin, open one one-line pull request
  per repository with `scripts/glyph-config-drop.sh` (`GLYPH=` the current
  pin's binary; `--dry` over every repository first): it drops exactly one
  line through the API and refuses unless the message, and its first line as
  the title, lint clean under that repository's old and new file. Merge them
  with `scripts/merge-when-green.sh`, re-run the census to zero, then merge
  the major and roll it out by the sequence below. On t-85y9 the one-line
  pulls opened under v5.0.0 — glyph-test#126 first, pare#55 as the canary,
  then the other 36 — and before glyph#317 merged the census found the key
  only in glyph's own tree, which that pull edits, and in a task-body record.

## The sequence

0. **Before the tag**, run glyph's own `scripts/fleet-preflight.sh ./bin/glyph`
   against the binary you are about to ship. It is the only thing that answers
   "how many repos does this release change the verdict for" while the answer is
   still free — a tag is cut on a frozen tree, so from step 1 onward the question
   is rhetorical. It probes every repo twice, once with the tag the fleet is
   pinned at and once with the candidate, and reports only the repos whose
   verdict MOVES. Read three things rather than assume them: a `lint` move is a
   **prediction** (CI lints a pull request's own commits, so nothing already
   merged is re-judged and no existing run turns red), a `bump` move is
   **retroactive** (that repo's next release cuts a different version, having
   changed nothing), and the `✓` line stamps the count a **FLOOR** whenever
   anything weakened the claim — including repos pinned *below* the baseline,
   whose real change is larger than their row. On the v1.0.0 rollout it found 18
   of 35 moving, all on lint, and named 11 repos still pinned below v0.12.0
   before step 5 went looking for them.
1. Merge the glyph PR, tag, and confirm the release actually published:
   `gh release view vX.Y.Z --json isDraft,assets` — assets must be non-zero and
   `isDraft` false. Pins resolve to a tag, but `actions/install` downloads
   **release assets**; a draft or asset-less release fails every consumer at once.
2. Bump `fleet/commit-lint.yml` and `fleet/version-preview.yml` in one PR.
   Before merging, apply to one repo and read the result:
   `gh workflow run fleet-sync.yml -f dry-run=false -f only-repo=glyph-test`.
   Nothing enforces this step — see `fleet-change-policy.md`, "Not enforced".
3. Read the REST budget, then merge. fleet-preflight and every apply draw on
   one 5000/h core budget — `FLEET_SYNC_PAT` is the owner's account, the local
   `gh` token's — and one full apply costs about 1,850 requests (38 repos, 72
   files, read-back included; measured 2026-10-05). So before this merge, and
   again before step 5's apply, read a real request's `X-RateLimit-Remaining`
   (`gh api -i repos/akira-toriyama/.github`), never `/rate_limit` (glyph's
   `scripts/fleet-preflight.sh`, "API budget", records it lying), and wait for
   the reset when the apply does not fit. On 2026-09-28 (v4.1.1) the apply this
   merge fired, after fleet-preflight and review agents had drained the
   budget, died with `API rate limit exceeded for user ID 92862731` — the
   local token's user — after 7 of 37 repos and moved the rest only when
   re-dispatched after the reset (runs 36414494391, 36417221128); on v6.0.0
   this merge waited for the reset (t-85y9, 2026-10-26). The push onto `main`
   applies fleet-wide by itself (`paths: fleet/**`);
   `gh workflow run fleet-sync.yml -f dry-run=false` is only needed to re-run
   it.
4. Merge any `fleet-sync/*` PRs it opened (see branch protection below) — `canon`
   is the one target whose protection forces the PR path.
5. Run the rewriter **with apply**:
   `gh workflow run glyph-pin-rewrite.yml -f dry-run=false`. It opens one
   `glyph-pin/vX.Y.Z` PR per repo still carrying an unmanaged pin, moving the
   `@tag` and the `version:` under it in the same edit. Below a major they merge
   on their own — the run's last job arms auto-merge and each repo's required
   checks do the rest; read that job's log for the lines that leave a pull to
   a person — `major-left:`, `skipped(no-auto-merge):` and
   `skipped(unprotected):` — and merge those pulls with
   `scripts/merge-when-green.sh`, which squash-merges a pull only once every
   check passed or skipped, or the head reports no checks. Write its list by
   pull number, one `<owner/repo> <pull>` per line
   (`gh pr list --repo <r> --head glyph-pin/vX.Y.Z` names the pull): those log
   lines name the repository, not always the pull. For a major, merge
   glyph-test's pull first, then glyph-monorepo-test's, read that their Release
   runs installed the new tag, fire each harness's e2e at it
   (`glyph-ref=vX.Y.Z`), then list the rest. On v6.0.0 (t-85y9, 2026-10-26)
   glyph-test#131 and glyph-monorepo-test#44 went first and their Release runs
   installed v6.0.0 (finished 09:55–09:56Z); the script then merged the other 19
   while the two e2e runs (40303592990, 40303597047; 09:57–10:02Z) ran, 13 of
   them before either finished. (Its `workflow_dispatch` defaults to dry-run
   for the same reason fleet-sync's does; run it without the flag first if you
   want the list.) A pull request that a later fleet-sync push left `BEHIND`
   catches up on the next scheduled run — the branch is rebuilt on the current
   tip (`scripts/glyph-pin-land.sh`) — so a stale one is a reason to wait for
   the nightly, not to update it by hand.
6. Verify with the audit and the live check below.

## Traps

**fleet-sync's manual trigger defaults to DRY-RUN.** `workflow_dispatch` has
`dry-run: true` by default, so a plain `gh workflow run fleet-sync.yml` reports
`needs-sync:` / `would-set-secrets:` for every repo, exits **success**, and
changes nothing. The default is correct — a safety for a fleet-wide blind write —
and two mechanisms now keep its green from being misread: a dry run's job summary
is headed **`DRY-RUN — NOTHING WAS DISTRIBUTED`**, and an apply run does not end
at "sent" — a read-back step re-fetches every managed file from every repo and
fails on any that is stale (an open `fleet-sync/*` PR carrying the canonical
bytes is the one accepted resting state). A write failure also fails the run
outright, so "green run, zero effect" can no longer read like "already up to
date". Pass `-f dry-run=false`. Scheduled runs apply automatically.

**Branch-protected repos get a PR, not a push.** fleet-sync tries a direct commit
first and falls back to opening `fleet-sync/<file>` branches when protection
rejects it (`direct commit rejected for … — using a PR` in the log). Those PRs sit
unmerged, so the repo stays on the old pin while every other repo moves. canon
was the only one on 2026-07-20; check for others after every sync.

**Grepping for pins is easy to get wrong, in both directions.** Every glyph
reusable ships a *commented* caller stub (`#   uses: …/lint.yml@vX.Y.Z`) whose
version is a placeholder on purpose — a tag is cut on an already-frozen tree,
so a version written into a comment is stale on arrival. glyph's
`TestCallerStubsCarryNoConcreteVersion` fails a concrete version in a stub, and
`TestNaiveGrepSeesNoPinInTheReusables` runs a version grep
(`uses:…@v[0-9][0-9.]*`) over the reusables with comments left in and requires
it to find nothing: for a version grep the placeholder closes the trap at the
source (unfiltered over glyph's `.github/workflows/*.yml` it matched only the
two real callers, `commit-lint.yml` and `version-preview.yml`, at glyph
46909b3 on 2026-11-03). The trap stays open two ways. A consumer that copied a
stub above its real `uses:` line carries the comment with whatever version it
was copied at (`tests/glyph-pin-scan.test.sh`, "commented example pin
ignored", is that shape), and a `head -1` grep reads it instead of the real
line. And a grep that accepts any ref (`@[^[:space:]]+`) reads `vX.Y.Z` itself
as drift — the audit's scanner, `scripts/glyph-pin-scan.sh`, accepts any ref
so it can classify a branch or SHA pin, and skips comment lines for this
reason. Filter `^\s*#` out and anchor on `uses:`. This is why the audit is a
workflow — see `glyph-pin-audit.yml`.

**The rewriter refuses some pins, on purpose.** An `actions/install@` step that
passes **no** `version:`, or one that **computes** it, is reported and left alone:
inserting the input is a structural edit and freezing an expression someone wrote
deliberately is a silent behaviour change. Those are the two states the audit
calls `version-missing` / `version-unreadable`, and they stay red until a human
decides. A `::warning::` in the rewriter's log names the file.

**And `version:` cannot be grepped at all.** It is a generic input name — taplo,
`setup-*` and half the fleet's third-party steps take one — so the only thing that
makes an occurrence a glyph pin is the *step* it sits in. That needs block
structure, which is why the audit's reader is an extracted, table-tested script
(`scripts/glyph-pin-scan.sh`, `tests/glyph-pin-scan.test.sh`) rather than another
line of grep. It reports an install step whose version it *cannot* read as drift
too: an unverifiable pin and a correct pin must not look alike.

## Verifying — actually run it

Do not conclude a rollout worked by reading diffs.

**Machine check.** `glyph-pin-audit.yml` runs daily and on any canonical-pin
change, and fails while any repo's real `uses:` — or the `version:` its install
step passes — disagrees with `fleet/commit-lint.yml`. Run it on demand with
`gh workflow run glyph-pin-audit.yml`. If it is green, the fleet is level.

Green means level, not *finished*: the audit only sees `.github/**.yml`, so a
glyph reference kept anywhere else is still invisible to it.

**Live check, in `glyph-test`.** That repo exists to fire live ammunition — use
it. Push a branch whose commit deliberately violates the new rule, open a PR, and
watch the real `commit-lint` job reach the verdict; then fix the commit and watch
it pass. Both halves matter: a rule that rejects everything is as broken as one
that rejects nothing. For the removal-declaration rule (CONTRIBUTING: a `:fire:`
that takes away something another repo or a user can reference carries `!`):

```
:fire:(presets) prune a preset that nobody should be able to remove silently
  -> lint / lint  FAIL   matches none of the configured patterns

:fire:(presets)! prune a preset that nobody should be able to remove silently
  -> lint / lint  PASS
```

`glyph-test` dropped its v1-acceptance window on 2026-09-25 (glyph-test #94),
so both halves fire there exactly as shown; before that the sigil-less half
only warned there, and a windowless repo (`glyph-monorepo-test`,
`zmk-hid-host`) was needed for the FAIL half.

Close the PR without merging.

**Before touching anything, `git fetch`.** A stale local checkout will happily
show an unmerged branch that merged hours ago, and every conclusion drawn from it
is wrong. On 2026-07-20 a whole analysis was built on a branch whose PR was
already merged and whose remote branch was deleted.
