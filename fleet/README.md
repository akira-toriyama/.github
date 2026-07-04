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
  caller stub for furrow's bundled
  [`sync-task-status`](https://github.com/akira-toriyama/furrow/blob/main/.github/workflows/sync-task-status.yml)
  reusable — pinned to a concrete furrow release tag; bump the pin here per
  furrow release).
- `dependabot.yml` → each repo's `.github/dependabot.yml` (keeps github-actions
  deps fresh fleet-wide).
- `commit-lint.yml` → each repo's `.github/workflows/commit-lint.yml` (caller
  stub for the shared [`commit-lint`](../.github/workflows/commit-lint.yml)
  reusable; enforces the commit convention on every PR).
- `taplo.yml` → each repo's `.github/workflows/taplo.yml` (caller stub for the
  shared [`taplo`](../.github/workflows/taplo.yml) reusable; a no-op on repos
  without any `*.toml`).
- `zizmor.yml` → each repo's `.github/workflows/zizmor.yml` (caller stub for the
  shared [`zizmor`](../.github/workflows/zizmor.yml) reusable — Actions-security
  lint as a PR gate). The zizmor version + action SHA live in the reusable, so this
  caller carries no third-party pin for a per-repo Dependabot to bump.
- `zizmor-config.yml` → each repo's `.github/zizmor.yml` (the `unpinned-uses` policy
  the gate reads; pairs with `zizmor.yml` above).
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
| `FLEET_SYNC_PAT` | classic PAT with `repo` + `workflow` scopes. `workflow` is **required** to write `.github/workflows/*` in other repos; the default `GITHUB_TOKEN` cannot. It is the widest-privilege secret here, so give it a bounded **expiry** (e.g. 1 year); the `fleet-sync-pat-expiry-reminder` workflow files a rotation task ~30 days before it lapses. |
| `PROJECTS_WRITE_PAT` | fine-grained PAT scoped to the tracker repo (`projects`) with **Contents: Read & write only**, auto-expiring — fanned out to each repo as `PROJECTS_WRITE_PAT`. Replaces the retired furrow-status-bot App master key (t-ke0v): a leak now reaches only the tracker and expires on its own. |

Manual runs **default to dry-run** (log only). Use `only-repo` to target one repo.

## Notes

- **Idempotent**: a file is rewritten only when it differs; the tracker PAT is
  overwritten every run, but only on repos that already carry the `task-status` stub
  on their default branch (least privilege — a repo holds the PAT only once it runs
  the workflow that needs it).
- **Security trade-off**: the fanned-out `PROJECTS_WRITE_PAT` is least-privilege
  (tracker `Contents: Read & write` only) and auto-expiring, so its blast radius is
  narrow — a leak reaches only the tracker and stops working on expiry. Fan-out is
  **gated on the `task-status` stub** existing on the target's default branch, so the
  PAT lands only in repos that actually use it (a stub still in an open fleet-sync PR
  waits for merge). Narrow it further via `EXCLUDE` if needed.
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

## Rotating `FLEET_SYNC_PAT`

`FLEET_SYNC_PAT` is a **classic** PAT (`repo` + `workflow`) and the widest-privilege
secret in this system — it writes files and sets secrets across every repo. Give it a
bounded **expiry**; `.github`'s `fleet-sync-pat-expiry-reminder` workflow then files a
furrow task ~30 days before it lapses so rotation is never forgotten. (While the token
is non-expiring the reminder stays quiet — reissue it *with* an expiry to arm it.)

1. **Generate** a new classic PAT: GitHub → Settings → Developer settings → Tokens
   (classic) → **Generate new token**, scopes `repo` + `workflow`, expiry e.g. 1 year.
2. **Update** the hub secret:
   `gh secret set FLEET_SYNC_PAT --repo akira-toriyama/.github` (paste the token).
3. **Verify**: run `fleet-sync` (Actions → Run workflow, dry-run) — it should list
   candidate repos instead of the "dormant" notice.
4. **Revoke the OLD token** in the Tokens (classic) page once step 3 passes.
