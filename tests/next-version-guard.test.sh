#!/usr/bin/env bash
# Table-test actions/next-version-guard/next-version-guard.sh over (next, last,
# pub_latest) triples. Runs the REAL script (drift-free); self-test.yml invokes it
# on ubuntu, and it runs locally too (no GNU-sed dependency). See t-kve5 / t-fqhx.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
script="$root/actions/next-version-guard/next-version-guard.sh"
fails=0

# run_guard <next> <last> <pub_latest>. Sets: OUT, RC, REL, VER.
run_guard() {
  local go; go="$(mktemp)"
  OUT="$(NEXT="$1" LAST="$2" PUB_LATEST="$3" GITHUB_OUTPUT="$go" bash "$script" 2>&1)"; RC=$?
  REL="$(sed -n 's/^release=//p' "$go" | tail -1)"
  VER="$(sed -n 's/^version=//p' "$go" | tail -1)"
  rm -f "$go"
}
pass() { echo "ok   - $1"; }
fail() {
  echo "FAIL - $1 (rc=$RC rel=$REL ver=$VER)"
  # shellcheck disable=SC2001  # per-line indent of captured output — sed is clearest
  echo "$OUT" | sed 's/^/       /'
  fails=$((fails + 1))
}

# next > last, no published floor → release
run_guard v1.2.0 v1.1.0 ""
if [ "$RC" -eq 0 ] && [ "$REL" = "true" ] && [ "$VER" = "v1.2.0" ]; then
  pass "advance, no published floor"
else
  fail "advance, no published floor"
fi

# next == last → no release
run_guard v1.1.0 v1.1.0 ""
if [ "$RC" -eq 0 ] && [ "$REL" = "false" ]; then
  pass "next==last no-op"
else
  fail "next==last no-op"
fi

# empty next → no release
run_guard "" v1.1.0 ""
if [ "$RC" -eq 0 ] && [ "$REL" = "false" ]; then
  pass "empty next no-op"
else
  fail "empty next no-op"
fi

# next == pub_latest → deadlock
run_guard v1.1.0 v1.0.0 v1.1.0
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q "not greater than the latest published"; then
  pass "next==pub_latest deadlocks"
else
  fail "next==pub_latest deadlocks"
fi

# next < pub_latest → deadlock (the t-fqhx regression: would have drafted a rollback)
run_guard v1.0.0 v0.9.0 v1.1.0
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q "not greater than the latest published"; then
  pass "next<pub_latest deadlocks (t-fqhx)"
else
  fail "next<pub_latest deadlocks (t-fqhx)"
fi

# next > pub_latest and > last → release
run_guard v1.2.0 v1.1.0 v1.1.0
if [ "$RC" -eq 0 ] && [ "$REL" = "true" ] && [ "$VER" = "v1.2.0" ]; then
  pass "advance above published floor"
else
  fail "advance above published floor"
fi

[ "$fails" -eq 0 ] || { echo "$fails next-version-guard case(s) failed"; exit 1; }
echo "all next-version-guard cases passed"
