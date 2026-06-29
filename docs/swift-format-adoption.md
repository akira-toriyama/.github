# Adopting swift-format in a Swift repo

The shared [`swift-format`](../.github/workflows/swift-format.yml) reusable runs
`swift format lint --strict` against a caller repo's `Sources`/`Tests`, using the
caller's `./.swift-format` config when present (else swift-format's defaults). This
is the house procedure for turning that gate green in a new Swift-package repo.

`chord` is the reference adoption ([chord#172](https://github.com/akira-toriyama/chord/pull/172)).

## Why a one-time reformat is unavoidable

A config **alone cannot** make `swift format lint --strict` pass on hand-formatted
code. Beyond indent width and the toggleable lint rules, `swift format` also
normalizes line breaks, spacing, and continuation indent via its pretty-printer —
and those are **not configurable**. Measured on chord, a best-effort config still
left ~4.5k findings (column-aligned tables collapsed, wrapped-argument indent
rewritten, line breaks moved). So the gate only goes green after the sources are
reformatted once.

The house policy (decided in t-w2xf) is **A′**: keep a house config that preserves
deliberate house style, then reformat **once** under it. On chord this kept the diff
to ~⅓ of swift-format's defaults (80 files, +5583/−4468 vs +15282/−14121) while
reaching `0` findings.

## The house `.swift-format`

Drop this at the repo root. 4-space indent; the rules that would rewrite deliberate
house choices are disabled (semicolons, import order, `.forEach`, grouped numeric
literals, access level on extensions, single trailing commas):

```json
{
  "version": 1,
  "indentation": { "spaces": 4 },
  "multiElementCollectionTrailingCommas": false,
  "rules": {
    "DoNotUseSemicolons": false,
    "OrderedImports": false,
    "GroupNumericLiterals": false,
    "ReplaceForEachWithForLoop": false,
    "OneVariableDeclarationPerLine": false,
    "NoAccessLevelOnExtensionDeclaration": false
  }
}
```

`lineLength` stays at the default `100`. Tune per house preference if needed — a
wider value reduces wrap churn but is a style choice, not a correctness one.

## Procedure (per repo)

1. **Add the config** — commit `./.swift-format` (above) and the caller stub below.
2. **Reformat once, in its own commit** — keep it separate from logic so it stays
   easy to review and revert:
   ```sh
   swift format --in-place --recursive Sources Tests
   git add -A && git commit -m ":art: style: reformat sources to satisfy swift-format"
   ```
3. **Verify** before pushing:
   ```sh
   swift format lint --strict --recursive Sources Tests   # expect 0 findings
   swift build && swift test                               # reformat is mechanical; must stay green
   ```
4. **Open the PR.** The caller's `swift-format` check validates the gate in CI.

### Caller stub — `.github/workflows/swift-format.yml`

```yaml
name: swift-format

on:
  pull_request:
    paths: ['Sources/**/*.swift', 'Tests/**/*.swift']
  workflow_dispatch:

jobs:
  swift-format:
    uses: akira-toriyama/.github/.github/workflows/swift-format.yml@v1
```

Pin `@v1` per [the ref policy](reusable-versioning.md). Widen the trigger `paths`
(and the reusable's `paths` input) for a non-standard source layout.

## Why this is not fleet-distributed

[`fleet`](../fleet/README.md) pushes its `MANIFEST` files to **every** owned repo
with no per-language scoping, but swift-format applies only to Swift packages —
distributing it fleet-wide would litter Go/other repos with a dead config + caller.
And the mandatory one-time reformat (above) is inherently per-repo and cannot be
automated by fleet. So swift-format is adopted **manually, repo by repo**, using
this procedure. (If the fleet ever gains language scoping, the config + caller —
but not the reformat — could be distributed to the Swift subset.)
