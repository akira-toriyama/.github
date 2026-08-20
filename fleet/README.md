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
- `dependabot.yml` + `dependabot.d/*.yml` → each repo's `.github/dependabot.yml`
  (keeps deps fresh fleet-wide). **Assembled** per repo: the base carries only
  github-actions (every repo has workflows); one `dependabot.d/` block is
  appended per package ecosystem whose root manifest exists on the target
  (`go.mod` → gomod, `Package.swift` → swift, `package.json` → npm). An
  ecosystem without its manifest is a weekly *failing* Dependabot run, not a
  no-op (t-s3fp); and a base-only overwrite *erases* a repo's real ecosystems —
  the old go.mod-only variant selection wiped chord's swift and study-engine's
  npm entries, killing their bump PRs (t-vhr9). New ecosystems = drop a block
  in `dependabot.d/` and add its `manifest:block` probe pair to the loop in
  `fleet-sync.yml`.
- `commit-lint.yml` → each repo's `.github/workflows/commit-lint.yml` (caller
  stub pinning [glyph](https://github.com/akira-toriyama/glyph)'s `lint.yml`
  reusable at a concrete release tag; enforces the commit convention on every
  PR. The hub's own shell-validator reusable it once called is retired).
- `taplo.yml` → each repo's `.github/workflows/taplo.yml` (caller stub for the
  shared [`taplo`](../.github/workflows/taplo.yml) reusable; a no-op on repos
  without any `*.toml`).
- `zizmor.yml` → each repo's `.github/workflows/zizmor.yml` (caller stub for the
  shared [`zizmor`](../.github/workflows/zizmor.yml) reusable — Actions-security
  lint as a PR gate). The zizmor version + action SHA live in the reusable, so this
  caller carries no third-party pin for a per-repo Dependabot to bump.
- `zizmor-config.yml` → each repo's `.github/zizmor.yml` (the `unpinned-uses` policy
  the gate reads; pairs with `zizmor.yml` above).
- `actionlint.yml` → each repo's `.github/workflows/actionlint.yml` (caller stub
  for the shared [`actionlint`](../.github/workflows/actionlint.yml) reusable —
  workflow-syntax + expression-type lint, with shellcheck over `run:` blocks, as
  a PR gate). Complements `zizmor.yml` above without overlapping it (zizmor =
  Actions *security*). The actionlint version + SHA256 live in the reusable, so
  this caller carries no third-party pin for a per-repo Dependabot to bump;
  per-repo waivers go in that repo's own `.github/actionlint.yaml`, which
  actionlint auto-discovers.
- `version-preview.yml` → each repo's `.github/workflows/version-preview.yml`
  (caller stub for [glyph](https://github.com/akira-toriyama/glyph)'s `pr-verdict.yml`
  reusable, pinned at a concrete release tag — bump it here per adopted glyph
  release, as with `commit-lint.yml`). Posts one sticky PR comment saying what
  merging would do to the version. Advisory: `commit-lint.yml` owns enforcement, and
  this is deliberately not a required check. The filename deliberately does **not**
  match the reusable it calls — the file's own header explains why, and
  `fleet-sync.yml`'s reusable-collision guard now refuses that mistake outright.
- `commit-convention.md` → each repo's `docs/commit-convention.md` (a universal
  pointer to the canonical [`CONTRIBUTING.md`](../CONTRIBUTING.md); carries no
  local-hook assumptions, so it fits hook-less repos too).
- `repo-policy.yml` → each repo's `.github/workflows/repo-policy.yml` (caller
  stub for the shared [`repo-policy`](../.github/workflows/repo-policy.yml)
  reusable — the tool-free house-policy PR gate: no translation files
  (`*.ja.*` paths; [doc-consistency-policy](../docs/doc-consistency-policy.md)),
  and no `available(macOS …)` gate at or below the repo's own `Package.swift`
  floor. Repos without a `Package.swift` skip the floor check automatically,
  so the stub is safe on non-Swift repos).

**Edit these canonical copies, never the per-repo copies** — fleet-sync overwrites
them on the next run.

## Rollout ledger — `rollout.json`

The one file here that is **not** distributed (fleet-manifest's check 3 excludes
it): it is the hub-only state the staged-rollout policy
([`docs/fleet-change-policy.md`](../docs/fleet-change-policy.md)) reads before any
apply run may write, via `scripts/fleet-rollout-gate.sh` (t-yyfv). Its effect:

- **Editing a canonical requires a ledger entry in the same PR.** The `covers`
  field is a hash over this directory's distributable bytes
  (`bash scripts/fleet-rollout-gate.sh --print-covers fleet/rollout.json`), and
  `tests/fleet-rollout-gate.test.sh` holds the real tree to it at PR time — so a
  canonical edit that forgets the ledger fails its own PR, and even if it merged,
  every apply run would refuse to distribute it (exit 11).
- **A rollout earns the fleet; it is not granted it.** `stage: "canary"` lets
  exactly the listed `canary` repos be written
  (`gh workflow run fleet-sync.yml -f dry-run=false -f only-repo=<canary>`).
  The recorder step then writes the read-back's verdicts into
  `evidence.canary.<repo>` as a PR on the hub, sets `soak_until` (48h) and
  advances `stage` to `"fleet"`. Fleet-wide writes resume only when the gate can
  verify that evidence — real `run_id` of a successful fleet-sync run, same
  `covers` — and the soak has elapsed. Any other `stage` value ("local", "poc",
  "glyph-test", …) holds all writes.
- **A held apply run is red on purpose** — including the daily scheduled one.
  That red says "the fleet is intentionally behind the hub's main"; the fix is to
  advance the rollout (run the canary, merge the evidence PR, wait out the soak),
  never to edit the ledger's evidence by hand — the gate's run-id check refuses
  records that no real run stands behind.

There is no approval flow in this — a solo fleet needs none. The only human acts
are the ones branch protection already requires: merging the change PR and the
evidence PR.

## How it runs

`fleet-sync.yml` runs daily (and on demand via **Run workflow**). It is **dormant**
until its secrets exist:

| Secret (on this `.github` repo) | What it is |
|---|---|
| `FLEET_SYNC_PAT` | classic PAT with `repo` + `workflow` scopes. `workflow` is **required** to write `.github/workflows/*` in other repos; the default `GITHUB_TOKEN` cannot. It is the widest-privilege secret here, so give it a bounded **expiry** (e.g. 1 year); the `fleet-sync-pat-expiry-reminder` workflow files a rotation task ~30 days before it lapses. |
| `PROJECTS_WRITE_PAT` | fine-grained PAT scoped to the tracker repo (`projects`) with **Contents: Read & write only**, auto-expiring — fanned out to each repo as `PROJECTS_WRITE_PAT`. Replaces the retired furrow-status-bot App master key (t-ke0v): a leak now reaches only the tracker and expires on its own. |
| `HOMEBREW_TAP_DEPLOY_KEY` | private half of `homebrew-tap`'s **write deploy key** — the cask-push credential every releasing repo uses (t-6bhz). Fanned out to each repo whose release-channel workflow (`release.yml`, `update-tap.yml`, or `goreleaser.yml`) references it. No expiry by design: a deploy key has no rotation calendar to miss, and a leak grants git push to the one tap repo, not an account-scoped API surface. |
| `HOMEBREW_TAP_TOKEN` | **DEPRECATED** (t-6bhz): the fine-grained cask-push PAT the deploy key above replaces. Still fanned out to repos whose release channel references it while they migrate; when the last consumer moves, delete this hub secret, its fan-out pair in `fleet-sync.yml`, and revoke the PAT. |

Manual runs **default to dry-run** (log only). Use `only-repo` to target one repo.

## Notes

- **Idempotent**: a file is rewritten only when it differs; the fanned-out secrets
  are overwritten every run, but each only on repos that already carry its consumer
  workflow on their default branch (least privilege — a repo holds a PAT only once
  it runs the workflow that needs it).
- **Security trade-off**: each fanned-out PAT is least-privilege and fine-grained
  (`PROJECTS_WRITE_PAT` = tracker `Contents: Read & write` only; `HOMEBREW_TAP_TOKEN`
  = tap `Contents: Read & write` only), so a leak reaches exactly one repo. Fan-out
  is **gated on the consumer workflow** on the target's default branch — the
  `task-status` stub existing for the tracker PAT; a release-channel workflow
  (`release.yml`, `update-tap.yml`, or `goreleaser.yml`) actually **referencing**
  `HOMEBREW_TAP_TOKEN` for the tap token (existence alone was too broad: some repos
  release without pushing a cask) — so each PAT lands only in repos that actually
  use it (a stub still in an open fleet-sync PR waits for merge). Narrow it further
  via `EXCLUDE` if needed.
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

## Replacing `HOMEBREW_TAP_DEPLOY_KEY` (no rotation calendar)

The deploy key does not expire, so there is no scheduled rotation — this procedure
is for a **suspected compromise** (or a deliberate re-key). Same
never-a-dead-window ordering as the PAT rotations above: add-new → redistribute →
remove-old.

1. **Generate** a fresh keypair: `ssh-keygen -t ed25519 -N '' -f tap-deploy-key`.
2. **Register** the public half as a second write deploy key on the tap:
   `gh api -X POST repos/akira-toriyama/homebrew-tap/keys -f title=… -f key=@tap-deploy-key.pub -F read_only=false`
   (a repo can hold several deploy keys, so the old one keeps working meanwhile).
3. **Update** the hub secret with the private half:
   `gh secret set HOMEBREW_TAP_DEPLOY_KEY --repo akira-toriyama/.github < tap-deploy-key`.
4. **Redistribute**: run `fleet-sync` (Actions → Run workflow with dry-run **off**, or
   wait for the daily run).
5. **Delete the OLD deploy key** (`gh api repos/akira-toriyama/homebrew-tap/keys` →
   `gh api -X DELETE repos/akira-toriyama/homebrew-tap/keys/<id>`) once step 4 has
   run, and shred the local private-key files.

The retired PAT's `homebrew-tap-token-expiry-reminder` workflow probed for token
death by HTTP 401 — SSH has no equivalent signal worth a weekly probe, and a dead
key fails the next release loudly at `git push`, so the reminder retires with the
PAT rather than being rebuilt for SSH.

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
