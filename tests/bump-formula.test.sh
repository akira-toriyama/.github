#!/usr/bin/env bash
# Table-test actions/bump-formula/bump-formula.sh against tests/fixtures/tap/*.rb.
# Runs the REAL script (drift-free); self-test.yml invokes this on ubuntu. Local:
# GNU sed only — on macOS run under linux (Docker ubuntu / gsed). See t-kve5.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
script="$root/actions/bump-formula/bump-formula.sh"
fixtures="$root/tests/fixtures/tap"
OLDSHA="1111111111111111111111111111111111111111111111111111111111111111"
NEWSHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
fails=0

# run_case <fixture> <tag> <new_sha> <repo> <formula> <allow_downgrade>
# Sets: WORK (mutated temp copy), OUT (stdout+stderr), RC (exit code).
run_case() {
  WORK="$(mktemp)"; cp "$fixtures/$1" "$WORK"
  OUT="$(TAG="$2" NEW_SHA="$3" REPO="$4" FORMULA="$5" ALLOW_DOWNGRADE="$6" \
         bash "$script" "$WORK" 2>&1)"; RC=$?
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

# url mismatches caller repo → assert loud fail (exit 1)
run_case mismatched-url.rb v2.0.0 "$NEWSHA" akira-toriyama/facet facet false
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q "tarball URL missing"; then
  pass "url mismatch loud-fails"
else
  fail "url mismatch loud-fails"
fi

[ "$fails" -eq 0 ] || { echo "$fails bump-formula case(s) failed"; exit 1; }
echo "all bump-formula cases passed"
