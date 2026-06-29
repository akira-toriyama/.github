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
| **glance** | custom | custom | the only remaining divergence |
| jig | — | — | repo removed |

So the spike's original premise ("glance **and chord** deliberately differ") is
**stale for chord**: chord migrated to thin callers of both reusables. The live
question is glance only.

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

The opposite holds for the tap. The shared `update-tap.yml` is a strict
**robustness superset** of glance's custom bumper (timeout, pull-rebase with
clean abort, first-match `sha256` scoping, stale-`revision` drop, idempotency +
post-sed asserts). glance's flagged divergences are incidental:

- `[released]` + `draft == false` vs `[published]` — a caller-level trigger
  choice; expressible in glance's caller stub.
- latest-fetch (`gh api …/releases/latest`) — *more* fragile than the shared
  event-tag resolution (which already falls back to latest).
- `glance-release-bot` identity — cosmetic git author string (auth is the PAT).
- strict `2+2` diff-shape assertion — covered by the shared post-sed grep asserts.

**Recommendation: migrate `glance/update-tap.yml` to a thin caller** of the
shared reusable. The bot identity and the `2+2` guard can be preserved by adding
two optional inputs to the shared reusable (`committer`, `strict-diff-shape`), or
simply dropped as covered by the shared asserts. Tracked as a follow-up.

## Decision

- **chord** — already unified; this change only corrects the stale header
  comments in the shared reusables.
- **glance release** — keep separate; the CLI-binary vs `.app` artifact model is
  a deliberate, load-bearing divergence.
- **glance tap** — converge to the shared reusable (separate follow-up task).
