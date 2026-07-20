# Rolling out a glyph release across the fleet

glyph is shared infrastructure: the commit lint, the semver verdict and the
release notes for **every** repo come out of one binary. A rollout therefore
touches ~24 repos, and every step below exists because it was got wrong at least
once. Machine checks come first; this document only covers what a check cannot.

Related: [`reusable-versioning.md`](reusable-versioning.md) (why pins are concrete
tags), [`CONTRIBUTING.md`](../CONTRIBUTING.md) (the convention glyph enforces).

## What is pinned, and by whom

Four things reference glyph. **Only the first two are fleet-managed** — the rest
need per-repo PRs, and forgetting them is the most common miss.

| Reference | Where the pin lives | Propagated by |
|---|---|---|
| `workflows/lint.yml` | `fleet/commit-lint.yml` | fleet-sync |
| `workflows/pr-verdict.yml` | `fleet/version-preview.yml` | fleet-sync |
| `workflows/release.yml` | each repo's `.github/workflows/release.yml` | **per-repo PR** |
| `actions/install` | each repo's release/CI workflows | **per-repo PR** |

`.github` also pins `lint.yml` in its own `self-commit-lint.yml`.

The install action is the sneaky one: a repo can have every *workflow* on the new
tag while still installing an **older binary**, so its CI enforces rules that no
longer match the workflows around it. dotfiles sat exactly like that.

## The sequence

1. Merge the glyph PR, tag, and confirm the release actually published:
   `gh release view vX.Y.Z --json isDraft,assets` — assets must be non-zero and
   `isDraft` false. Pins resolve to a tag, but `actions/install` downloads
   **release assets**; a draft or asset-less release fails every consumer at once.
2. Bump `fleet/commit-lint.yml` and `fleet/version-preview.yml` in one PR. Merge.
3. Run fleet-sync **with apply**: `gh workflow run fleet-sync.yml -f dry-run=false`.
4. Merge any `fleet-sync/*` PRs it opened (see branch protection below).
5. Open per-repo PRs for `release.yml` and `actions/install`.
6. Verify with the audit and the live check below.

## Traps

**fleet-sync's manual trigger defaults to DRY-RUN.** `workflow_dispatch` has
`dry-run: true` by default, so a plain `gh workflow run fleet-sync.yml` reports
`needs-sync:` / `would-set-secrets:` for every repo, exits **success**, and
changes nothing. The default is correct — a 24-repo blind write deserves a
safety — but "green run, zero effect" reads exactly like "already up to date".
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

## Verifying — actually run it

Do not conclude a rollout worked by reading diffs.

**Machine check.** `glyph-pin-audit.yml` runs daily and on any canonical-pin
change, and fails while any repo's real `uses:` disagrees with
`fleet/commit-lint.yml`. Run it on demand with
`gh workflow run glyph-pin-audit.yml`. If it is green, the fleet is level.

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
