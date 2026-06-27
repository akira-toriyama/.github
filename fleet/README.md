# fleet — repo standardizer

Keeps a set of **standard files** present in every owned, non-fork, non-archived
repo, and distributes the secrets those files need. New repos are onboarded
automatically (the repo list is fetched at run time), so there is never a
"this repo has it / that one doesn't" gap.

It is **general on purpose**: `task-status` is just the first managed file. To
standardize more files across the fleet, drop the canonical copy here and add a
line to `MANIFEST` in [`.github/workflows/fleet-sync.yml`](../.github/workflows/fleet-sync.yml).

## Files

- `task-status.yml` → synced to each repo's `.github/workflows/task-status.yml`
  (the thin caller stub for the [`sync-task-status`](../.github/workflows/sync-task-status.yml)
  reusable). **Edit this canonical copy, never the per-repo copies** — fleet-sync
  overwrites them.

## How it runs

`fleet-sync.yml` runs daily (and on demand via **Run workflow**). It is **dormant**
until its secrets exist:

| Secret (on this `.github` repo) | What it is |
|---|---|
| `FLEET_SYNC_PAT` | classic PAT with `repo` + `workflow` scopes. `workflow` is **required** to write `.github/workflows/*` in other repos; the default `GITHUB_TOKEN` cannot. |
| `PROJECTS_APP_CLIENT_ID` | furrow-status-bot App **Client ID** — fanned out to each repo as `PROJECTS_APP_CLIENT_ID`. |
| `PROJECTS_APP_PRIVATE_KEY` | furrow-status-bot App **private key** — fanned out to each repo as `PROJECTS_APP_PRIVATE_KEY`. |

Manual runs **default to dry-run** (log only). Use `only-repo` to target one repo.

## Notes

- **Idempotent**: a file is rewritten only when it differs; secrets are set every run (cheap, overwrite).
- **Security trade-off**: distributing the App private key to many repos widens its
  blast radius. If that matters more than uniformity, add repos to `EXCLUDE` or
  scope the secret-fan-out step. (The centralized-sweep alternative keeps the key
  in one place but trades away real-time updates — see the design notes.)
- The furrow-status-bot App only needs to be installed on the **tracker repo**
  (`projects`); code repos do not need the App installed.
