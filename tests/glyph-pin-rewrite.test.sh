#!/usr/bin/env bash
# Table-test scripts/glyph-pin-rewrite.sh — the writer half of the glyph pin
# machinery. glyph-pin-scan.sh decides what a pin IS (tested next door); this
# decides what happens to the file, and it is the half that can damage ~14 repos.
#
# Every case is one YAML document in and the EXACT bytes out, or the exact exit
# code for the two states it must refuse. Runs the REAL script; self-test.yml
# invokes this. Needs bash + awk only.
#
# Two properties are checked on every passing case without being written per
# case, because both fail silently and both are how an automated fleet write
# turns into a daily stream of no-op PRs or a slow corruption:
#
#   IDEMPOTENCE — rewriting the output again must produce the same bytes. A
#     rewriter that is not idempotent re-opens the same PR forever.
#   CONFINEMENT — the output must differ from the input only on lines that
#     actually carry a glyph pin (the script enforces this itself and exits 3;
#     the cases below aim at the specific shapes where it is tempting not to).
#
# The shapes are the fleet's real ones. Every trap named in the script's header
# has a case here AND a positive control proving the case would notice: a guard
# that asserts "this was left alone" passes just as happily when the rewriter
# matches nothing at all.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
script="$root/scripts/glyph-pin-rewrite.sh"
fails=0

[ -f "$script" ] || { echo "FAIL - $script is missing"; exit 1; }

WANT=v0.12.0

fail_() {
  echo "FAIL - $1"
  shift
  for line in "$@"; do printf '       %s\n' "$line"; done
  fails=$((fails + 1))
}

# case_ <name> <yaml-in> <yaml-out-expected>
case_() {
  local name="$1" in_="$2" want="$3" got rc again rc2
  got="$(printf '%s\n' "$in_" | bash "$script" "$WANT" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    fail_ "$name" "expected rc=0, got rc=$rc" "$(printf '%s' "$got" | sed 's/^/  /')"
    return
  fi
  if [ "$got" != "$want" ]; then
    fail_ "$name" "want:" "$(printf '%s' "$want" | sed 's/^/  /')" \
      "got:" "$(printf '%s' "$got" | sed 's/^/  /')"
    return
  fi
  # Idempotence, on every case, for free.
  again="$(printf '%s\n' "$got" | bash "$script" "$WANT" 2>&1)"; rc2=$?
  if [ "$rc2" -ne 0 ] || [ "$again" != "$got" ]; then
    fail_ "$name (idempotence)" "a second rewrite changed the file (rc=$rc2)" \
      "$(diff <(printf '%s\n' "$got") <(printf '%s\n' "$again") | head -10)"
    return
  fi
  echo "ok   - $name"
}

# same_ <name> <yaml> — the rewriter must return the file byte-for-byte.
same_() { case_ "$1" "$2" "$2"; }

# refuse_ <name> <yaml> <expected-rc> <expected-stderr-substring>
refuse_() {
  local name="$1" in_="$2" want_rc="$3" needle="$4" out err rc
  err="$(mktemp)"
  out="$(printf '%s\n' "$in_" | bash "$script" "$WANT" 2>"$err")"; rc=$?
  if [ "$rc" -ne "$want_rc" ]; then
    fail_ "$name" "expected rc=$want_rc, got rc=$rc" "stderr: $(head -3 "$err")"
  elif [ -n "$out" ]; then
    fail_ "$name" "refused with rc=$rc but still wrote $(printf '%s' "$out" | wc -l) line(s) to stdout" \
      "a caller redirecting stdout to a file would land a half-rewrite"
  elif ! grep -q -- "$needle" "$err"; then
    fail_ "$name" "stderr does not explain the refusal (looking for '$needle')" "$(head -5 "$err")"
  else
    echo "ok   - $name"
  fi
  rm -f "$err"
}

# ---------------------------------------------------------------------------
# The three sites fleet-sync cannot reach. These are the whole point.
# ---------------------------------------------------------------------------

# Site 3: a repo's own release.yml calling glyph's release reusable.
case_ "release.yml caller pin moves" "$(cat <<'EOF'
name: release
on:
  push:
    tags: ['v*']
jobs:
  release:
    uses: akira-toriyama/glyph/.github/workflows/release.yml@v0.11.2
    secrets: inherit
EOF
)" "$(cat <<'EOF'
name: release
on:
  push:
    tags: ['v*']
jobs:
  release:
    uses: akira-toriyama/glyph/.github/workflows/release.yml@v0.12.0
    secrets: inherit
EOF
)"

# Sites 4+5 in ONE edit — the pair that must never move separately. Seven repos
# once sat on a v0.8.0 binary behind a v0.10.2 action for three releases.
case_ "install action and the binary it installs move together" "$(cat <<'EOF'
jobs:
  release:
    steps:
      - name: install glyph
        uses: akira-toriyama/glyph/.github/actions/install@v0.10.2
        with:
          version: v0.8.0
          token: ${{ github.token }}
EOF
)" "$(cat <<'EOF'
jobs:
  release:
    steps:
      - name: install glyph
        uses: akira-toriyama/glyph/.github/actions/install@v0.12.0
        with:
          version: v0.12.0
          token: ${{ github.token }}
EOF
)"

# The other spelling in the fleet: the `uses:` IS the list item.
case_ "bare install item moves both pins" "$(cat <<'EOF'
jobs:
  release:
    steps:
      - uses: akira-toriyama/glyph/.github/actions/install@v0.11.2
        with:
          version: v0.11.2
EOF
)" "$(cat <<'EOF'
jobs:
  release:
    steps:
      - uses: akira-toriyama/glyph/.github/actions/install@v0.12.0
        with:
          version: v0.12.0
EOF
)"

# ---------------------------------------------------------------------------
# Trap 2: commented placeholders must STAY placeholders.
#
# glyph's reusables ship a commented caller stub pinned to `@vX.Y.Z`, and glyph's
# own internal/workflows test fails a CONCRETE version there — a tag is cut on an
# already-frozen tree, so any version written into that comment is stale the
# moment it exists. Rewriting it would turn a fleet automation into the thing
# that breaks glyph's CI.
#
# The executable `uses:` below is the positive control: without it this case
# would pass just as well against a rewriter that matches nothing at all.
# ---------------------------------------------------------------------------
case_ "a commented placeholder survives while the real pin moves" "$(cat <<'EOF'
# Example caller:
#   jobs:
#     lint:
#       uses: akira-toriyama/glyph/.github/workflows/lint.yml@vX.Y.Z
jobs:
  lint:
    uses: akira-toriyama/glyph/.github/workflows/lint.yml@v0.11.2
EOF
)" "$(cat <<'EOF'
# Example caller:
#   jobs:
#     lint:
#       uses: akira-toriyama/glyph/.github/workflows/lint.yml@vX.Y.Z
jobs:
  lint:
    uses: akira-toriyama/glyph/.github/workflows/lint.yml@v0.12.0
EOF
)"

# ---------------------------------------------------------------------------
# Trap 3: `version:` is a generic input name.
#
# taplo, every setup-*, half the fleet's third-party steps take one. The only
# thing that makes an occurrence a glyph pin is the STEP it sits in — so the
# glyph step's version moves (positive control) and the neighbour's does not.
# ---------------------------------------------------------------------------
case_ "a neighbouring step's version: is left alone" "$(cat <<'EOF'
jobs:
  release:
    steps:
      - uses: akira-toriyama/glyph/.github/actions/install@v0.11.2
        with:
          version: v0.11.2
      - uses: uncle-org/taplo-action@v1
        with:
          version: v9.9.9
      - uses: actions/setup-go@v5
        with:
          version: 1.24.0
EOF
)" "$(cat <<'EOF'
jobs:
  release:
    steps:
      - uses: akira-toriyama/glyph/.github/actions/install@v0.12.0
        with:
          version: v0.12.0
      - uses: uncle-org/taplo-action@v1
        with:
          version: v9.9.9
      - uses: actions/setup-go@v5
        with:
          version: 1.24.0
EOF
)"

# A decoy key inside the glyph step itself. `glyph-version:` ends in `version:`;
# only the `[ \t{,]` guard keeps it from reading as one.
case_ "glyph-version: is not read as version:" "$(cat <<'EOF'
jobs:
  release:
    steps:
      - uses: akira-toriyama/glyph/.github/actions/install@v0.11.2
        with:
          version: v0.11.2
          glyph-version: v9.9.9
EOF
)" "$(cat <<'EOF'
jobs:
  release:
    steps:
      - uses: akira-toriyama/glyph/.github/actions/install@v0.12.0
        with:
          version: v0.12.0
          glyph-version: v9.9.9
EOF
)"

# ---------------------------------------------------------------------------
# Everything around the pin survives the substitution.
# ---------------------------------------------------------------------------
case_ "a trailing comment survives the retag" "$(cat <<'EOF'
jobs:
  lint:
    uses: akira-toriyama/glyph/.github/workflows/lint.yml@v0.11.2 # bumped 2026-07-26
EOF
)" "$(cat <<'EOF'
jobs:
  lint:
    uses: akira-toriyama/glyph/.github/workflows/lint.yml@v0.12.0 # bumped 2026-07-26
EOF
)"

case_ "quotes survive on both sites" "$(cat <<'EOF'
jobs:
  release:
    steps:
      - uses: "akira-toriyama/glyph/.github/actions/install@v0.11.2"
        with:
          version: "v0.11.2"
EOF
)" "$(cat <<'EOF'
jobs:
  release:
    steps:
      - uses: "akira-toriyama/glyph/.github/actions/install@v0.12.0"
        with:
          version: "v0.12.0"
EOF
)"

case_ "flow-style with: block" "$(cat <<'EOF'
jobs:
  release:
    steps:
      - uses: akira-toriyama/glyph/.github/actions/install@v0.11.2
        with: { version: v0.11.2, token: x }
EOF
)" "$(cat <<'EOF'
jobs:
  release:
    steps:
      - uses: akira-toriyama/glyph/.github/actions/install@v0.12.0
        with: { version: v0.12.0, token: x }
EOF
)"

# ---------------------------------------------------------------------------
# Refs that are not a concrete release tag ARE fixable — that is the point of
# moving them. Each of these is drift by definition (it can resolve elsewhere
# tomorrow), and the audit reports it as such.
# ---------------------------------------------------------------------------
case_ "a branch ref is pinned to the release" "$(cat <<'EOF'
jobs:
  lint:
    uses: akira-toriyama/glyph/.github/workflows/lint.yml@main
EOF
)" "$(cat <<'EOF'
jobs:
  lint:
    uses: akira-toriyama/glyph/.github/workflows/lint.yml@v0.12.0
EOF
)"

# Losing the `uses:` match once discarded the block tag with it, hiding the
# BINARY pin inside the step. Both must move here.
case_ "a SHA-pinned action and its stale binary both move" "$(cat <<'EOF'
jobs:
  release:
    steps:
      - uses: akira-toriyama/glyph/.github/actions/install@0f9d1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f
        with:
          version: v0.8.0
EOF
)" "$(cat <<'EOF'
jobs:
  release:
    steps:
      - uses: akira-toriyama/glyph/.github/actions/install@v0.12.0
        with:
          version: v0.12.0
EOF
)"

case_ "a prerelease is moved to the release" "$(cat <<'EOF'
jobs:
  lint:
    uses: akira-toriyama/glyph/.github/workflows/lint.yml@v0.12.0-rc.1
EOF
)" "$(cat <<'EOF'
jobs:
  lint:
    uses: akira-toriyama/glyph/.github/workflows/lint.yml@v0.12.0
EOF
)"

# The pin-probe residue (glyph-test, v3.0.0 rollout): replacing only the value's
# release-shaped prefix glues want onto the leftover `-rc.3`, writes the drift
# right back, and still reports a clean rewrite — the completeness check reads
# the result through the same truncating scanner, so nothing downstream notices.
case_ "a prerelease version: moves whole — no suffix residue" "$(cat <<'EOF'
jobs:
  probe:
    steps:
      - uses: akira-toriyama/glyph/.github/actions/install@v0.12.0
        with:
          version: v0.12.0-rc.3
          token: ${{ github.token }}
EOF
)" "$(cat <<'EOF'
jobs:
  probe:
    steps:
      - uses: akira-toriyama/glyph/.github/actions/install@v0.12.0
        with:
          version: v0.12.0
          token: ${{ github.token }}
EOF
)"

# ---------------------------------------------------------------------------
# Files that must come back untouched. `same_` asserts byte equality, so a
# rewriter that "helpfully" reformatted anything fails here.
# ---------------------------------------------------------------------------

# Already level: the caller compares content to decide whether to write, so an
# unchanged file MUST be unchanged or every run opens the same PR again.
same_ "an already-level file is returned byte-for-byte" "$(cat <<'EOF'
jobs:
  release:
    steps:
      - uses: akira-toriyama/glyph/.github/actions/install@v0.12.0
        with:
          version: v0.12.0
EOF
)"

# glyph's own reusables reach the composite by relative path against a checkout
# of glyph at the caller's pinned commit, and COMPUTE the version. Nothing here
# is a hand-maintained pin — rewriting it would break glyph's own release.
same_ "glyph's own relative install is not a pin to move" "$(cat <<'EOF'
jobs:
  lint:
    steps:
      - name: Install glyph (pinned release binary)
        uses: ./.glyph-action/.github/actions/install
        with:
          version: ${{ steps.glyph.outputs.version }}
          token: ${{ github.token }}
EOF
)"

same_ "a workflow with no glyph reference is untouched" "$(cat <<'EOF'
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
)"

# ---------------------------------------------------------------------------
# Refusals. Both write NOTHING to stdout — a caller that redirects stdout into
# the file it is about to PUT must not be handed a half-rewrite.
# ---------------------------------------------------------------------------

# Inserting a `version:` is a structural edit, not a pin move. The audit is
# already red about this file and staying red is the correct outcome.
refuse_ "an install step with no version: is refused, not guessed at" "$(cat <<'EOF'
jobs:
  release:
    steps:
      - uses: akira-toriyama/glyph/.github/actions/install@v0.11.2
        with:
          token: ${{ github.token }}
EOF
)" 4 "version-missing"

# Someone wrote that expression on purpose; freezing it to a literal would be a
# silent behaviour change in a file this script does not own.
refuse_ "an install step with a computed version is refused" "$(cat <<'EOF'
jobs:
  release:
    steps:
      - uses: akira-toriyama/glyph/.github/actions/install@v0.11.2
        with:
          version: ${{ env.GLYPH_VERSION }}
EOF
)" 4 "version-unreadable"

# The fleet is levelled on ONE concrete release tag. Accepting a branch — or an
# empty argument from an unset workflow input — as the TARGET would re-point
# every consumer in the fleet at a moving ref in one run.
for bad in main v0 v0.12 v0.12.0-rc.1 latest ''; do
  got="$(printf 'jobs: {}\n' | bash "$script" "$bad" 2>&1)"; rc=$?
  if [ "$rc" -eq 2 ]; then
    echo "ok   - target '$bad' is rejected as a usage error"
  else
    fail_ "target '$bad' is rejected as a usage error" "got rc=$rc" "$(printf '%s' "$got" | head -3)"
  fi
done

# ---------------------------------------------------------------------------
# A file that ships without a trailing newline must come back without one. awk
# terminates its last line either way, so this is a real byte difference — and
# it would make "unchanged" untrue for every such file, forever.
# ---------------------------------------------------------------------------
nonl_in="$(mktemp)"; nonl_out="$(mktemp)"
printf 'jobs:\n  lint:\n    uses: akira-toriyama/glyph/.github/workflows/lint.yml@v0.11.2' > "$nonl_in"
if bash "$script" "$WANT" < "$nonl_in" > "$nonl_out" 2>/dev/null &&
   [ "$(tail -c 1 "$nonl_out" | wc -l | tr -d ' ')" -eq 0 ] &&
   grep -q "lint.yml@$WANT\$" "$nonl_out" &&
   [ "$(wc -l < "$nonl_in" | tr -d ' ')" = "$(wc -l < "$nonl_out" | tr -d ' ')" ]; then
  echo "ok   - a file with no trailing newline keeps not having one"
else
  fail_ "a file with no trailing newline keeps not having one" \
    "in:  $(wc -c < "$nonl_in") bytes, out: $(wc -c < "$nonl_out") bytes" \
    "$(cat "$nonl_out")"
fi
rm -f "$nonl_in" "$nonl_out"

# ---------------------------------------------------------------------------
# The canonical itself. fleet/commit-lint.yml is the file the audit reads the
# fleet's intended version OUT of, so the rewriter must agree with it exactly:
# rewriting the live canonical to the tag it already carries must be a no-op.
# This is the case that fails when the real fleet file grows a shape none of the
# invented documents above cover.
# ---------------------------------------------------------------------------
canonical="$root/fleet/commit-lint.yml"
if [ ! -f "$canonical" ]; then
  fail_ "the live canonical rewrites to itself" "missing $canonical"
else
  canon_tag="$(bash "$root/scripts/glyph-pin-scan.sh" < "$canonical" | awk -F'\t' '$1 == "uses" { print $2; exit }')"
  if [ -z "$canon_tag" ]; then
    fail_ "the live canonical rewrites to itself" "could not read a pin out of $canonical"
  elif out="$(bash "$script" "$canon_tag" < "$canonical" 2>&1)" && [ "$out" = "$(cat "$canonical")" ]; then
    echo "ok   - the live canonical rewrites to itself ($canon_tag)"
  else
    fail_ "the live canonical rewrites to itself" \
      "$(diff <(cat "$canonical") <(printf '%s\n' "$out") | head -10)"
  fi
fi

# ---------------------------------------------------------------------------
# The two runtime guards, pinned by MUTATION.
#
# Everything above proves the rewriter is right on inputs it handles correctly.
# Neither of the script's own refusals — (a) confinement, (b) the re-scan oracle
# — can be reached that way: they fire only when the substitution itself is
# wrong, and a passing case by definition has no wrong substitution in it. Left
# untested they are decoration, and the first future edit that quietly disables
# one would look exactly like this file passing.
#
# So break the script on purpose, in a copy, and require the refusal. Same idea
# as go-bite-self in self-test.yml: hold the guard to the standard it enforces.
# ---------------------------------------------------------------------------
mutant_() { # <name> <sed-expression> <expected-rc> <yaml>
  local name="$1" expr="$2" want_rc="$3" in_="$4" dir rc out
  dir="$(mktemp -d)"
  cp "$root/scripts/glyph-pin-scan.sh" "$root/scripts/glyph-pin-rewrite.sh" "$dir/"
  if ! sed "$expr" "$root/scripts/glyph-pin-rewrite.sh" > "$dir/glyph-pin-rewrite.sh"; then
    fail_ "$name" "sed failed to build the mutant"
    rm -rf "$dir"; return
  fi
  # A mutation that no longer applies is NOT a pass. The line it targets was
  # renamed or deleted, so the guard below is unproven and the ledger has to be
  # re-derived — silently skipping is how a guard loses its only defender.
  if cmp -s "$dir/glyph-pin-rewrite.sh" "$root/scripts/glyph-pin-rewrite.sh"; then
    fail_ "$name" "the mutation changed nothing — re-derive it against the current script" \
      "sed: $expr"
    rm -rf "$dir"; return
  fi
  out="$(printf '%s\n' "$in_" | bash "$dir/glyph-pin-rewrite.sh" "$WANT" 2>&1)"; rc=$?
  if [ "$rc" -eq "$want_rc" ]; then
    echo "ok   - $name"
  else
    fail_ "$name" "the broken rewriter exited $rc, not $want_rc — the guard did not fire" \
      "$(printf '%s' "$out" | head -6)"
  fi
  rm -rf "$dir"
}

# A file whose real pin is one line under a commented placeholder: the shape the
# whole fleet's workflow files have.
MUT_YAML="$(cat <<'EOF'
# Example caller:
#   uses: akira-toriyama/glyph/.github/workflows/lint.yml@vX.Y.Z
jobs:
  lint:
    uses: akira-toriyama/glyph/.github/workflows/lint.yml@v0.11.2
EOF
)"

# (b) the re-scan oracle. Make the retag match nothing: the file comes back
# byte-identical, every line-level check is satisfied (nothing moved!), and
# without the oracle the caller is told the rewrite succeeded. It would then
# compare, find no change, skip the repo — and the fleet would sit drifted while
# the mechanism reported it had nothing to do.
mutant_ "a rewrite that silently matches nothing is caught, not reported clean" \
  's@if (!match(line, /akira@if (1) return line; if (!match(line, /akira@' \
  3 "$MUT_YAML"

# (a) confinement. Drop the "only these lines" guard and the retag runs on every
# line — including the commented placeholder glyph's own CI fails a concrete
# version in. Without the check this ships a PR that breaks glyph.
mutant_ "a rewrite that escapes its line set is caught before anything is written" \
  's|if (NR in U) line = retag(line)|if (1) line = retag(line)|' \
  3 "$MUT_YAML"

[ "$fails" -eq 0 ] || { echo "$fails glyph-pin-rewrite case(s) failed"; exit 1; }
echo "all glyph-pin-rewrite cases passed"
