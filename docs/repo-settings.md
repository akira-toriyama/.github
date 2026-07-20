# Recommended repo settings (fleet-wide)

`fleet-sync` distributes *files*; these are *repo settings*, so they are applied
out-of-band by [`scripts/apply-repo-settings.sh`](../scripts/apply-repo-settings.sh).
The recipe is the one proven on `.github` (t-s7me) and rolled out fleet-wide (t-tvzh).

## What it sets

Safe baseline (always, idempotent):

| Setting | API |
|---|---|
| auto-delete head branch on merge | `PATCH /repos/{R}` `delete_branch_on_merge=true` |
| Private Vulnerability Reporting (public repos) | `PUT /repos/{R}/private-vulnerability-reporting` |
| Code scanning default setup — CodeQL `actions` (public repos) | `PATCH /repos/{R}/code-scanning/default-setup` `state=configured` `languages=[actions]` |
| Dependabot alerts | `PUT /repos/{R}/vulnerability-alerts` |
| Dependabot security updates | `PUT /repos/{R}/automated-security-fixes` |

**Code scanning is scoped to `actions` on purpose.** That is the no-build CodeQL
analysis that machine-detects the script-injection / over-broad-`permissions:`
patterns we otherwise audit by hand — highest value on the hub's ~1,000 lines of
YAML-embedded bash. Omitting `languages` would auto-enable **every** language the
repo detects (`swift`/`go`/`c-cpp`/`ruby`/…), i.e. heavy compile jobs on every PR —
a separate per-repo decision, not this always-on baseline. The GET returns the
detectable languages even when `not-configured`, so the step guards on it: repos
with no workflow (`actions` not detected) are skipped, an already-`actions` config
is a no-op, a repo configured for *other* languages gets `actions` **added**
(union, never clobbered), and a GET that fails transiently warns and skips rather
than misreporting "no actions". Because the PATCH kicks off an async validation
run, re-running the script back-to-back (before state flips to `configured`) can
transiently log a `FAILED` code-scanning line; the next run reconciles it.

Opt-in (need per-repo judgement, hence flags):

- `WITH_TOKEN_FLIP=1` — default workflow `GITHUB_TOKEN` → read-only + no PR approvals.
  Only safe where every write-needing job declares its own `permissions:` block.
  `akira-toriyama` and `dotfiles` (the only write-default repos) were audited and
  cleared; `SKIP_TOKEN_FLIP` lists any repo to hold back.
- `WITH_PROTECTION=1` — make `lint / lint` a required check (admin bypass:
  `enforce_admins:false`). Already-protected repos are **PATCH**ed (only the
  status-check contexts change, preserving `strict`/force-push/reviews); unprotected
  repos get a fresh **PUT** matching the `.github` template. Repos whose *ruleset*
  already requires it (e.g. `canon`) are skipped. `PROTECT_REPOS` is an allowlist so
  the merge-blocking check stays on the intended app repos, not every repo that
  gained a commit-lint caller via a fleet-sync gap-fill.
- `WITH_IMMUTABLE=1` — enable immutable releases on the release repos
  (`RELEASE_REPOS`). Now safe: `release.yml` was hardened first — see below.
- `WITH_CODEQL_GO=1` — add CodeQL **`go`** (compiled) analysis on the Go repos
  (`GO_REPOS`, default `cifail pare furrow glyph`). The list is hand-kept because
  the CI cost is a per-repo call — **when creating a new Go repo, decide and add
  it there** (nothing auto-detects the gap; glyph slipped through until t-tndq).
  It detects code patterns — SQL
  injection, path traversal, tampering — that `govulncheck` (reachable known-CVEs)
  does not, so the two are **complementary**. Unlike the no-build `actions`
  baseline, `go` runs a **build every PR**, hence opt-in + allowlisted (the same
  CI-cost axis on which the compiled languages are kept out of the always-on
  baseline). `go` is **union**ed into the language set — it never clobbers
  `actions`. A repo not yet code-scanning-configured is **deferred**: the `actions`
  baseline PATCH is async, so `go` is added on the next run rather than risking a
  same-run clobber of the just-set baseline. If the default query suite is noisy on
  a repo, narrow it there (`query_suite=extended`/filters) — a per-repo follow-up,
  not baked in here.

## Usage

```sh
./scripts/apply-repo-settings.sh                      # DRY RUN (report only)
APPLY=1 ./scripts/apply-repo-settings.sh              # apply the safe baseline
APPLY=1 WITH_TOKEN_FLIP=1 ./scripts/apply-repo-settings.sh
APPLY=1 WITH_PROTECTION=1 PROTECT_REPOS="chord facet glance halo perch sill swift-toml-edit wand" \
  ./scripts/apply-repo-settings.sh
APPLY=1 WITH_CODEQL_GO=1 ./scripts/apply-repo-settings.sh   # CodeQL go on GO_REPOS
ONLY=facet APPLY=1 ./scripts/apply-repo-settings.sh   # one repo
```

New repos are picked up automatically (the repo list is fetched at run time).

## Immutable releases — enabled (hardened)

Compatible with the rolling-DRAFT flow: immutability is conferred at *publish*, so
drafts stay mutable. An adversarial review found a reachable footgun — if a
*published* immutable release is ever deleted, its tag is **permanently** burned,
yet a tag-based version-compute would recompute that version, auto-create a draft,
and the manual Publish would be hard-blocked; the stale-draft cleanup also collided
with delete-protection (cli/cli#9367). `release.yml` was hardened before enabling:
the next version must be strictly greater than the latest *published* release (fail
loud otherwise), and stale-draft cleanup deletes drafts **by release id**, never by
tag name. Full rationale: [`immutable-releases-hardening.md`](immutable-releases-hardening.md)
(that reusable is retired since `v2.0.0` — glyph's release reusable keeps the same guards).

**Discipline (still required):** never delete a published immutable release or its
tag. The full "delete release *and* tag" case leaves no trace in either `git tag`
or the releases API, so the guard can't auto-detect it — if it ever happens, that
version is permanently burned; bump past it manually. Scope is `RELEASE_REPOS`
(`chord facet halo perch wand`); `glance` runs a custom release flow and is **not**
covered (separate follow-up).
