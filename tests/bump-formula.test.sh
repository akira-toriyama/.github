#!/usr/bin/env bash
# Table-test actions/bump-formula/bump-formula.sh against tests/fixtures/tap/*.rb.
# Runs the REAL script (drift-free); self-test.yml invokes this on ubuntu, and it
# runs unchanged on the macOS dev machine — the script under test is POSIX-only
# for exactly that reason (see its header). See t-kve5.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
script="$root/actions/bump-formula/bump-formula.sh"
fixtures="$root/tests/fixtures/tap"
OLDSHA="1111111111111111111111111111111111111111111111111111111111111111"
NEWSHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
fails=0

# run_on <tag> <new_sha> <repo> <formula> <allow_downgrade>
# Runs the script against the CURRENT $WORK — so a case can chain a second bump
# onto the file the first one produced, which is what a real release loop does.
# Sets: OUT (stdout+stderr), RC (exit code).
run_on() {
  OUT="$(TAG="$1" NEW_SHA="$2" REPO="$3" FORMULA="$4" ALLOW_DOWNGRADE="$5" \
         bash "$script" "$WORK" 2>&1)"; RC=$?
}
# run_case <fixture> <tag> <new_sha> <repo> <formula> <allow_downgrade>
# Sets: WORK (a fresh mutable copy of the fixture), plus everything run_on sets.
run_case() {
  WORK="$(mktemp)"; cp "$fixtures/$1" "$WORK"; shift
  run_on "$@"
}
pass() { echo "ok   - $1"; rm -f "$WORK"; }
fail() {
  echo "FAIL - $1 (rc=$RC)"
  # shellcheck disable=SC2001  # per-line indent of captured output — sed is clearest
  echo "$OUT" | sed 's/^/       /'
  rm -f "$WORK"
  fails=$((fails + 1))
}

# plain bump moves url + sha
run_case plain.rb v2.0.0 "$NEWSHA" akira-toriyama/facet facet false
if [ "$RC" -eq 0 ] \
  && grep -q "github.com/akira-toriyama/facet/archive/refs/tags/v2.0.0.tar.gz" "$WORK" \
  && grep -q "sha256 \"$NEWSHA\"" "$WORK"; then
  pass "plain bump moves url+sha"
else
  fail "plain bump moves url+sha"
fi

# resource block: third-party url + sha untouched (#98 bug)
run_case with-resource.rb v2.0.0 "$NEWSHA" akira-toriyama/facet facet false
if [ "$RC" -eq 0 ] \
  && grep -q "github.com/akira-toriyama/facet/archive/refs/tags/v2.0.0.tar.gz" "$WORK" \
  && grep -q "github.com/someone-else/dep/archive/refs/tags/v9.9.9.tar.gz" "$WORK" \
  && grep -q "sha256 \"2222222222222222222222222222222222222222222222222222222222222222\"" "$WORK" \
  && grep -q "sha256 \"$NEWSHA\"" "$WORK"; then
  pass "resource block third-party url+sha untouched (#98)"
else
  fail "resource block third-party url+sha untouched (#98)"
fi

# head spec must not move
run_case with-head.rb v2.0.0 "$NEWSHA" akira-toriyama/facet facet false
if [ "$RC" -eq 0 ] \
  && grep -q 'head "https://github.com/akira-toriyama/facet.git", branch: "main"' "$WORK" \
  && grep -q "github.com/akira-toriyama/facet/archive/refs/tags/v2.0.0.tar.gz" "$WORK"; then
  pass "head line unmoved"
else
  fail "head line unmoved"
fi

# revision line dropped on bump
run_case with-revision.rb v2.0.0 "$NEWSHA" akira-toriyama/facet facet false
if [ "$RC" -eq 0 ] \
  && ! grep -qE '^  revision [0-9]+$' "$WORK" \
  && grep -q "github.com/akira-toriyama/facet/archive/refs/tags/v2.0.0.tar.gz" "$WORK"; then
  pass "revision line dropped"
else
  fail "revision line dropped"
fi

# downgrade refused (default) — exit 1
run_case plain.rb v0.9.0 "$NEWSHA" akira-toriyama/facet facet false
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q "Refusing to move"; then
  pass "downgrade refused"
else
  fail "downgrade refused"
fi

# downgrade allowed with allow-downgrade=true — exit 0, url moved back
run_case plain.rb v0.9.0 "$NEWSHA" akira-toriyama/facet facet true
if [ "$RC" -eq 0 ] \
  && grep -q "github.com/akira-toriyama/facet/archive/refs/tags/v0.9.0.tar.gz" "$WORK"; then
  pass "downgrade allowed with flag"
else
  fail "downgrade allowed with flag"
fi

# same tag + same sha → no-op, file unchanged
run_case plain.rb v1.0.0 "$OLDSHA" akira-toriyama/facet facet false
if [ "$RC" -eq 0 ] \
  && printf '%s' "$OUT" | grep -q "already at v1.0.0" \
  && diff -q "$WORK" "$fixtures/plain.rb" >/dev/null; then
  pass "same tag+sha is no-op"
else
  fail "same tag+sha is no-op"
fi

# url mismatches caller repo → assert loud fail (exit 1), and the formula is left
# BYTE-IDENTICAL. Without the diff this case is vacuous: it reports ok just as
# happily when the rewrite stage is entirely dead, because "URL missing" is also
# what a script that mutates nothing at all prints.
run_case mismatched-url.rb v2.0.0 "$NEWSHA" akira-toriyama/facet facet false
if [ "$RC" -eq 1 ] \
  && printf '%s' "$OUT" | grep -q "tarball URL missing" \
  && diff -q "$WORK" "$fixtures/mismatched-url.rb" >/dev/null; then
  pass "url mismatch loud-fails, formula untouched"
else
  fail "url mismatch loud-fails, formula untouched"
fi

# Two consecutive bumps across the double-digit boundary, on ONE file — the real
# release loop, where each bump reads the formula the previous one wrote. Both
# hops are live today (the fleet is at v0.11.x), and each pins a different thing
# that every other fixture is blind to, because they all sit at single digits:
#
#   v1.9.0 → v1.10.0   is FORWARD, yet lexicographically "v1.10.0" < "v1.9.0" —
#                      a plain `sort` refuses a legitimate release here.
#   v1.10.0 → v1.11.0  requires the url pattern to still MATCH a double-digit
#                      component. Narrow it to `v[0-9][.][0-9][.][0-9]` and every
#                      other case in this table still passes.
run_case double-digit-minor.rb v1.10.0 "$NEWSHA" akira-toriyama/facet facet false
first_rc=$RC
run_on v1.11.0 "$OLDSHA" akira-toriyama/facet facet false
if [ "$first_rc" -eq 0 ] && [ "$RC" -eq 0 ] \
  && grep -q "github.com/akira-toriyama/facet/archive/refs/tags/v1.11.0.tar.gz" "$WORK" \
  && grep -q "sha256 \"$OLDSHA\"" "$WORK"; then
  pass "v1.9.0 → v1.10.0 → v1.11.0 chains across the double-digit boundary"
else
  fail "v1.9.0 → v1.10.0 → v1.11.0 chains across the double-digit boundary"
fi

# A resource vendored from THE SAME repo. with-resource.rb is protected by the
# repo-qualified pattern; here that qualification matches BOTH urls, so only the
# first-match scoping keeps the resource pinned — the one arm no other fixture
# exercises.
run_case with-own-resource.rb v2.0.0 "$NEWSHA" akira-toriyama/facet facet false
if [ "$RC" -eq 0 ] \
  && grep -q "github.com/akira-toriyama/facet/archive/refs/tags/v2.0.0.tar.gz" "$WORK" \
  && grep -q "github.com/akira-toriyama/facet/archive/refs/tags/v0.5.0.tar.gz" "$WORK" \
  && grep -q "sha256 \"3333333333333333333333333333333333333333333333333333333333333333\"" "$WORK" \
  && grep -q "sha256 \"$NEWSHA\"" "$WORK"; then
  pass "same-repo resource url+sha untouched"
else
  fail "same-repo resource url+sha untouched"
fi

# The backward-move refusal must name the SOURCE url's version. With two
# same-repo urls in the file, dropping the `head -1` that picks the first one
# makes `cur` a two-line string, which this exact-message assertion catches and a
# bare "Refusing to move" grep does not.
run_case with-own-resource.rb v0.9.0 "$NEWSHA" akira-toriyama/facet facet false
if [ "$RC" -eq 1 ] \
  && printf '%s' "$OUT" | grep -q "Refusing to move facet BACKWARD (v1.0.0 → v0.9.0)"; then
  pass "refusal names the source version, not the resource's"
else
  fail "refusal names the source version, not the resource's"
fi

[ "$fails" -eq 0 ] || { echo "$fails bump-formula case(s) failed"; exit 1; }
echo "all bump-formula cases passed"
