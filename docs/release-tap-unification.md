# Spike: glance/chord release + tap unification

A decision record for whether `glance` and `chord` — historically running their
own release + Homebrew-tap workflows instead of the shared reusables — should
converge onto [`release.yml`](../.github/workflows/release.yml) and
[`update-tap.yml`](../.github/workflows/update-tap.yml). **No blind merge:** a
load-bearing divergence is documented and kept, not erased.

## Current state

| Repo | release | update-tap | Notes |
|---|---|---|---|
| facet / halo / perch / wand | caller | caller | the norm |
| **chord** | **caller** | **caller** | already converged (PRs #90 / #91) |
| **glance** | custom | custom | release stays custom; tap migrating (t-jd81) |
| **eventfx** | custom | custom | same custom bumper as glance (t-jd81 follow-up) |
| jig | — | — | repo removed |

So the spike's original premise ("glance **and chord** deliberately differ") is
**stale for chord**: chord migrated to thin callers of both reusables. The live
question is glance — and, found while executing t-jd81, **eventfx**, whose
`update-tap.yml` is the same custom bumper with the name swapped (same
`[released]` + draft guard, same latest-fetch, same `2+2`, same
`eventfx-release-bot`, same missing-token no-op). Everything this record
concludes about glance's tap applies to it unchanged.

## chord — already unified (no action)

Both chord workflows are thin `uses:` callers passing only documented inputs
(`app: Chord`, `smoke-cmd: config --validate`, install notes; `formula: chord`).
Every named "intentional divergence" of the old chord workflows was incidental
and either **subsumed** by the shared logic (latest-fetch is the shared bumper's
fallback branch; the post-sed grep asserts cover the same failure class as the
old `2+2` diff-shape check) or **deliberately dropped** as cosmetic
(`[released]`→`[published]`, `chord-release-bot`→`github-actions[bot]`).
Convergence lost nothing functional and gained pull-rebase robustness + safer
first-only `sha256` targeting.

The only concrete fallout is a **docs bug**: the reusables' header comments still
list chord (and the removed jig) among repos that "deliberately differ … are NOT
callers." Corrected in this change.

## glance — keep the release separate; migrate the tap

### Release: **keep separate** (load-bearing divergence)

The shared `release.yml` is hardwired for **GUI `.app` bundles**: `package.sh`
builds `<App>.app`, `ditto`-zips it to `<App>.zip`, and the optional smoke runs
`./<App>.app/Contents/MacOS/<bin> --validate`. **glance is a bare CLI
executable** — `build.sh` emits `bin/glance`, the release attaches the raw binary
plus a `glance.sha256` sidecar, and the Homebrew formula builds from the source
tarball (it never consumes the binary asset). The artifact model differs at the
core, not the edges:

- build script (`build.sh` vs `package.sh`) and output layout (`bin/` vs `.app`),
- asset set (raw binary + `.sha256` vs a single `.app.zip`),
- no `.app` bundle path for the shared smoke to validate against.

Forcing glance onto the shared reusable would require a build-output-shape switch
(`artifact-kind: app|binary`, a `build-script` knob, skip-zip, skip-smoke) that
contorts a reusable whose entire identity is "build the `.app` and zip it" — for
a single consumer. That is exactly the divergence the "no blind merge" rule
protects. **Recommendation: keep `glance/release.yml` custom.**

### Tap: **unify-feasible** (follow-up)

The opposite holds for the tap. The shared `update-tap.yml` is a **robustness
superset** of glance's custom bumper (timeout, pull-rebase with clean abort,
first-match `sha256` scoping, stale-`revision` drop, idempotency + post-sed
asserts). glance's flagged divergences are incidental:

- `[released]` + `draft == false` vs `[published]` — a caller-level trigger
  choice; expressible in glance's caller stub. `[released]` is the *stricter*
  of the two (it excludes prereleases, so a "Set as a pre-release" tick in the
  publish UI can't land a prerelease in the stable tap), and it does fire on a
  rolling-draft publish. Keep it in the stub rather than flattening to the
  fleet's `[published]`. The `draft == false` guard is dead and can go: Actions
  does not deliver release events for drafts at all.
- `glance-release-bot` identity — cosmetic git author string (auth is the PAT).
  Not a GitHub account; the tap has no branch protection, ruleset, or CODEOWNERS
  keyed on author, and `github-actions[bot]` bumps from facet/chord already land
  there. Drop it.
- strict `2+2` diff-shape assertion — **drop it, but not for the reason first
  recorded here.** See the corrections below.

**Recommendation: migrate `glance/update-tap.yml` to a thin caller** of the
shared reusable, dropping the bot identity and the `2+2` guard. Tracked as a
follow-up (t-jd81).

#### Corrections (t-jd81, 2026-07-17)

Executing the follow-up falsified two claims made above. Both were load-bearing
for "just drop the guard", so they are corrected here rather than quietly fixed:

1. **"`2+2` is covered by the shared post-sed grep asserts" was false.** The
   asserts only check that the *new* url/sha are present; they cannot see
   collateral damage elsewhere in the file. The `sha256` sed was first-match
   scoped but the **url sed was unanchored, un-repo-qualified and carried `/g`** —
   so bumping a formula with a `resource` block rewrote the third-party tarball's
   url to *this* repo's tag, poisoning the tap with both asserts passing and CI
   green. `2+2` was the only thing catching that class, in glance's bumper and
   nowhere in the shared one. Reproduced under `ubuntu:24.04` / GNU sed 4.9.
   The url sed is now repo-qualified and first-match scoped, which makes the
   class *impossible* rather than *detected* — and only that fix makes the `2+2`
   guard genuinely redundant. This was a latent bug for **every** caller
   (chord / facet / halo / perch / wand), not a glance-migration concern; it had
   never fired only because no formula in the tap carries a `resource` line.
2. **"latest-fetch is *more* fragile than the shared event-tag resolution" was
   backwards.** `gh api …/releases/latest` always resolves the newest *published*
   release, so it is accidentally order-*independent*: publishing an older release
   is a self-correcting no-op. The shared reusable trusts the event payload, which
   is order-*dependent* — publishing an older release moves the tap backward, and
   the latest-fetch fallback rolls it backward too whenever a shipped release gets
   re-drafted (glance's rolling-draft model does exactly that). Nothing guarded
   this. A **no-downgrade guard** (`allow-downgrade` to opt out) now restores, by
   design, the protection glance's bumper had by accident — for all callers.

Rejected outright: a `strict-diff-shape` input. It is incompatible with the
reusable's own stale-`revision` drop — a bump that removes a `revision` line
diffs `2+3`, so the guard would abort a valid bump whose asserts both pass
(measured). A `committer` input was rejected as cosmetic (see above).

## Decision

- **chord** — already unified; this change only corrects the stale header
  comments in the shared reusables.
- **glance release** — keep separate; the CLI-binary vs `.app` artifact model is
  a deliberate, load-bearing divergence.
- **glance tap** — converge to the shared reusable (separate follow-up task).
- **eventfx tap** — same conclusion as glance's, for the same reasons; its
  release model (rolling draft, CLI binary) matches glance's too. Not done here.
- **the shared reusable** — hardening the url sed and adding the no-downgrade
  guard were prerequisites the follow-up surfaced, not part of the original
  spike; they ship ahead of any caller migration because they fix a latent bug
  in the five repos already on the reusable.
