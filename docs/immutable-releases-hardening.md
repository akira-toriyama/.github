# Hardening `release.yml` for immutable releases (t-tvzh)

> **Historical (2026-07-20, t-hy5b):** the shared `release.yml` reusable this
> record hardened was retired in `v2.0.0` — the fleet now releases through
> [glyph](https://github.com/akira-toriyama/glyph)'s `release.yml` reusable,
> which inherits the same rolling-draft discipline (published-floor guard,
> delete-drafts-by-id). The retired file remains readable at
> [`v1.5.0`](https://github.com/akira-toriyama/.github/blob/v1.5.0/.github/workflows/release.yml).
> The immutable-release *findings* below (what immutability does, the burned-tag
> deadlock, the discipline) are still true and still load-bearing.

A decision record for the final piece of t-tvzh: enabling GitHub
[immutable releases](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases)
on the release repos. The recommended settings (`t-s7me`/`t-tvzh`) were rolled out
fleet-wide in `.github#46`; immutable releases were **deferred** pending this
hardening because an adversarial audit found a reachable deadlock in the shared
`release.yml` rolling-DRAFT flow.

## What immutable releases actually do (verified)

- Immutability is conferred **at Publish**, not before. **Draft releases stay
  mutable.** So the rolling-DRAFT flow (one draft grown across merges, manually
  Published) is compatible in normal operation.
- A published immutable release's **tag is locked to its commit and cannot be
  deleted while the release exists.**
- If you delete the published release, you *can* then delete the tag — but the
  **tag name can never be reused** (permanent; survives even repo deletion).
- Enabled at repo or org level (default off). REST surface exists:
  `GET/PUT /repos/{owner}/{repo}/immutable-releases` → `{"enabled":…,"enforced_by_owner":…}`.

## The deadlock (why it was deferred)

The rolling-DRAFT flow computes the next version from git history via
`git-cliff --bumped-version`, anchored on the latest **git tag**. The footgun:

1. A published immutable release `vX.Y.Z` exists (tag `vX.Y.Z`).
2. Someone deletes the **release and its tag** → the tag name is permanently burned.
3. `git-cliff` now sees the previous tag and recomputes `vX.Y.Z` as "next".
4. `release.yml` auto-creates a draft `vX.Y.Z`.
5. Manual Publish at `vX.Y.Z` is **hard-blocked forever** — the tag name can't be reused.

A second, independent footgun in the cleanup step: it deleted stale auto-drafts
**by tag name** (`gh release delete <tag>`). Per [cli/cli#9367](https://github.com/cli/cli/issues/9367)
(open), `gh release list` reports a draft's *intended publish tag*, so when a draft
and a published release share that name, `gh release delete <tag>` deletes the
**published** one — which, under immutable releases, starts the deletion → tag-burn
sequence above. The cleanup also did `git push origin :refs/tags/$t`, which would
collide with immutable tag protection.

## Decision: lightweight hardening + enable

Chosen over a persisted version-ledger (heavier: a new `release: published`
workflow + a commit on every publish). The full burned-tag case is only reachable
by a deliberate two-step destructive act on a *published* release, which immutable
releases' own design ("don't delete published things") already discourages. We
harden the workflow against the *workflow-caused* paths and the realistic
accidental ones, and cover the residual deliberate case with a documented
discipline.

### Part A — stale-draft cleanup by release **id** (cli/cli#9367-proof)

In `release.yml`'s "Create or update rolling DRAFT release" step:

- Enumerate releases via REST (`gh api repos/{repo}/releases --paginate`), which
  exposes `id` / `draft` / `tag_name`. (`gh release list --json` has **no id**.)
- Stale auto-draft = `draft==true` **and** `tag_name` matches `^v[0-9]+\.[0-9]+\.[0-9]+$`
  **and** `tag_name != VERSION`. Delete each **by id**: `gh api -X DELETE
  repos/{repo}/releases/{id}`. Never resolves by tag name → can never hit a
  published release.
- If more than one draft has `tag_name == VERSION` (anomalous dup), keep one id and
  delete the rest by id, so the subsequent update resolves unambiguously.
- **Never** touch `draft==false` (published / immutable) releases.
- **Remove** `git push origin :refs/tags/$t` — rolling drafts create no tags, and
  with immutable on it is a tag-burn hazard.
- The current-version draft's update/create still uses `gh release edit/upload/create
  "$VERSION"`; this is safe because Part B guarantees no *published* release shares
  `VERSION` at this point.

### Part B — version-compute floor (deadlock guard)

In the "Compute next version" step, after computing `next`:

- Compute `pub_latest` = highest **published** semver release
  (`gh release list --json tagName,isDraft` → filter `isDraft==false` + semver →
  `sort -V | tail -1`).
- If `pub_latest` is non-empty and `next` is **not strictly greater** than
  `pub_latest` (`sort -V` comparison), **fail loud** (`::error::`) instead of
  creating an unpublishable draft.
- This catches: a tag deleted out-of-band while its published release remains, and
  any `git-cliff`/config regression that produces a non-advancing version.
- ⚠️ It does **not** auto-catch the full burned case (release *and* tag both
  deleted leave no trace in `git tag` *or* `gh release list`). That residual is
  covered by the discipline below — the accepted trade-off of the lightweight option.

### Part C — discipline, documented

- `docs/repo-settings.md`: flip the immutable section from "deferred" to "enabled
  (hardened)" and state the rule: **never delete a published immutable release or
  its tag.** If one is ever deleted, that version is permanently burned — bump past
  it manually; do not let the pipeline recreate it.
- `release.yml` header comment: note the immutable assumptions (drafts mutable,
  cleanup by id, version monotonic vs. published releases, burned-tag avoided by
  discipline).

### Part D — enable (rollout order)

1. Merge the hardened `release.yml` to `main` (touches `.github/workflows/*` → merge
   via SSH squash or web UI; the gh token lacks the `workflow` scope).
2. Move the `v1` tag (per [reusable-versioning.md](reusable-versioning.md)) so
   `@v1` callers pick up the hardened reusable.
3. Verify on `facet` (see Verification).
4. `APPLY=1 WITH_IMMUTABLE=1 ./scripts/apply-repo-settings.sh` for the **5 release
   repos** (`RELEASE_REPOS="chord facet halo perch wand"`); spot-check
   `gh api repos/{R}/immutable-releases` → `enabled=true`.
5. Update `docs/` and the task body.

**Scope:** the 5 reusable-`release.yml` callers only. **`glance` is excluded** — it
runs a custom CLI-binary release flow (a load-bearing divergence, see
[release-tap-unification.md](release-tap-unification.md)) that this hardening does
not touch; immutable on `glance` is a separate follow-up. **No org-level enforcement**
(it would reach `glance` and non-release repos) — per-repo only.

## Verification (manual, inline workflow retained)

- **Dry-run** the version-compute: run a caller (`facet`) with `dry_run=true` and
  read the `Compute next version` log (note: dry-run does not exercise cleanup).
- **Cleanup**: create a throwaway stale draft on `facet`
  (`gh release create v0.0.1-test --draft --notes test`), run the new id-based
  cleanup logic against `facet` with real `gh`, and confirm it deletes **only** the
  scratch draft by id while the live draft (`v7.0.0`) and all published releases are
  untouched; then clean up the scratch draft.
