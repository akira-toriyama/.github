# Contributing

Conventions shared across the repositories under this account. This is the
**single source of truth for commit messages** — individual repos should link
here rather than copy it. (Per-repo `docs/commit-convention.md` files predate
this and have drifted; reduce them to a link over time.)

## Commit messages

We use **gitmoji + [Conventional Commits](https://www.conventionalcommits.org)**.
From the messages, [git-cliff](https://git-cliff.org) computes the release
**semver and the release notes** — so the format is enforced (the shared
`commit-lint.yml` reusable) and consumed (the shared `release.yml` reusable +
each repo's `cliff.toml`). **The Conventional type decides the version; gitmoji
is for readability and changelog grouping and never affects the version.**

### Format

```
<gitmoji> <type>(<scope>)<!>: <subject>

<body, optional>

<footer, optional>
```

- **gitmoji** — exactly one leading gitmoji in the `:sparkles:` **text form**
  (grep-friendly; not the emoji glyph), e.g. `:bug:`.
- **type** — required; one of the Conventional types below. **semver is decided
  by this.**
- **scope** — optional, **parenthesised only**: `(cli)`, `(native)`,
  `(homebrew)`, `(ci)`. Sub-scopes use dashes inside the parens
  (`(grid-1f-4)`, not bracketed forms — those fail the CI lint). Multi-word
  scopes go inside the parens too: `(commit-lint)`.
- **!** — breaking change (or a `BREAKING CHANGE: <desc>` footer).
- **subject** — required; imperative, present tense, concise. **English**,
  lowercase start, no trailing period.

### Type → semver

| Change | type / marker | version |
|---|---|---|
| Breaking change | `<type>!` or `BREAKING CHANGE:` footer | **major** |
| New feature | `feat` | **minor** |
| Bug fix / performance | `fix` / `perf` | **patch** |
| Revert | `revert` | patch |
| Everything else | `docs` `style` `refactor` `test` `build` `ci` `chore` | **no bump** (also excluded from the changelog) |

Non-conventional messages are not folded into a release (no version, no notes).
Bot commits (`github-actions`, `*[bot]`) are excluded from versioning and the
changelog (see each repo's `cliff.toml` `commit_parsers`).

### Body (optional)

- **English**; explain the *why* and *how*.
- When a body is present, end it with a `---（和訳）` separator and add a
  Japanese translation of both the subject and the body (same content).
- A subject-only commit needs no body and no translation.

### Footer (optional)

- `BREAKING CHANGE: <description>` — makes a major bump explicit.
- `Closes #<N>` — links / closes an issue.
- `Co-Authored-By: <name> <email>`.

### Examples

```
:sparkles: feat(ui): add a right-click window menu (float / fullscreen / close)
```

```
:bug: fix(config): keep defaults when an unknown key is present

Unknown keys used to reset the ring; now they are ignored per spec.

---（和訳）
fix(config): 未知のキーがあってもデフォルトを保持する

未知のキーは以前リングをリセットしていたが、仕様どおり無視するようにした。
```

```
:boom: feat(api)!: replace the --items flag with a positional argument

BREAKING CHANGE: `--items` is removed; pass the file as the first argument.
```

## Release flow (rolling-draft)

Releases are automated by the shared `release.yml` reusable:

1. Merge `feat:` / `fix:` / `perf:` to `main`. git-cliff computes the next
   version and the workflow creates/updates a single **draft** GitHub Release
   (build artifacts attached). **No tag is created yet.**
2. Review the draft and **Publish** it in the GitHub UI — GitHub creates the
   tag (`vX.Y.Z`) on the target commit at publish time.
3. Non-bumping-only changes (`docs:` / `chore:` / …) ⇒ the workflow no-ops.

`workflow_dispatch` with `dry_run=true` is a full preview (no draft, no version
consumed). The initial version is each repo's `cliff.toml` `initial_tag`
(typically `v1.0.0`). The CHANGELOG is not committed; the GitHub Release notes
are canonical.

## Local hook (optional, no Node)

Each repo bundles a shell `commit-msg` hook. Enable it with:

```sh
git config core.hooksPath scripts/hooks
```
