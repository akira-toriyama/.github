# CLAUDE.md — akira-toriyama/.github

This repo is three things at once: (1) the account's **community-health defaults**
(issue / PR templates, `SECURITY.md`) that GitHub applies to every owned repo
lacking its own; (2) the **shared CI** — reusable `workflow_call` workflows plus the
`swift-build` composite action that family repos consume at the moving `@v2` tag;
and (3) the **fleet-sync distribution hub** that keeps a set of standard files (and
the secrets they need) present in every owned repo. [`README.md`](README.md) is the
consumer index.

## Where each topic is documented — read there, don't reinvent

- **How far to verify before rolling a change out** (stage it: local → POC → live ammunition in `glyph-test` → canary → fleet; what is machine-enforced and what is not) → [`docs/fleet-change-policy.md`](docs/fleet-change-policy.md) (account-wide rule).
- **Commit convention** (gitmoji-driven — the leading `:code:` is the type and drives semver; enforced/consumed by glyph) → [`CONTRIBUTING.md`](CONTRIBUTING.md) (single source of truth).
- **Ref policy + cutting a release** (moving `v2`, immutable `v2.x.y`, next major for breaking; `v1` frozen at `v1.5.0`) → [`docs/reusable-versioning.md`](docs/reusable-versioning.md).
- **fleet-sync mechanism + PAT rotation** → [`fleet/README.md`](fleet/README.md).
- **Fleet-wide repo settings** (`apply-repo-settings.sh`) → [`docs/repo-settings.md`](docs/repo-settings.md).
- **Why the retired `release.yml` was shaped as it was** (immutable-release hardening; glyph's release reusable inherits it) → [`docs/immutable-releases-hardening.md`](docs/immutable-releases-hardening.md).

## Invariants — load-bearing, easy to break, not obvious from any single file

- **A change here lands in every repo at once — stage it, don't ship it.** Build
  a POC when a step has never been done before, fire live ammunition in
  `glyph-test`, canary one repo, *then* the fleet. Nothing in CI enforces those
  stages, so say which ones you actually performed and which you skipped. The
  rule, and the honest list of what is and is not machine-enforced, is
  [`docs/fleet-change-policy.md`](docs/fleet-change-policy.md).
- **`.github/workflows/task-status.yml` is maintained BY HAND.** fleet-sync
  EXCLUDEs `.github` (it *is* the hub), so the canonical `fleet/task-status.yml`
  never syncs onto it. Keep this file's caller body — the furrow pin,
  `on` / `permissions` / `secrets` — identical to `fleet/task-status.yml`; only the
  top provenance comment differs. Bump the furrow pin in **both**. Nothing in CI
  guards this — the rule lives only in the two files' comments.
- **Fleet-distributed files: edit only the canonical copy in [`fleet/`](fleet/)**
  (`task-status.yml`, `commit-lint.yml`, `taplo.yml`, `dependabot.yml`,
  `commit-convention.md`). Every per-repo copy is overwritten on the next sync —
  never edit those.
- **Merging to `main` does NOT reach callers.** Callers pin `@v2`; a change ships
  only when you move the `v2` tag onto the release commit
  (`git tag -f v2 <v2.x.y> && git push -f origin v2` — force-push *only* the moving
  tag). Steps: [`docs/reusable-versioning.md`](docs/reusable-versioning.md).
- **`vX.Y.Z` tags here are cut BY HAND** — this repo has no app of its own, so
  no release workflow ever tags it. The immutable `vX.Y.Z` tags are **never** moved
  or deleted, and the frozen `v1` (parked at `v1.5.0` since the `v2.0.0`
  retirements) must not move either; separately, the retired `sync-task-status@v1`
  (that reusable now ships from furrow — its old `@v1` here still serves
  stragglers) must not be moved until fleet-sync repoints them.
- **Verify `run:` blocks under bash, not zsh** — zsh doesn't word-split, so a
  script that passes an interactive zsh test can still break in Actions' bash.
