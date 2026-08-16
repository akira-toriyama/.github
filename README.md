# .github

Shared CI (reusable workflows + composite actions) and the default
community-health files for the **akira-toriyama** repos. This front page is **the**
index of what lives here and how to consume it — the ref policy and the design
records point back at these tables rather than restating them; the deeper records
are in [`docs/`](docs/).

## Reusable workflows

Each family repo ships a **thin caller** that `uses:` one of these `workflow_call`
workflows at the moving `@v2` tag. The logic lives here once; callers only wire the
trigger and a few inputs. Copy the caller skeleton from each file's header:

```yaml
uses: akira-toriyama/.github/.github/workflows/<name>.yml@v2
```

| Reusable (`.github/workflows/…`) | What it does | Distribution |
|---|---|---|
| [`taplo.yml`](.github/workflows/taplo.yml) | TOML lint + `fmt --check` (Taplo); a no-op without `*.toml` | fleet-sync |
| [`zizmor.yml`](.github/workflows/zizmor.yml) | Actions-security lint (zizmor) as a PR gate — unpinned actions, template injection, over-broad `permissions:` | fleet-sync (caller + `.github/zizmor.yml` config) |
| [`actionlint.yml`](.github/workflows/actionlint.yml) | Workflow lint (actionlint) as a PR gate — syntax, expression types, shellcheck over `run:` blocks; complements zizmor | hub self-CI today; fleet-sync stub pending the rollout queue (t-ya55) |
| [`swift-format.yml`](.github/workflows/swift-format.yml) | `swift format lint` for Swift packages (macOS, pinned Xcode) | per-repo caller (opt-in, paths-limited) |
| [`design-md-lint.yml`](.github/workflows/design-md-lint.yml) | `DESIGN.md` validator (`@google/design.md`); fails on broken refs | per-repo caller (DESIGN.md repos only) |
| [`go-ci.yml`](.github/workflows/go-ci.yml) | Go build / vet / `test -race` / module-hygiene / golangci-lint v2 | per-repo caller (repo-specific jobs) |
| [`go-vuln.yml`](.github/workflows/go-vuln.yml) | govulncheck (source + `-mode binary`), daily-cron capable | per-repo caller |
| [`go-bite.yml`](.github/workflows/go-bite.yml) | Runs a pull request's new/changed Go tests against the source **before** it; fails the ones that all still pass | per-repo caller |
| [`swift-bite.yml`](.github/workflows/swift-bite.yml) | The same gate for the Swift half of the fleet (XCTest and swift-testing alike) | per-repo caller |
| [`update-tap.yml`](.github/workflows/update-tap.yml) | Bump the Homebrew formula in `homebrew-tap` on release publish | per-repo caller (app repos) |

Retired in `v2.0.0` (frozen `@v1` still serves stragglers, never moved):
`release.yml` — the git-cliff rolling-DRAFT release, superseded by
[glyph](https://github.com/akira-toriyama/glyph)'s `release.yml` reusable — and
`commit-lint.yml` — the shell validator, superseded by glyph's `lint.yml`.

The per-repo `commit-lint` caller (pinning glyph's reusable at a concrete release
tag — workflow + binary ship lockstep from that one tag) and the `taplo` / `zizmor`
callers are identical across repos, so **fleet-sync** distributes them (see
[`fleet/`](fleet/)); `zizmor` also ships its `.github/zizmor.yml` policy alongside
the caller. The rest have per-repo callers you edit in place: the **Go** callers
keep repo-specific jobs (fuzz / smoke / drift guards) alongside the `uses:` job;
`swift-format` / `design-md-lint` are opt-in and paths-limited; `update-tap`
carries the app name.

### Adopting Go CI in a new Go repo

1. `.github/workflows/build.yml` — a `ci:` job that `uses: …/go-ci.yml@v2` plus any
   repo-specific jobs. Copy the skeleton from [`go-ci.yml`](.github/workflows/go-ci.yml)'s
   header; mind the `go-version` / `go-version-file` / `gotoolchain` footgun noted there.
2. `.github/workflows/govulncheck.yml` — a `scan:` job that `uses: …/go-vuln.yml@v2`
   with `binary-path: ./cmd/<bin>` and a daily `schedule` cron.
3. `.github/workflows/build.yml` — a `bite:` job that `uses: …/go-bite.yml@v2`
   beside the `ci:` job, so a test that would have passed without the change it
   accompanies cannot be merged as proof of that change. See
   [`go-bite.md`](docs/go-bite.md).
4. Third-party actions in your own repo-specific jobs stay SHA-pinned with a
   `# vX.Y.Z` comment (Dependabot follows it); the shared core is pinned here once.

## Composite actions

| Action | What it does |
|---|---|
| [`actions/swift-build`](actions/swift-build/action.yml) | Build + test a Swift package on the pinned latest-stable Xcode (`build-cmd`, `run-tests` inputs) |
| [`actions/go-bite`](actions/go-bite/action.yml) | The go-bite gate as a step, for a caller that already has a Go job (the reusable above wraps it) |
| [`actions/swift-bite`](actions/swift-bite/action.yml) | The swift-bite gate as a step (the reusable above wraps it) |
| [`actions/bump-formula`](actions/bump-formula/action.yml) | Move a Homebrew formula to a new tag + source sha256 in place. The pure file-mutation half of `update-tap.yml`, extracted so it can be table-tested; a backward move is refused unless `allow-downgrade` |

```yaml
uses: akira-toriyama/.github/actions/swift-build@v2
```

## fleet-sync — the standard-file distributor

[`fleet-sync.yml`](.github/workflows/fleet-sync.yml) keeps a set of **standard
files** (and the secrets they need) present in every owned, non-fork, non-archived
repo; new repos are onboarded automatically (the repo list is fetched at run time).
Edit the canonical copy in [`fleet/`](fleet/) — never a per-repo copy, which the
next run overwrites. Mechanism, secrets, and PAT rotation: [`fleet/README.md`](fleet/README.md).

## glyph-pin-rewrite — the other fleet writer

fleet-sync distributes **whole files**, which works only where every repo may
carry the identical one. Three of the five things that reference glyph are lines
inside files each repo owns and writes differently — a repo's own release
workflow, `actions/install@`, and the `version:` binary pin under it — so
`fleet-sync` cannot reach them, and refuses those dests by name.
[`glyph-pin-rewrite.yml`](.github/workflows/glyph-pin-rewrite.yml) moves those
lines instead: it rewrites **only** the pin lines, in whatever file they are in,
and opens one `glyph-pin/vX.Y.Z` pull request per repo. The confinement is proved
rather than intended — [`scripts/glyph-pin-rewrite.sh`](scripts/glyph-pin-rewrite.sh)
writes nothing at all if any other line moves. Merging the pull requests stays
manual. Sequence: [`docs/glyph-rollout-runbook.md`](docs/glyph-rollout-runbook.md).

## Versioning the reusables

Callers pin the **moving `@v2`** tag; merging to `main` does not reach them until
you move `v2` onto the release commit. Immutable `v2.x.y` tags are never moved
(`v1` is frozen at `v1.5.0` since the `v2.0.0` retirements). Full ref policy + how
to cut a release: [`docs/reusable-versioning.md`](docs/reusable-versioning.md).

## Community-health defaults

This repo is GitHub's [account-level default community-health](https://docs.github.com/en/communities/setting-up-your-project-for-healthy-contributions/creating-a-default-community-health-file)
source: a file here applies to **every** `akira-toriyama` repo that doesn't ship
its own. Provided: [`SECURITY.md`](SECURITY.md) (private vuln reporting),
[`SUPPORT.md`](SUPPORT.md) (where to get help), the issue templates in
[`.github/ISSUE_TEMPLATE/`](.github/ISSUE_TEMPLATE), and
[`pull_request_template.md`](.github/pull_request_template.md).

**Intentionally omitted** (recorded so their absence reads as a decision, not a
gap): `CODE_OF_CONDUCT.md` and `GOVERNANCE.md` — ceremonial for a solo author; and
`FUNDING.yml` — no sponsorship is sought. Adding a one-line `FUNDING.yml` here is
all it takes to surface a Sponsor button fleet-wide, should that ever change.

## Design records — [`docs/`](docs/)

- [`reusable-versioning.md`](docs/reusable-versioning.md) — the moving-`v2` / immutable-`v2.x.y` ref policy and how to cut a release.
- [`action-pinning-policy.md`](docs/action-pinning-policy.md) — how `uses:` refs are pinned (first-party tag / third-party SHA / self-owned tag) and why.
- [`repo-settings.md`](docs/repo-settings.md) — fleet-wide repo settings applied out-of-band by [`scripts/apply-repo-settings.sh`](scripts/apply-repo-settings.sh).
- [`immutable-releases-hardening.md`](docs/immutable-releases-hardening.md) — why the retired `release.yml` was deadlock-hardened for GitHub immutable releases (historical; glyph's release reusable inherits the discipline).
- [`release-tap-unification.md`](docs/release-tap-unification.md) — whether `glance` / `chord` converge onto the shared release / tap reusables (historical; the fleet has since converged onto glyph's release reusable).
- [`swift-format-adoption.md`](docs/swift-format-adoption.md) — the house procedure for turning the `swift-format` gate green in a new Swift repo.
- [`go-bite.md`](docs/go-bite.md) — why a test that passes without its own fix is refused, what the gate does and does not judge, and when opting out is honest.
- [`jscpd-adoption.md`](docs/jscpd-adoption.md) — jscpd stays an on-demand duplication-measuring tool, never a CI gate: the pinned command, the load-bearing ignore list, and the fleet measurements behind the call.
- [`swift-bite.md`](docs/swift-bite.md) — the same gate for Swift, and the measured `swift test` semantics (filter dialect, verdict lines, the empty-match exit 0) the design rests on.
- [`doc-consistency-policy.md`](docs/doc-consistency-policy.md) — the fleet-wide rule that docs stay code-first, un-duplicated, and not translated in place (no stored `README.ja.md`), plus the language matrix (public → English, private → the author's language). furrow is the reference implementation.
- [`fleet-change-policy.md`](docs/fleet-change-policy.md) — how far to verify before a change here reaches every repo (local → POC → live ammunition in `glyph-test` → canary → fleet), and an honest list of which of those stages a machine enforces and which it does not.
- [`glyph-rollout-runbook.md`](docs/glyph-rollout-runbook.md) — the procedure for levelling the fleet on a new glyph release, including the binary `version:` pin that no `uses:`-shaped check could see until `glyph-pin-audit` grew one.

The commit convention — the single source of truth for every repo — lives in
[`CONTRIBUTING.md`](CONTRIBUTING.md).
