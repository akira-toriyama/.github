# .github

Shared CI (reusable workflows + a composite action) and the default
community-health files for the **akira-toriyama** repos. This front page indexes
what lives here and how to consume it; the deeper design records are in
[`docs/`](docs/).

## Reusable workflows

Each family repo ships a **thin caller** that `uses:` one of these `workflow_call`
workflows at the moving `@v1` tag. The logic lives here once; callers only wire the
trigger and a few inputs. Copy the caller skeleton from each file's header:

```yaml
uses: akira-toriyama/.github/.github/workflows/<name>.yml@v1
```

| Reusable (`.github/workflows/…`) | What it does | Distribution |
|---|---|---|
| [`commit-lint.yml`](.github/workflows/commit-lint.yml) | gitmoji + Conventional Commits validator on every PR | fleet-sync (caller byte-identical everywhere) |
| [`taplo.yml`](.github/workflows/taplo.yml) | TOML lint + `fmt --check` (Taplo); a no-op without `*.toml` | fleet-sync |
| [`swift-format.yml`](.github/workflows/swift-format.yml) | `swift format lint` for Swift packages (macOS, pinned Xcode) | per-repo caller (opt-in, paths-limited) |
| [`design-md-lint.yml`](.github/workflows/design-md-lint.yml) | `DESIGN.md` validator (`@google/design.md`); fails on broken refs | per-repo caller (DESIGN.md repos only) |
| [`go-ci.yml`](.github/workflows/go-ci.yml) | Go build / vet / `test -race` / module-hygiene / golangci-lint v2 | per-repo caller (repo-specific jobs) |
| [`go-vuln.yml`](.github/workflows/go-vuln.yml) | govulncheck (source + `-mode binary`), daily-cron capable | per-repo caller |
| [`release.yml`](.github/workflows/release.yml) | Rolling-DRAFT GitHub Release from Conventional Commits (git-cliff) | per-repo caller (Swift-app repos) |
| [`update-tap.yml`](.github/workflows/update-tap.yml) | Bump the Homebrew formula in `homebrew-tap` on release publish | per-repo caller (app repos) |

`commit-lint` / `taplo` callers are identical across repos, so **fleet-sync**
distributes them (see [`fleet/`](fleet/)). The rest have per-repo callers you edit
in place: the **Go** callers keep repo-specific jobs (fuzz / smoke / drift guards)
alongside the `uses:` job; `swift-format` / `design-md-lint` are opt-in and
paths-limited; `release` / `update-tap` carry the app name.

### Adopting Go CI in a new Go repo

1. `.github/workflows/build.yml` — a `ci:` job that `uses: …/go-ci.yml@v1` plus any
   repo-specific jobs. Copy the skeleton from [`go-ci.yml`](.github/workflows/go-ci.yml)'s
   header; mind the `go-version` / `go-version-file` / `gotoolchain` footgun noted there.
2. `.github/workflows/govulncheck.yml` — a `scan:` job that `uses: …/go-vuln.yml@v1`
   with `binary-path: ./cmd/<bin>` and a daily `schedule` cron.
3. Third-party actions in your own repo-specific jobs stay SHA-pinned with a
   `# vX.Y.Z` comment (Dependabot follows it); the shared core is pinned here once.

## Composite action

| Action | What it does |
|---|---|
| [`actions/swift-build`](actions/swift-build/action.yml) | Build + test a Swift package on the pinned latest-stable Xcode (`build-cmd`, `run-tests` inputs) |

```yaml
uses: akira-toriyama/.github/actions/swift-build@v1
```

## fleet-sync — the standard-file distributor

[`fleet-sync.yml`](.github/workflows/fleet-sync.yml) keeps a set of **standard
files** (and the secrets they need) present in every owned, non-fork, non-archived
repo; new repos are onboarded automatically (the repo list is fetched at run time).
Edit the canonical copy in [`fleet/`](fleet/) — never a per-repo copy, which the
next run overwrites. Mechanism, secrets, and PAT rotation: [`fleet/README.md`](fleet/README.md).

## Versioning the reusables

Callers pin the **moving `@v1`** tag; merging to `main` does not reach them until
you move `v1` onto the release commit. Immutable `v1.x.y` tags are never moved. Full
ref policy + how to cut a release: [`docs/reusable-versioning.md`](docs/reusable-versioning.md).

## Design records — [`docs/`](docs/)

- [`reusable-versioning.md`](docs/reusable-versioning.md) — the moving-`v1` / immutable-`v1.x.y` ref policy and how to cut a release.
- [`action-pinning-policy.md`](docs/action-pinning-policy.md) — how `uses:` refs are pinned (first-party tag / third-party SHA / self-owned tag) and why.
- [`repo-settings.md`](docs/repo-settings.md) — fleet-wide repo settings applied out-of-band by [`scripts/apply-repo-settings.sh`](scripts/apply-repo-settings.sh).
- [`immutable-releases-hardening.md`](docs/immutable-releases-hardening.md) — why `release.yml` is deadlock-hardened for GitHub immutable releases.
- [`release-tap-unification.md`](docs/release-tap-unification.md) — whether `glance` / `chord` converge onto the shared release / tap reusables (and the divergence kept).
- [`swift-format-adoption.md`](docs/swift-format-adoption.md) — the house procedure for turning the `swift-format` gate green in a new Swift repo.

The commit convention — the single source of truth for every repo — lives in
[`CONTRIBUTING.md`](CONTRIBUTING.md).
