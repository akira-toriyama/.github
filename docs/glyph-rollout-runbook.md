# Rolling out a glyph release across the fleet

glyph is shared infrastructure: the commit lint, the semver verdict and the
release notes for **every** repo come out of one binary. A rollout therefore
touches the whole fleet, and every step below exists because it was got wrong at
least once. (No repo count here on purpose — the loops print the live one:
`glyph-pin-audit` logs `auditing N repos` and `fleet-sync` logs `candidate repos: N`.
A hand-kept number in prose only ever disagrees with them.) Machine checks come first; this document only covers what a check cannot.

This document is the **sequence**. Whether you have earned the right to run it —
how far to verify before a change reaches the fleet at all — is
[`fleet-change-policy.md`](fleet-change-policy.md): local → POC → live ammunition
in `glyph-test` → canary → fleet. Step 1 below is the earliest point at which
that staging is already over.

Related: [`reusable-versioning.md`](reusable-versioning.md) (why pins are concrete
tags), [`CONTRIBUTING.md`](../CONTRIBUTING.md) (the convention glyph enforces).

## What is pinned, and by whom

Five things reference glyph, and **no single mechanism moves all five**. The split
is not cosmetic: the first two are one canonical byte-copied everywhere, the last
three are lines inside files each repo owns and writes differently.

| Reference | Where the pin lives | Propagated by |
|---|---|---|
| `workflows/lint.yml` | `fleet/commit-lint.yml` | fleet-sync (copies the file) |
| `workflows/pr-verdict.yml` | `fleet/version-preview.yml` | fleet-sync (copies the file) |
| `workflows/release.yml` | each repo's own release workflow | glyph-pin-rewrite (**opens a PR**) |
| `actions/install` | each repo's release/CI workflows | glyph-pin-rewrite (**opens a PR**) |
| the **binary** that action installs | `with: version:` on that same step | glyph-pin-rewrite (**opens a PR**) |

Those bottom three moved **only by hand** until 2026-07-28 — one pull request per
repo per glyph release, 22 references across 14 repos on the v0.11.2 rollout, with
the audit red for the four days it took. `glyph-pin-rewrite.yml` opens those pull
requests now; **merging them is still yours**, and until they merge the audit is
correctly red.

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

## The sequence

1. Merge the glyph PR, tag, and confirm the release actually published:
   `gh release view vX.Y.Z --json isDraft,assets` — assets must be non-zero and
   `isDraft` false. Pins resolve to a tag, but `actions/install` downloads
   **release assets**; a draft or asset-less release fails every consumer at once.
2. Bump `fleet/commit-lint.yml` and `fleet/version-preview.yml` in one PR. Merge.
3. Run fleet-sync **with apply**: `gh workflow run fleet-sync.yml -f dry-run=false`.
4. Merge any `fleet-sync/*` PRs it opened (see branch protection below).
5. Run the rewriter **with apply**:
   `gh workflow run glyph-pin-rewrite.yml -f dry-run=false`. It opens one
   `glyph-pin/vX.Y.Z` PR per repo still carrying an unmanaged pin, moving the
   `@tag` and the `version:` under it in the same edit. Merge them. (Its
   `workflow_dispatch` defaults to dry-run for the same reason fleet-sync's does;
   run it without the flag first if you want the list.)
6. Verify with the audit and the live check below.

## Traps

**fleet-sync's manual trigger defaults to DRY-RUN.** `workflow_dispatch` has
`dry-run: true` by default, so a plain `gh workflow run fleet-sync.yml` reports
`needs-sync:` / `would-set-secrets:` for every repo, exits **success**, and
changes nothing. The default is correct — a safety for a fleet-wide blind write — but "green run, zero effect" reads exactly
like "already up to date".
Pass `-f dry-run=false`. Scheduled runs apply automatically.

**Branch-protected repos get a PR, not a push.** fleet-sync tries a direct commit
first and falls back to opening `fleet-sync/<file>` branches when protection
rejects it (`direct commit rejected for … — using a PR` in the log). Those PRs sit
unmerged, so the repo stays on the old pin while every other repo moves. canon
was the only one on 2026-07-20; check for others after every sync.

**Grepping for pins is easy to get wrong, in both directions.** Every glyph
reusable ships a *commented* caller stub (`#   uses: …/lint.yml@v0.4.0`) that is
permanently stale. A naive grep reports glyph itself as drifted forever; a
`head -1` grep reads the comment instead of the real `uses:` line and reports the
wrong version everywhere. Filter `^\s*#` out and anchor on `uses:`. This is why
the audit is a workflow — see `glyph-pin-audit.yml`.

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
that rejects nothing. For the removal-declaration rule that was:

```
:fire: prune a preset that nobody should be able to remove silently
  -> lint / lint  FAIL   rule=undeclared-removal

:fire: prune a preset that nobody should be able to remove silently

NON-BREAKING: the preset was internal to this sandbox and never exported
  -> lint / lint  PASS
```

Close the PR without merging.

**Before touching anything, `git fetch`.** A stale local checkout will happily
show an unmerged branch that merged hours ago, and every conclusion drawn from it
is wrong. On 2026-07-20 a whole analysis was built on a branch whose PR was
already merged and whose remote branch was deleted.

## Regression: a line break was worth a major release

`Parse` matched `BREAKING CHANGE:` on any body line starting with it, so prose
that merely **wrapped** onto the phrase declared a breaking change. The commit
introducing the removal rule wrapped exactly that way and classified itself as
breaking — the next release would have been v1.0.0 instead of v0.10.0.

Fixed in glyph v0.10.0: footers are read only in trailer position (opening a
block, or stacked under another trailer). Two habits follow. When a commit body
discusses breaking changes, keep the phrase off the start of a line. And when a
release verdict surprises you, ask `glyph bump --range … --json` for its
`reason` — it names the commit it blamed, which is faster than reading bodies.
