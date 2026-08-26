#!/usr/bin/env bash
# Table-test scripts/glyph-pin-scan.sh — the extractor glyph-pin-audit.yml reads
# every fleet workflow through. Each case is one YAML document on stdin and the
# EXACT record stream it must produce (kind, tag, line). Runs the REAL script
# (drift-free); self-test.yml invokes this. Needs bash + awk only.
#
# The shapes below are the fleet's real ones, not invented: the fleet caller
# stub, the two install-step spellings that exist across the 8 repos that call
# the composite, glyph's own relative-path form, and the commented example pin
# every glyph reusable ships (matching that one is a mistake this repo has
# already made once).
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
script="$root/scripts/glyph-pin-scan.sh"
fails=0

[ -f "$script" ] || { echo "FAIL - $script is missing"; exit 1; }

# case <name> <yaml> <expected-records>
case_() {
  local name="$1" yaml="$2" want="$3" got rc
  got="$(printf '%s\n' "$yaml" | bash "$script" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && [ "$got" = "$want" ]; then
    echo "ok   - $name"
  else
    echo "FAIL - $name (rc=$rc)"
    echo "       want:"; printf '%s\n' "$want" | sed 's/^/         /'
    echo "       got:";  printf '%s\n' "$got"  | sed 's/^/         /'
    fails=$((fails + 1))
  fi
}

# A fleet-synced caller pins a reusable workflow at job level — no step, no
# binary version of its own.
case_ "reusable caller pin" "$(cat <<'EOF'
name: commit-lint
on:
  pull_request:
jobs:
  lint:
    uses: akira-toriyama/glyph/.github/workflows/lint.yml@v0.11.0
EOF
)" "$(printf 'uses\tv0.11.0\t6')"

# The spelling seven repos use: a named step whose `uses:` is on the next line.
# The version they pass is the one that drifted to v0.8.0 behind a v0.10.2 action.
case_ "named install step reports both pins" "$(cat <<'EOF'
jobs:
  release:
    steps:
      - name: checkout
        uses: actions/checkout@v7
      - name: install glyph
        uses: akira-toriyama/glyph/.github/actions/install@v0.10.2
        with:
          version: v0.8.0
          token: ${{ github.token }}
      - name: generate release notes (glyph)
        run: glyph notes
EOF
)" "$(printf 'uses\tv0.10.2\t7\nversion\tv0.8.0\t9')"

# glyph-test's spelling: the `uses:` IS the list item.
case_ "bare install item reports both pins" "$(cat <<'EOF'
jobs:
  release:
    steps:
      - uses: akira-toriyama/glyph/.github/actions/install@v0.10.2
        with:
          version: v0.10.2
          token: ${{ github.token }}
EOF
)" "$(printf 'uses\tv0.10.2\t4\nversion\tv0.10.2\t6')"

# Every glyph reusable ships a commented caller stub with a permanently stale
# example pin. Reading it is how a naive grep reports eternal false drift.
case_ "commented example pin ignored" "$(cat <<'EOF'
# Example caller:
#   jobs:
#     lint:
#       uses: akira-toriyama/glyph/.github/workflows/lint.yml@v0.4.0
jobs:
  lint:
    uses: akira-toriyama/glyph/.github/workflows/lint.yml@v0.11.0
EOF
)" "$(printf 'uses\tv0.11.0\t7')"

case_ "trailing comment is not a second pin" "$(cat <<'EOF'
jobs:
  lint:
    uses: akira-toriyama/glyph/.github/workflows/lint.yml@v0.11.1 # was @v0.8.0
EOF
)" "$(printf 'uses\tv0.11.1\t3')"

# glyph's own reusables reach the composite by relative path against a checkout
# of glyph at the caller's pinned commit, and compute the version. Nothing here
# is a hand-maintained pin, so nothing is reported.
case_ "glyph's own relative install is invisible" "$(cat <<'EOF'
jobs:
  lint:
    steps:
      - name: Install glyph (pinned release binary)
        uses: ./.glyph-action/.github/actions/install
        with:
          version: ${{ steps.glyph.outputs.version }}
          token: ${{ github.token }}
EOF
)" ""

# Fail loud, not open: an install step this scanner cannot read a literal
# version out of must not look like a correct one.
case_ "install step with no version is reported" "$(cat <<'EOF'
jobs:
  release:
    steps:
      - uses: akira-toriyama/glyph/.github/actions/install@v0.11.1
        with:
          token: ${{ github.token }}
EOF
)" "$(printf 'uses\tv0.11.1\t4\nversion-missing\tv0.11.1\t4')"

case_ "install step with a computed version is reported" "$(cat <<'EOF'
jobs:
  release:
    steps:
      - uses: akira-toriyama/glyph/.github/actions/install@v0.11.1
        with:
          version: ${{ env.GLYPH_VERSION }}
          token: ${{ github.token }}
EOF
)" "$(printf 'uses\tv0.11.1\t4\nversion-unreadable\tv0.11.1\t4')"

# `version:` is a generic input name. A neighbouring step's must never be
# attributed to the glyph step — this is the whole reason the scanner tracks
# blocks instead of grepping.
case_ "a neighbour's version: is not the glyph pin" "$(cat <<'EOF'
jobs:
  release:
    steps:
      - uses: akira-toriyama/glyph/.github/actions/install@v0.11.1
        with:
          version: v0.11.1
          token: ${{ github.token }}
      - uses: uncle-org/taplo-action@v1
        with:
          version: v9.9.9
EOF
)" "$(printf 'uses\tv0.11.1\t4\nversion\tv0.11.1\t6')"

case_ "flow-style with: block" "$(cat <<'EOF'
jobs:
  release:
    steps:
      - uses: akira-toriyama/glyph/.github/actions/install@v0.11.1
        with: { version: v0.11.1, token: x }
EOF
)" "$(printf 'uses\tv0.11.1\t4\nversion\tv0.11.1\t5')"

# A list nested inside a step is deeper than the `- ` that opened it, so it must
# not end the step and orphan the version that follows.
case_ "a nested list does not end the step" "$(cat <<'EOF'
jobs:
  release:
    steps:
      - uses: akira-toriyama/glyph/.github/actions/install@v0.11.1
        env:
          PATHS:
            - a
            - b
        with:
          version: v0.11.1
EOF
)" "$(printf 'uses\tv0.11.1\t4\nversion\tv0.11.1\t10')"

# The decoy key comes AFTER the real one deliberately. The scanner is
# last-write-wins, so with the order reversed this case passes just as happily
# without the `[ \t{,]` guard that keeps `glyph-version:` from reading as
# `version:` — it would be named for a failure it cannot detect.
case_ "quotes erased, glyph-version: not read as version:" "$(cat <<'EOF'
jobs:
  release:
    steps:
      - uses: "akira-toriyama/glyph/.github/actions/install@v0.11.1"
        with:
          version: "v0.11.1"
          glyph-version: v9.9.9
EOF
)" "$(printf 'uses\tv0.11.1\t4\nversion\tv0.11.1\t6')"

# ---------------------------------------------------------------------------
# Refs that are NOT a concrete release tag. Each of these produced ZERO output
# before the `uses:` match was widened — indistinguishable, to the audit, from a
# file with no glyph reference at all.
# ---------------------------------------------------------------------------
case_ "a branch ref is reported, not skipped" "$(cat <<'EOF'
jobs:
  lint:
    uses: akira-toriyama/glyph/.github/workflows/lint.yml@main
EOF
)" "$(printf 'uses-unpinned\tmain\t3')"

# The compounding case: losing the `uses:` match also dropped the block tag, so
# the BINARY version inside the step vanished with it. A step installing a
# three-release-old glyph off a SHA-pinned action reported nothing at all.
case_ "a SHA-pinned install action still reports its binary version" "$(cat <<'EOF'
jobs:
  release:
    steps:
      - uses: akira-toriyama/glyph/.github/actions/install@0f9d1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f
        with:
          version: v0.8.0
EOF
)" "$(printf 'uses-unpinned\t0f9d1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f\t4\nversion\tv0.8.0\t6')"

# A prerelease is not the release tag the fleet is levelled on, and the old
# `@v[0-9][0-9.]*` match would have truncated it to `v0.11.0` and called it level.
case_ "a prerelease tag is not mistaken for its release" "$(cat <<'EOF'
jobs:
  lint:
    uses: akira-toriyama/glyph/.github/workflows/lint.yml@v0.11.0-rc.1
EOF
)" "$(printf 'uses-unpinned\tv0.11.0-rc.1\t3')"

# The residue the v3.0.0 rollout actually left (glyph-test's pin-probe.yml):
# a prerelease BINARY version under a release-pinned action. Prefix-matching
# the value read v3.0.0 out of v3.0.0-rc.3 and reported the site as already
# at its release, hiding the drift from the audit and the rewriter alike.
case_ "a prerelease version: is reported whole, not as its release" "$(cat <<'EOF'
jobs:
  probe:
    steps:
      - uses: akira-toriyama/glyph/.github/actions/install@v3.0.0
        with:
          version: v3.0.0-rc.3
          token: ${{ github.token }}
EOF
)" "$(printf 'uses\tv3.0.0\t4\nversion\tv3.0.0-rc.3\t6')"

# A moving major would silently re-point the whole fleet on glyph's next release.
case_ "a moving major ref is reported" "$(cat <<'EOF'
jobs:
  lint:
    uses: akira-toriyama/glyph/.github/workflows/lint.yml@v0
EOF
)" "$(printf 'uses-unpinned\tv0\t3')"

case_ "blank and comment lines do not end the step" "$(cat <<'EOF'
jobs:
  release:
    steps:
      - uses: akira-toriyama/glyph/.github/actions/install@v0.11.1

        # keep the binary in lockstep with the tag above
        with:
          version: v0.11.1
EOF
)" "$(printf 'uses\tv0.11.1\t4\nversion\tv0.11.1\t8')"

# A file with no glyph reference at all must produce nothing — the audit loops
# over every .github/**.yml in ~36 repos and most of them are this.
case_ "unrelated workflow is silent" "$(cat <<'EOF'
name: taplo
on:
  pull_request:
jobs:
  taplo:
    steps:
      - uses: uncle-org/taplo-action@v1
        with:
          version: v9.9.9
EOF
)" ""

[ "$fails" -eq 0 ] || { echo "$fails glyph-pin-scan case(s) failed"; exit 1; }
echo "all glyph-pin-scan cases passed"
