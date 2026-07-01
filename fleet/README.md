# fleet — repo standardizer

Keeps a set of **standard files** present in every owned, non-fork, non-archived
repo, and distributes the secrets those files need. New repos are onboarded
automatically (the repo list is fetched at run time), so there is never a
"this repo has it / that one doesn't" gap.

It is **general on purpose**: `task-status` is just the first managed file. To
standardize more files across the fleet, drop the canonical copy here and add a
line to `MANIFEST` in [`.github/workflows/fleet-sync.yml`](../.github/workflows/fleet-sync.yml).

## Files

- `task-status.yml` → each repo's `.github/workflows/task-status.yml` (the thin
  caller stub for the [`sync-task-status`](../.github/workflows/sync-task-status.yml)
  reusable).
- `dependabot.yml` → each repo's `.github/dependabot.yml` (keeps github-actions
  deps fresh fleet-wide).
- `commit-lint.yml` → each repo's `.github/workflows/commit-lint.yml` (caller
  stub for the shared [`commit-lint`](../.github/workflows/commit-lint.yml)
  reusable; enforces the commit convention on every PR).
- `taplo.yml` → each repo's `.github/workflows/taplo.yml` (caller stub for the
  shared [`taplo`](../.github/workflows/taplo.yml) reusable; a no-op on repos
  without any `*.toml`).
- `commit-convention.md` → each repo's `docs/commit-convention.md` (a universal
  pointer to the canonical [`CONTRIBUTING.md`](../CONTRIBUTING.md); carries no
  local-hook assumptions, so it fits hook-less repos too).

**Edit these canonical copies, never the per-repo copies** — fleet-sync overwrites
them on the next run.

## How it runs

`fleet-sync.yml` runs daily (and on demand via **Run workflow**). It is **dormant**
until its secrets exist:

| Secret (on this `.github` repo) | What it is |
|---|---|
| `FLEET_SYNC_PAT` | classic PAT with `repo` + `workflow` scopes. `workflow` is **required** to write `.github/workflows/*` in other repos; the default `GITHUB_TOKEN` cannot. |
| `PROJECTS_WRITE_PAT` | fine-grained PAT scoped to the tracker repo (`projects`) with **Contents: Read & write only**, auto-expiring — fanned out to each repo as `PROJECTS_WRITE_PAT`. Replaces the retired furrow-status-bot App master key (t-ke0v): a leak now reaches only the tracker and expires on its own. |

Manual runs **default to dry-run** (log only). Use `only-repo` to target one repo.

## Notes

- **Idempotent**: a file is rewritten only when it differs; secrets are set every run (cheap, overwrite).
- **Security trade-off**: the fanned-out `PROJECTS_WRITE_PAT` is least-privilege
  (tracker `Contents: Read & write` only) and auto-expiring, so its blast radius is
  narrow — a leak reaches only the tracker and stops working on expiry. It is still
  copied into many repos; if that matters more than uniformity, add repos to
  `EXCLUDE` or gate the secret-fan-out on the repo actually carrying the task-status
  stub.
- No GitHub App is involved any more (the furrow-status-bot App master key was
  retired in t-ke0v). Auth is the credential-only PAT above — no App install, no
  server, no token minting.

## Rotating `PROJECTS_WRITE_PAT`

The PAT is copied into every repo's secrets, so rotation matters — but because it is
fine-grained (tracker `Contents:RW` only) and auto-expiring, the blast radius is
small and the deadline is bounded automatically. `projects`'s `pat-expiry-reminder`
workflow auto-files a furrow task when the PAT is within ~30 days of expiry, so this
is never forgotten.

1. **Generate** a new fine-grained PAT: GitHub → Settings → Developer settings →
   Fine-grained tokens → **Generate new token**, scoped to **only**
   `akira-toriyama/projects` with **Contents: Read and write**, and a sensible
   expiry (e.g. 1 year).
2. **Update** the hub secret:
   `gh secret set PROJECTS_WRITE_PAT --repo akira-toriyama/.github` (paste the token).
3. **Redistribute**: run `fleet-sync` (Actions → Run workflow, or wait for the daily
   run) so every repo gets the new PAT.
4. **Revoke the OLD token** in the Fine-grained tokens page once step 3 has run —
   that invalidates any leaked/stale copy. (Leave the old one valid until the new
   PAT is redistributed, so sync never breaks mid-rotation.)

**Audit**: the Fine-grained tokens page lists each token's expiry; `gh secret list --repo <r>`
shows where `PROJECTS_WRITE_PAT` exists per repo.
