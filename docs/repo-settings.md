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
| Dependabot alerts | `PUT /repos/{R}/vulnerability-alerts` |
| Dependabot security updates | `PUT /repos/{R}/automated-security-fixes` |

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
- `WITH_IMMUTABLE=1` — enable immutable releases on the release repos.
  **Deferred** — see below.

## Usage

```sh
./scripts/apply-repo-settings.sh                      # DRY RUN (report only)
APPLY=1 ./scripts/apply-repo-settings.sh              # apply the safe baseline
APPLY=1 WITH_TOKEN_FLIP=1 ./scripts/apply-repo-settings.sh
APPLY=1 WITH_PROTECTION=1 PROTECT_REPOS="chord facet glance halo perch sill swift-toml-edit wand" \
  ./scripts/apply-repo-settings.sh
ONLY=facet APPLY=1 ./scripts/apply-repo-settings.sh   # one repo
```

New repos are picked up automatically (the repo list is fetched at run time).

## Immutable releases — deferred

Compatible with the rolling-DRAFT flow in normal operation (immutability is
conferred at *publish*; drafts stay mutable). But an adversarial review found a
reachable footgun: if a *published* immutable release is ever deleted, its tag is
**permanently** burned, yet `release.yml`'s git-cliff version-compute (tag-based)
would recompute that version, auto-create a draft, and the manual Publish would be
hard-blocked. The stale-draft cleanup also collides with delete-protection
(cli/cli#9367). Harden `release.yml` (track published versions independent of
deletable tags; make stale-draft cleanup immutable-aware) before enabling, or run
strictly under a "never delete a published release" discipline.
