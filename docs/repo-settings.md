# Recommended repo settings (fleet-wide)

`fleet-sync` distributes *files*; these are *repo settings*, so they go through
[`scripts/apply-repo-settings.sh`](../scripts/apply-repo-settings.sh) instead. The
safe baseline is reconciled by machine — [`repo-settings-sync.yml`](../.github/workflows/repo-settings-sync.yml),
daily and on push, in the fleet-sync shape — and the opt-ins are run by hand. The
recipe is the one proven on `.github` (t-s7me) and rolled out fleet-wide (t-tvzh).

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
(union, never clobbered), and a GET that fails is `unreadable:` (see the contract
below) rather than a false "no actions". Because the PATCH kicks off an async
validation run, it is the one write the script does not read back in the same run
(`applied:`, counted as `async=` in the summary, not `landed:`); re-running
back-to-back while that validation is still pending can make the PATCH itself
fail (a `::FAILED::` line), and the next run reconciles it. A repo that shows up
as `async=1` every day is one whose validation keeps failing — look at it.

**Contract for every setting, in both modes** (pinned by
[`tests/apply-repo-settings.test.sh`](../tests/apply-repo-settings.test.sh)):

- A state the script could not *read* is neither compliant nor drifted. It is
  reported as `unreadable:`, never written to, and fails the run — in dry-run and
  in `APPLY=1` alike. Before this, every failed GET read as drift: on 2026-09-24
  a rate-limited token produced 37 repos × 2 false `would:` lines, and an apply
  would have PUT/PATCHed every one of them (t-4ghh). For branch protection the
  same rule means only a 404 is "unprotected"; a fresh PUT over protection the
  run merely failed to read would reset force-push / reviews / strict. A failed
  GET is retried once first, unless the error is a 404 (an answer) or a rate
  limit (not transient at this timescale).
- `landed:` is a read-back: the setting was re-fetched after the write and holds.
  A 2xx whose read-back does not show the change is a `::FAILED::` mutation and a
  non-zero exit — the same honesty fleet-sync applies to files. A read-back that
  itself cannot read is `unreadable:` (the write was sent; nothing is known).
- `ONLY=` naming no repo is a non-zero exit, not a clean canary over zero repos.

Opt-in (need per-repo judgement, hence flags):

- `WITH_TOKEN_FLIP=1` — default workflow `GITHUB_TOKEN` → read-only + no PR approvals.
  Only safe where every write-needing job declares its own `permissions:` block.
  `akira-toriyama` and `dotfiles` (the only write-default repos) were audited and
  cleared; `SKIP_TOKEN_FLIP` lists any repo to hold back.
- `WITH_PROTECTION=1` — make `lint / lint` a required check (admin bypass:
  `enforce_admins:false`), **plus `build` where the default branch HEAD carries a
  check-run named `build`** (t-jvdr). The probe is ground truth, not file
  inference: a required context that no run produces wedges every PR invisibly
  (the t-c51t shape), so the script requires only what the repo demonstrably
  runs — the swift family's hand-added `build` is now distributed, and a new
  app repo gets it on the first run after its first `build` lands on main. A
  transient probe failure warns and requires `lint` alone that run (never a
  silent "no build"); the next run heals. Protection the run cannot read
  (anything but a 404) is `unreadable:` and never overwritten. Already-protected repos are
  **PATCH**ed (only the
  status-check contexts change, preserving `strict`/force-push/reviews); unprotected
  repos get a fresh **PUT** matching the `.github` template. Contexts whose *ruleset*
  already requires them (e.g. `canon`) are skipped. `PROTECT_REPOS` is an allowlist so
  the merge-blocking check stays on the intended app repos, not every repo that
  gained a commit-lint caller via a fleet-sync gap-fill.
  A repo counts as having a caller when its `.github/workflows/commit-lint.yml`
  carries the `uses:` line that [`fleet/commit-lint.yml`](../fleet/commit-lint.yml)
  distributes — read from that file at run time, not restated in the script. If it
  matches **zero** repos the run now fails loudly instead of reporting a clean
  sweep: between #82 and this change the detector still named the hub's own retired
  reusable, so every repo printed `skip(protection)` and nothing was ever applied.
  [`tests/apply-repo-settings.test.sh`](../tests/apply-repo-settings.test.sh) seeds
  its fixture from the canonical, so the next repoint cannot disarm it again.
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
./scripts/apply-repo-settings.sh                      # DRY RUN (report only: exit 0 on drift, non-zero on anything unreadable)
APPLY=1 ./scripts/apply-repo-settings.sh              # apply the safe baseline (what the workflow does)
APPLY=1 WITH_TOKEN_FLIP=1 ./scripts/apply-repo-settings.sh
APPLY=1 WITH_PROTECTION=1 PROTECT_REPOS="chord facet glance halo perch sill swift-toml-edit wand" \
  ./scripts/apply-repo-settings.sh
APPLY=1 WITH_CODEQL_GO=1 ./scripts/apply-repo-settings.sh   # CodeQL go on GO_REPOS
ONLY=facet APPLY=1 ./scripts/apply-repo-settings.sh   # one repo (the canary)
```

New repos are picked up automatically (the repo list is fetched at run time).

## Reconcile (the workflow)

[`repo-settings-sync.yml`](../.github/workflows/repo-settings-sync.yml) runs the
script with `APPLY=1` in the fleet-sync shape: a dispatch defaults to dry-run,
and `-f only-repo=<repo>` is the canary. It passes no `WITH_*` flag, so the
opt-ins stay a hand-run with per-repo judgement.

**Staged (docs/fleet-change-policy.md).** The workflow currently carries
`workflow_dispatch` only. GitHub registers a workflow for dispatch from the
default branch alone (measured 2026-09-25), so a brand-new workflow cannot be
canaried before it is on `main`; the follow-up adds the daily `schedule` and the
`push` trigger once the canary from `main` has landed one repo. Until then the
baseline is applied by dispatch (or by hand, above). After it, a new repo is
level within a day of its creation.

Why the machine applies. The script only ever ran by hand, and every repo
created after the last hand-run was born with the baseline OFF: on 2026-07-26,
10 of 35 repos had Dependabot alerts disabled, 6 of them with real dependency
manifests (t-qsea). t-qsea added a daily dry-run *audit* that went red on drift
and left the apply to a human. That audit was red on 22 of the 29 days to
2026-09-24 — four repos (dotfiles-private, glyph-monorepo-test, kiln,
furrow-test) were born drifted after the one hand-run in that window and stayed
so for up to three weeks (t-4ghh). A red that waits for a human is not acted on
in this fleet. The blast radius of a bad run is the five baseline settings, each
idempotent and each an "on" toggle; rollback is a revert of the workflow.

Canary, from `main`, both halves — knock a baseline setting off on `glyph-test`
by hand, then:

```sh
gh workflow run repo-settings-sync.yml -f dry-run=true  -f only-repo=glyph-test   # expect would:, nothing applied
gh workflow run repo-settings-sync.yml -f dry-run=false -f only-repo=glyph-test   # expect landed:
```

and read the setting back with `gh api` before believing the log.

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
