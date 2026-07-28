# Contributing

Conventions shared across the repositories under this account. This is the
**single source of truth for commit messages** — individual repos carry only a
fleet-distributed pointer here (`docs/commit-convention.md`), never a copy.

## Commit messages

We use **gitmoji-driven commits**: the leading gitmoji **is the type** and
decides the release **semver and the release-notes grouping**. The engine is
[glyph](https://github.com/akira-toriyama/glyph) — the format is enforced on
every PR (the fleet-wide `commit-lint.yml` caller runs glyph's reusable
`lint.yml`) and consumed at release time (`glyph release` / `glyph bump` /
`glyph notes`).

> Historical note: the convention used to be gitmoji + Conventional Commits
> with the Conventional `<type>` word deciding the version (computed by
> git-cliff). The `<type>` word is now retired — the gitmoji plays that role —
> but the linter still accepts-and-ignores a legacy `<type>(scope)!:` token, so
> old history keeps linting and bumping. No flag-day.

### Format

```
<:gitmoji:>[(<scope>)][!] <subject>

<body, optional>

<footer, optional>
```

- **gitmoji** — exactly one leading gitmoji in the `:sparkles:` **text form**
  (column 0, mandatory). Textual, not the emoji glyph: pure ASCII (no
  U+FE0F/ZWJ), grep-friendly, deterministic to author; GitHub renders the glyph
  in its UI. An **unknown code is a hard lint error**, never a silent pass.
- **scope** — optional, **parenthesised only**, lowercase kebab, attached
  directly to the code (no space): `:sparkles:(cli)`, `:bug:(commit-lint)`.
- **!** — breaking-change marker, immediately after the code or the scope
  (or use a `BREAKING CHANGE: <desc>` footer).
- **subject** — required; imperative, present tense, concise. **English**,
  lowercase start, no trailing period.

### gitmoji → semver

Bump lattice `none < patch < minor < major`, default **none**; all 75 spec
codes are explicitly enumerated. The **machine source of truth is glyph's
embedded rules table** — print it with `glyph rules` (`--md` for the full
table, mirrored at
[glyph `docs/gitmoji-table.md`](https://github.com/akira-toriyama/glyph/blob/main/docs/gitmoji-table.md)).
The buckets:

| Change | gitmoji / marker | version |
|---|---|---|
| Breaking change | `:boom:`, or `!`, or `BREAKING CHANGE:` footer | **major** |
| New feature | `:sparkles:` (deliberately the only minor) | **minor** |
| Shipped / user-observable behavior | `:bug:` `:zap:` `:lock:` `:lipstick:` `:arrow_up:` `:rewind:` … | **patch** |
| Internal / non-shipping / meta | `:memo:` `:recycle:` `:wrench:` `:white_check_mark:` `:construction_worker:` … | **no bump** (excluded from the notes — except deletions/renames, see below) |

- **Breaking is an orthogonal, non-suppressible flag**, not a rung: any of the
  three triggers forces major regardless of the code's own bump.
- **Squash-safe**: at release time the bump is computed from **each PR's
  individual commits** (resolved via the GitHub API) and max-folded — never
  from `main`'s post-squash subjects — so `COMMIT_OR_PR_TITLE` squash titles
  cannot hide or invent a bump. Order-independent and stateless.
- Bot commits (`*[bot]`), merge commits, autosquash artifacts, and raw
  `git revert` subjects are skipped by the lint and excluded from versioning
  and the notes. A `:construction:` (WIP) commit in a merge candidate is a
  lint error.

### Deletions & renames (public API)

A deletion or rename is literally `:fire:` (remove), `:coffin:` (remove dead
code), or `:truck:` (move / rename) — all **no bump**. That is correct for
internal, dead, or non-public assets, and silently wrong for the rare one:
removing or renaming something others depend on is a breaking change that the
literal gitmoji hides from semver.

**Rule (enforced):** a commit whose code is `:fire:`, `:coffin:` or `:truck:`
must say whether it breaks anyone. Either it takes a **public** element away —
an exported type or function, a catalog / preset name, a configuration key, a
resource slug, anything another repo or a user can reference — and carries `!`
(or a `BREAKING CHANGE:` footer), or it does not and carries a
`NON-BREAKING: <why>` footer. Silence is a **lint error**, in CI and in the
commit-msg hook.

- **Every repo, not just libraries.** This used to be a library-repo rule, on
  the reasoning that an app is a leaf nothing depends on. The measurement says
  otherwise: replaying the whole fleet, every clear true positive was in an
  *app* repo removing a user-facing configuration key. Users are downstream
  too, and "is this repo a library" is a judgement that was already got wrong
  once. The rule is uniform so the safety net cannot be switched off by
  mis-classifying a repo.
- **glyph forces the question, it cannot answer it.** No commit-message linter
  can know whether the removed symbol was public — that is your repo's
  knowledge, and an API-diff tool's job. All the rule does is refuse to let the
  question go unanswered, so `NON-BREAKING:` is a claim you are making, not a
  formality. It never lowers a bump, so it cannot be used to hide a break.
- **Safety net, not a substitute.** glyph also surfaces
  `:fire:`/`:truck:`/`:coffin:` under a **Removals** section in the release
  notes (still `no bump`), so an honest deletion stays visible to a downstream
  pin-bump audit.

*Why this exists:* sill pruned the public preset `catppuccin-latte` under
`:fire:` inside a `:sparkles:` PR and shipped it as a minor; a downstream
consumer broke on its next pin bump because the removal carried no major signal
and — until the Removals section — no notes signal either. `:truck:` is the
worse of the three: a rename resolves at runtime, so sill's
`paletteFor("catppuccin-latte")` fell back to another theme silently rather
than failing.

### Body (optional)

- **English**; explain the *why* and *how*.
- A subject-only commit needs no body.

### Footer (optional)

- `BREAKING CHANGE: <description>` — makes a major bump explicit.
- `NON-BREAKING: <why>` — records that a `:fire:`/`:coffin:`/`:truck:` removal
  takes nothing public away. Required on those codes when `!` is absent; the
  reason is mandatory. Never lowers a bump.
- `Closes #<N>` — links / closes an issue.
- `Co-Authored-By: <name> <email>`.

Footers are **trailers**: they open a block (after a blank line) or stack under
another trailer, and are matched case-sensitively. Prose that happens to wrap
onto `BREAKING CHANGE:` mid-paragraph is not a footer — a line break must not
be able to buy a major release.

### Examples

```
:sparkles:(ui) add a right-click window menu (float / fullscreen / close)
```

```
:bug:(config) keep defaults when an unknown key is present

Unknown keys used to reset the ring; now they are ignored per spec.
```

```
:boom:(api) replace the --items flag with a positional argument

BREAKING CHANGE: `--items` is removed; pass the file as the first argument.
```

## Release flow

Both release shapes read the same commit data; the difference is only who
builds the artifacts. (**Verdict is glyph's; artifacts are GoReleaser's.**)

- **Rolling-draft repos** (glyph's reusable `release.yml`): every push to
  `main` recomputes the verdict from `lastPublishedTag..HEAD` and converges the
  repo's single **draft** GitHub Release (notes + next `vX.Y.Z`). **No tag is
  created** — review the draft and **Publish** it in the GitHub UI; GitHub
  creates the tag at publish time. A no-bump range means no draft (and any
  stale draft is deleted).
- **Binary-distribution repos** (tag-driven GoReleaser): the next tag comes
  from `glyph bump`, the release notes from `glyph notes`; GoReleaser owns the
  artifacts, checksums, and attestation.

The fleet migration is complete: every releasing repo is on a glyph flavor
above, and the hub's old git-cliff `release.yml` reusable is retired (its
frozen `@v1` would still serve a straggler, but none exist).

## Local hook (optional)

Install it once per clone, in any repo:

```sh
glyph hook install
```

That writes a `commit-msg` hook which pipes the message into `glyph lint
--stdin`, so a violation surfaces as you commit rather than after a push. The
hook carries **no copy of the convention** — it calls glyph, so it cannot lag
the rules the way the bundled per-repo hooks did. Where glyph is not on `PATH`
it warns and lets the commit through: CI (`glyph lint`) is the authority, the
hook is only an early warning.

It honours `core.hooksPath` and refuses to overwrite a hook it did not write
(`--force` overrides). `glyph hook install --print` shows the script without
installing it.

> Repos used to bundle a shell `commit-msg` hook under `scripts/hooks`, enabled
> with `git config core.hooksPath scripts/hooks`. Those were hand-written
> regexes for the retired `<type>:` form and had fallen out of lockstep with the
> convention — they are removed. If you still have `core.hooksPath` pointing at
> `scripts/hooks` in a clone, unset it (`git config --unset core.hooksPath`) and
> run `glyph hook install`.
