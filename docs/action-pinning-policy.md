# Action-pinning policy

How `uses:` refs are pinned across every workflow in this repo (and the fleet
callers it distributes). Third-party actions are already SHA-pinned and GitHub's
own actions ride version tags; this file records **why the boundary sits there**
so it is a decision, not an accident. The machine check for it is the
`unpinned-uses` policy in [`.github/zizmor.yml`](../.github/zizmor.yml) — this doc
is the human rationale behind that config.

## The three tiers

| Publisher | Pin to | Example |
|---|---|---|
| **First-party** — `actions/*` (GitHub-authored) | major-version **tag** (a full SHA is also accepted, never *required*) | `actions/checkout@v7` |
| **Third-party** — everyone else | **full-length commit SHA** + a `# vX.Y.Z` trailer | `taiki-e/install-action@<sha> # v2.62.19` |
| **Self-owned** — `akira-toriyama/*` reusables & composite | release **tag** | `akira-toriyama/.github/.github/workflows/taplo.yml@v2` |

`zizmor`'s `ref-pin` requires *some* git ref (tag or SHA), and `hash-pin` requires
a full SHA. So the config maps one-to-one: `actions/*` → `ref-pin`,
`akira-toriyama/*` → `ref-pin`, `*` → `hash-pin`.

## Why first-party actions stay on tags (the decision)

GitHub's own [secure-use guidance](https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions#using-third-party-actions)
calls a full commit SHA the only immutable way to pin *any* action and carves out
no exception for first-party ones. We take the exception anyway, deliberately:

- **Authorship.** `actions/*` is GitHub-published from the same platform that runs
  the workflow. A supply-chain compromise there is a compromise of the runner
  itself — SHA-pinning `actions/checkout` does not meaningfully shrink that blast
  radius, whereas it very much does for an arbitrary third-party action.
- **Freshness cost.** These are bumped by Dependabot in a weekly **grouped** PR
  (`.github/dependabot.yml`), so tags never drift far. Blanket SHA-pinning would
  trade that low-friction currency for a wall of SHA-churn PRs with a `# vX`
  comment that has to be read to know what moved — worse ergonomics, marginal gain.
- **Blast radius stays bounded elsewhere.** The classes SHA-pinning defends
  against (a hijacked *tag* on a third-party action) are already closed for
  third-party via `hash-pin`, and the deeper CodeQL "actions" scan
  ([`scripts/apply-repo-settings.sh`](../scripts/apply-repo-settings.sh)) is the
  backstop for the tail.

This is the "document the exception" resolution (vs. blanket SHA-pinning
everything); the trade is small either way, but the boundary is now recorded.

## Notes

- **A SHA is always allowed, never required, for first-party.** `go-ci.yml` and
  `go-vuln.yml` SHA-pin `actions/checkout` / `actions/setup-go` (they were pinned
  to "the newest across the fleet" when Go CI was standardized). That is *stricter*
  than this policy asks and stays compliant — no need to convert them back to tags,
  and no need to push the other workflows to SHA. First-party consistency (all-tag
  vs all-SHA) is a style preference, not a requirement.
- **Third-party pins carry a `# vX.Y.Z` trailer** so Dependabot can track them and
  a human can read what a SHA is without resolving it.
- **Fleet callers follow the same policy.** The stubs in [`fleet/`](../fleet/) pin
  `akira-toriyama/.github/...@v2` (self-owned → tag); any third-party `uses:` added
  to a distributed file must be SHA-pinned.
