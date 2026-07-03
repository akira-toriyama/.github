# .github

Shared CI / default community files for akira-toriyama repos.

## Reusable workflows

Each family repo ships a **thin caller** that `uses:` one of these `workflow_call`
workflows at `@v1`. The logic lives here once; callers only wire the trigger and a
few inputs. See each file's header for the copy-paste caller skeleton.

| Reusable (`.github/workflows/…`) | What it does | Distributed by |
|---|---|---|
| [`commit-lint.yml`](.github/workflows/commit-lint.yml) | gitmoji + Conventional Commits validator on every PR | fleet-sync (caller is byte-identical) |
| [`taplo.yml`](.github/workflows/taplo.yml) | TOML format check (no-op without `*.toml`) | fleet-sync |
| [`go-ci.yml`](.github/workflows/go-ci.yml) | Go build / vet / `test -race` / module-hygiene / golangci-lint v2 | per-repo caller (repo-specific jobs) |
| [`go-vuln.yml`](.github/workflows/go-vuln.yml) | govulncheck (source + `-mode binary`), daily-cron capable | per-repo caller |

`commit-lint` / `taplo` callers are identical across repos, so fleet-sync
distributes them (see [`fleet/`](fleet/)). The **Go** callers are NOT
fleet-synced: each repo keeps its own repo-specific jobs (fuzz targets, smoke
tests, schema/drift guards) alongside the `uses:` job, so the caller differs per
repo. Edit those callers in place.

### Adopting Go CI in a new Go repo

1. `.github/workflows/build.yml` — a `ci:` job that `uses: …/go-ci.yml@v1` plus any
   repo-specific jobs. Copy the skeleton from [`go-ci.yml`](.github/workflows/go-ci.yml)'s
   header; mind the `go-version` / `go-version-file` / `gotoolchain` footgun noted there.
2. `.github/workflows/govulncheck.yml` — a `scan:` job that `uses: …/go-vuln.yml@v1`
   with `binary-path: ./cmd/<bin>` and a daily `schedule` cron.
3. Third-party actions in your own repo-specific jobs stay SHA-pinned with a
   `# vX.Y.Z` comment (Dependabot follows it); the shared core is pinned here once.
