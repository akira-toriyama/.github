#!/usr/bin/env bash
# Table-test scripts/apply-repo-settings.sh — the one script here that mutates
# GitHub state across the whole fleet, and until now the only one with no test at
# all. Runs the REAL script (drift-free) against a stubbed `gh` on PATH.
#
# What this exists to stop, concretely: the branch-protection detector matched a
# `uses:` line naming the hub's OWN commit-lint reusable. #82 repointed the
# canonical caller at glyph's reusable on 2026-07-12 and #111 deleted the hub one
# — after which the detector matched ZERO repos, printed `skip(protection): no
# commit-lint caller` for every one of them, applied nothing, and exited 0. Two
# weeks of fleet runs reported a clean sweep while doing nothing at all. Nothing
# could have caught it: no test, and actionlint does not read scripts/.
#
# The load-bearing move is that the caller fixture below is READ LIVE from
# fleet/commit-lint.yml. Repoint the canonical again and this test follows it; break
# the derivation and it goes red. A hand-copied fixture would have rotted exactly
# the way the detector did.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
script="$root/scripts/apply-repo-settings.sh"
canonical="$root/fleet/commit-lint.yml"
fails=0

[ -f "$script" ] || { echo "FAIL - $script is missing"; exit 1; }
[ -f "$canonical" ] || { echo "FAIL - $canonical is missing"; exit 1; }

stub_dir="$(mktemp -d)"
trap 'rm -rf "$stub_dir"' EXIT

# A `gh` that answers from files under $STUB_HOME instead of the network.
#   $STUB_HOME/repos                  the `gh repo list` output (name<TAB>VISIBILITY)
#   $STUB_HOME/commit-lint.<name>     that repo's .github/workflows/commit-lint.yml
#                                     (absent = 404, like a repo with no caller)
#   $STUB_HOME/fail-mutations         present = every -X call fails (403/expired token)
#   $STUB_HOME/alerts-off.<name>      present = that repo's vulnerability-alerts GET
#                                     404s, i.e. Dependabot alerts are OFF (drift)
cat >"$stub_dir/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
if [ "${1:-}" = "repo" ] && [ "${2:-}" = "list" ]; then
  cat "$STUB_HOME/repos"; exit 0
fi
[ "${1:-}" = "api" ] || { echo "stub gh: unhandled command: $*" >&2; exit 64; }
shift
verb=GET; path=""; jqexpr=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -X) verb="$2"; shift 2 ;;
    -H|-F|-f) shift 2 ;;
    --jq) jqexpr="$2"; shift 2 ;;
    --input) shift 2 ;;
    -*) shift ;;
    *) [ -n "$path" ] || path="$1"; shift ;;
  esac
done
if [ "$verb" != GET ]; then
  [ -e "$STUB_HOME/fail-mutations" ] && exit 1
  exit 0
fi
emit() { if [ -n "$jqexpr" ]; then printf '%s' "$1" | jq -r "$jqexpr"; else printf '%s\n' "$1"; fi; }
# repos/<owner>/<name>[/<rest>] — peel the segments one at a time. `${path#repos/*/}`
# looks like it would do this in one step, but for the bare `repos/owner/name` it
# strips through the SECOND slash and leaves the repo name as the "rest".
p="${path#repos/}"; p="${p#*/}"        # <name>[/<rest>]
name="${p%%/*}"
if [ "$p" = "$name" ]; then rest=""; else rest="${p#*/}"; fi
case "$rest" in
  "")                                        emit '{"delete_branch_on_merge":true}' ;;
  private-vulnerability-reporting)           emit '{"enabled":true}' ;;
  code-scanning/default-setup)               emit '{"state":"configured","languages":["actions"]}' ;;
  vulnerability-alerts)
    [ -e "$STUB_HOME/alerts-off.$name" ] && exit 1
    exit 0 ;;
  automated-security-fixes)                  emit '{"enabled":true}' ;;
  rulesets)                                  emit '[]' ;;
  branches/main/protection)                  exit 1 ;;
  contents/.github/workflows/commit-lint.yml)
    f="$STUB_HOME/commit-lint.$name"
    [ -f "$f" ] || exit 1
    cat "$f" ;;
  *)                                         emit '{}' ;;
esac
STUB
chmod +x "$stub_dir/gh"

# run_script [VAR=value ...] — sets OUT (stdout+stderr) and RC. Args are passed
# through `env`, not written as a bare prefix: a VAR=value that arrives via "$@"
# is an ordinary word, and bash would try to execute it as a command.
run_script() {
  OUT="$(PATH="$stub_dir:$PATH" STUB_HOME="$STUB_HOME" env "$@" bash "$script" 2>&1)"; RC=$?
}
pass() { echo "ok   - $1"; }
fail() {
  echo "FAIL - $1 (rc=$RC)"
  printf '%s\n' "$OUT" | awk '{ print "       " $0 }'
  fails=$((fails + 1))
}

# ---------------------------------------------------------------------------
# A fleet in which `hasit` carries the CANONICAL caller and `lacks` carries none.
# ---------------------------------------------------------------------------
STUB_HOME="$stub_dir/fleet-a"; mkdir -p "$STUB_HOME"
printf 'hasit\tPUBLIC\nlacks\tPUBLIC\n' >"$STUB_HOME/repos"
cp "$canonical" "$STUB_HOME/commit-lint.hasit"

run_script WITH_PROTECTION=1
if [ "$RC" -eq 0 ] \
  && printf '%s' "$OUT" | grep -q "skip(protection): no commit-lint caller in lacks" \
  && ! printf '%s' "$OUT" | grep -q "skip(protection): no commit-lint caller in hasit"; then
  pass "the canonical caller is detected; a repo without one is skipped"
else
  fail "the canonical caller is detected; a repo without one is skipped"
fi

# The detector must reach the PUT/PATCH decision for the matching repo. In dry-run
# that surfaces as a `would:` line — proof it got past the grep rather than merely
# not printing a skip.
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "would: protection(PUT new): require \[lint / lint\]"; then
  pass "a detected caller reaches the protection decision"
else
  fail "a detected caller reaches the protection decision"
fi

# ---------------------------------------------------------------------------
# The regression itself: a fleet still on the RETIRED hub reusable matches
# nothing. That must be a loud, non-zero failure, not a clean sweep.
# ---------------------------------------------------------------------------
STUB_HOME="$stub_dir/fleet-retired"; mkdir -p "$STUB_HOME"
printf 'hasit\tPUBLIC\n' >"$STUB_HOME/repos"
cat >"$STUB_HOME/commit-lint.hasit" <<'OLD'
name: commit-lint
on:
  pull_request:
jobs:
  lint:
    uses: akira-toriyama/.github/.github/workflows/commit-lint.yml@v1
OLD

run_script WITH_PROTECTION=1
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "matched NONE"; then
  pass "zero detector matches is a loud non-zero failure"
else
  fail "zero detector matches is a loud non-zero failure"
fi

# ---------------------------------------------------------------------------
# WITH_PROTECTION off: the zero-match check must stay quiet (it examined nothing).
# ---------------------------------------------------------------------------
run_script
if [ "$RC" -eq 0 ] && ! printf '%s' "$OUT" | grep -q "matched NONE"; then
  pass "the zero-match check is silent when protection is not requested"
else
  fail "the zero-match check is silent when protection is not requested"
fi

# ---------------------------------------------------------------------------
# APPLY mode in which every mutation fails (an expired token) must not report
# success. This is the second half of the same defect class: run() printed
# ::FAILED:: per call, counted nothing, and the script exited 0 regardless.
# ---------------------------------------------------------------------------
STUB_HOME="$stub_dir/fleet-403"; mkdir -p "$STUB_HOME"
printf 'hasit\tPUBLIC\n' >"$STUB_HOME/repos"
cp "$canonical" "$STUB_HOME/commit-lint.hasit"
: >"$STUB_HOME/fail-mutations"

run_script APPLY=1 WITH_PROTECTION=1
if [ "$RC" -ne 0 ] \
  && printf '%s' "$OUT" | grep -q "::FAILED::" \
  && printf '%s' "$OUT" | grep -qE "[0-9]+ mutation\(s\) FAILED"; then
  pass "APPLY with failing mutations exits non-zero"
else
  fail "APPLY with failing mutations exits non-zero"
fi

# ---------------------------------------------------------------------------
# ONLY= must still work — it is how the operator canaries one repo, and the
# fleet-change policy's canary stage depends on it.
# ---------------------------------------------------------------------------
STUB_HOME="$stub_dir/fleet-a"
run_script ONLY=lacks
if [ "$RC" -eq 0 ] \
  && printf '%s' "$OUT" | grep -q "== lacks (PUBLIC) ==" \
  && ! printf '%s' "$OUT" | grep -q "== hasit (PUBLIC) =="; then
  pass "ONLY= limits the run to one repo"
else
  fail "ONLY= limits the run to one repo"
fi

# ---------------------------------------------------------------------------
# FAIL_ON_DIFF — the audit mode repo-settings-audit.yml runs on a schedule.
# Both directions: a compliant fleet must stay green (an audit that cries wolf
# gets ignored), and a drifted one must be a loud non-zero, not a wall of
# `would:` lines under exit 0 — which is exactly how 10 repos sat with
# Dependabot alerts OFF for weeks (t-qsea).
# ---------------------------------------------------------------------------
STUB_HOME="$stub_dir/fleet-clean"; mkdir -p "$STUB_HOME"
printf 'hasit\tPUBLIC\n' >"$STUB_HOME/repos"
cp "$canonical" "$STUB_HOME/commit-lint.hasit"

run_script FAIL_ON_DIFF=1
if [ "$RC" -eq 0 ] && ! printf '%s' "$OUT" | grep -q "would:"; then
  pass "FAIL_ON_DIFF on a compliant fleet stays green"
else
  fail "FAIL_ON_DIFF on a compliant fleet stays green"
fi

STUB_HOME="$stub_dir/fleet-drifted"; mkdir -p "$STUB_HOME"
printf 'hasit\tPUBLIC\nfresh\tPUBLIC\n' >"$STUB_HOME/repos"
cp "$canonical" "$STUB_HOME/commit-lint.hasit"
: >"$STUB_HOME/alerts-off.fresh"

run_script FAIL_ON_DIFF=1
if [ "$RC" -ne 0 ] \
  && printf '%s' "$OUT" | grep -q "would: vulnerability-alerts=on" \
  && printf '%s' "$OUT" | grep -qE "[0-9]+ setting\(s\) drifted"; then
  pass "FAIL_ON_DIFF on a drifted fleet is a loud non-zero"
else
  fail "FAIL_ON_DIFF on a drifted fleet is a loud non-zero"
fi

# Without the flag, the same drifted fleet must keep the original contract: a
# plain dry run reports and exits 0 (it is the operator's preview, not a gate).
run_script
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "would: vulnerability-alerts=on"; then
  pass "a plain dry run still reports drift without failing"
else
  fail "a plain dry run still reports drift without failing"
fi

[ "$fails" -eq 0 ] || { echo "$fails apply-repo-settings case(s) failed"; exit 1; }
echo "all apply-repo-settings cases passed"
