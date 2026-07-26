# Versioning the shared reusables

The reusable workflows and composite actions in this repo are consumed by every
owned repo via `uses: akira-toriyama/.github/.github/workflows/<name>.yml@<ref>`
(or `…/actions/<name>@<ref>`). **What they are is indexed in
[`README.md`](../README.md)** — this document is only the ref policy, and keeps no
second list to fall out of date (it already had: it named seven reusables when
there were eight, and two composites when there were three).

> `sync-task-status` RETIRED from this repo (2026-07-02): it ships with furrow
> itself (`akira-toriyama/furrow/.github/workflows/sync-task-status.yml`) and is
> pinned to a **concrete furrow release tag**, NOT a moving major — the workflow
> installs the furrow release binary of the same version, so workflow and binary
> cannot skew, and moving tags would collide with GoReleaser's semver tag space.
>
> There are no stragglers left to serve here, and there is no `@v1` fallback for
> this one: `sync-task-status.yml` was last present at `v1.0.2` and is **absent
> from `v1.5.0`**, where the frozen `v1` points. A surviving
> `…/.github/.github/workflows/sync-task-status.yml@v1` pin is therefore already a
> hard "workflow was not found", not a deprecation — repoint it at furrow's tag.

## The scheme — moving `v2` + immutable `v2.x.y`

Same model GitHub recommends for actions:

- **`main`** — development. Changes land here via PR; **callers do not track it.**
- **`v2.0.0`, `v2.0.1`, …** — immutable release tags. Never moved or deleted.
- **`v2`** — a **moving major** tag that always points at the latest `v2.x.y`.
  **Callers pin `@v2`** and get non-breaking updates automatically.

Why not `@main`: pinning every caller to `@main` meant every push to a reusable
hit the whole fleet instantly, with no staging and no rollback. The moving major
decouples "merged to main" from "released to callers" — you move `v2` when
you're ready.

## The `v1` → `v2` cut (2026-07-20, t-hy5b)

`v2.0.0` removed two retired reusables and one orphaned composite from `main`
(the deletion of a public reusable is `:boom:` per the CONTRIBUTING semver
convention, hence the major):

- `release.yml` — git-cliff rolling-DRAFT release; superseded by glyph's
  `release.yml` reusable (fleet migration t-vt8s).
- `commit-lint.yml` — shell commit validator; superseded by glyph's `lint.yml`.
- `actions/next-version-guard` — release.yml's extracted version-decision half;
  nothing else consumed it.

**`v1` is frozen at `v1.5.0` and must never move again.** Anything still on
`@v1` keeps working (immutable behavior, including the retired files) but
receives no further fixes; the fleet was repointed to `@v2` in the t-hy5b sweep,
which also fixed the six `swift-build@main` stragglers (t-mxnm) to `@v2`.

## Cutting a release (moving `v2`)

After the change is on `main` and you've verified it (a caller PR is green):

```sh
# from a clean checkout of this repo, on the commit you want to release
git tag -a v2.1.0 -m "release: <what changed>"   # immutable, never reused
git push origin v2.1.0

git tag -f v2 v2.1.0                              # move the major tag
git push -f origin v2                             # force-push ONLY the moving tag
```

`@v2` callers pick it up on their next run. To **roll back**, move `v2` back to a
known-good `v2.x.y` the same way (`git tag -f v2 v2.0.0 && git push -f origin v2`).

Immutable `vX.Y.Z` tags are never force-pushed or deleted — only `v2` moves.

## Breaking changes → `v3`

A breaking change to a reusable's inputs/secrets/behavior gets a new major:
tag `v3.0.0`, create the moving `v3`, and leave `v2` where it is (frozen, like
`v1` today). Callers opt in by changing their `uses:` to `@v3` on their own
schedule — but this fleet's practice is to sweep every caller in one rollout so
no repo is left on a frozen major receiving no fixes.

## Caller migration

New callers copy the `@v2` skeleton from each reusable's header comment. The
fleet-distributed stubs (`taplo`, `zizmor`) flip majors via their canonical
copies in [`fleet/`](../fleet/) + `fleet-sync`; the per-repo callers
(`update-tap`, `swift-format`, `go-ci`, `go-vuln`, `design-md-lint`,
`swift-build`) flip per repo.

## Notes

- `main` is branch-protected (PR + `commit-lint / lint` check; admins may bypass).
  Tags are not affected by branch protection — push them directly.
- This repo has no app of its own, so no release workflow ever tags it; the
  `vX.Y.Z` tags here are created by hand per the steps above.
