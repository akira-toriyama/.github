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
- `dependabot.yml` → synced to each repo's `.github/dependabot.yml` (keeps
  github-actions deps fresh fleet-wide). Edit this canonical copy, never the
  per-repo copies.

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

## Rotating the App private key (every 90 days)

The App private key is copied into every repo's secrets, so its blast radius is
wide. Rotation bounds the damage window — a leaked key stops working once the old
key is deleted. (A `projects` workflow auto-files a quarterly reminder task.)

1. **Generate** a new key: GitHub → Settings → Developer settings → GitHub Apps →
   **furrow-status-bot** → *Private keys* → **Generate a private key** (downloads a `.pem`).
2. **Update** the hub secret:
   `gh secret set PROJECTS_APP_PRIVATE_KEY --repo akira-toriyama/.github < new.pem`
3. **Redistribute**: run `fleet-sync` (Actions → Run workflow, or wait for the daily
   run) so every repo gets the new key.
4. **Delete the OLD key** in the App's *Private keys* page. **This is the step that
   matters** — deleting it **immediately invalidates every old copy everywhere**
   (even leaked/stale ones). Skipping it means rotation achieved nothing.

**Audit**: the App's *Private keys* page lists each key's fingerprint + creation
date (spot stale/unexpected keys); `gh secret list --repo <r>` shows where the
secret exists per repo.
