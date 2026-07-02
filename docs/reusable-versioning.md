# Versioning the shared reusables

The reusable workflows in this repo (`commit-lint`, `taplo`, `release`,
`update-tap`, `swift-format`) are consumed by every owned repo via
`uses: akira-toriyama/.github/.github/workflows/<name>.yml@<ref>`. This is the
ref policy.

> `sync-task-status` RETIRED from this repo (2026-07-02): it ships with furrow
> itself (`akira-toriyama/furrow/.github/workflows/sync-task-status.yml`) and is
> pinned to a **concrete furrow release tag** (e.g. `@v0.5.0`), NOT a moving
> `v1` — the workflow installs the furrow release binary of the same version,
> so workflow and binary cannot skew, and moving tags would collide with
> GoReleaser's semver tag space. The old `@v1` tag here still serves stragglers
> until fleet-sync repoints them; do not move it.

## The scheme — moving `v1` + immutable `v1.x.y`

Same model GitHub recommends for actions:

- **`main`** — development. Changes land here via PR; **callers do not track it.**
- **`v1.0.0`, `v1.0.1`, …** — immutable release tags. Never moved or deleted.
- **`v1`** — a **moving major** tag that always points at the latest `v1.x.y`.
  **Callers pin `@v1`** and get non-breaking updates automatically.

Why not `@main`: pinning every caller to `@main` meant every push to a reusable
hit the whole fleet instantly, with no staging and no rollback. `@v1` decouples
"merged to main" from "released to callers" — you move `v1` when you're ready.

## Cutting a release (moving `v1`)

After the change is on `main` and you've verified it (a caller PR is green):

```sh
# from a clean checkout of this repo, on the commit you want to release
git tag -a v1.2.0 -m "release: <what changed>"   # immutable, never reused
git push origin v1.2.0

git tag -f v1 v1.2.0                              # move the major tag
git push -f origin v1                             # force-push ONLY the moving tag
```

`@v1` callers pick it up on their next run. To **roll back**, move `v1` back to a
known-good `v1.x.y` the same way (`git tag -f v1 v1.1.0 && git push -f origin v1`).

Immutable `vX.Y.Z` tags are never force-pushed or deleted — only `v1` moves.

## Breaking changes → `v2`

A breaking change to a reusable's inputs/secrets/behavior gets a new major:
tag `v2.0.0`, create the moving `v2`, and leave `v1` where it is. Callers opt in
by changing their `uses:` to `@v2` on their own schedule.

## Caller migration

New callers should copy the `@v1` skeleton from each reusable's header comment.
Existing callers across the fleet are still on `@main` and are migrated to `@v1`
in a separate fleet-wide rollout (the fleet-distributed stubs — `commit-lint`,
`taplo`, `task-status` — flip via their canonical copies in [`fleet/`](../fleet/)
+ `fleet-sync`; the per-repo `release`/`update-tap` callers flip per repo).

## Notes

- `main` is branch-protected (PR + `commit-lint / lint` check; admins may bypass).
  Tags are not affected by branch protection — push them directly.
- This repo has no app of its own, so it is **not** released by the `release.yml`
  reusable; the `vX.Y.Z` tags here are created by hand per the steps above.
