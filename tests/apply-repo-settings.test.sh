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
#   $STUB_HOME/stale-writes           present = every -X call returns 2xx but changes
#                                     nothing (the read-back must catch it)
#   $STUB_HOME/alerts-off.<name>      present = that repo's vulnerability-alerts GET
#                                     404s, i.e. Dependabot alerts are OFF (drift)
#   $STUB_HOME/dbom-off.<name>        present = delete_branch_on_merge is false (drift)
#   $STUB_HOME/cs-off.<name>          present = code scanning is not-configured with
#                                     `actions` detected (drift; the async PATCH)
#   $STUB_HOME/unreadable.<name>      present = every GET on that repo fails 403
#                                     (rate limit / degraded token) — no body
#   $STUB_HOME/unreadable-after-write.<name>
#                                     present = the first mutation the stub accepts
#                                     on that repo creates unreadable.<name>: the
#                                     write lands, the read-back cannot read
#   $STUB_HOME/flaky.<name>           present = the NEXT GET on that repo fails 502
#                                     once (the stub removes the marker), then works
#   $STUB_HOME/protection-unreadable.<name>
#                                     present = the branch-protection GET fails 403
#                                     (not the 404 that means "unprotected")
#   $STUB_HOME/protection.<name>      that repo's branch protection JSON (absent =
#                                     404, an unprotected branch)
#   $STUB_HOME/check-runs.<name>      that repo's HEAD check-run names, one per
#                                     line (absent = a repo whose HEAD ran nothing)
#   $STUB_HOME/check-runs-fail        present = the check-runs GET fails (transient)
#   $STUB_HOME/mutations.log          written by the stub: one `VERB path` per -X
#                                     call it accepted (what the script tried to write)
# A mutation the stub accepts FLIPS its state (alerts-off.<name> is removed, the
# protection body is recorded), so the script's read-back sees what a real API
# would — unless stale-writes is present.
cat >"$stub_dir/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
if [ "${1:-}" = "repo" ] && [ "${2:-}" = "list" ]; then
  cat "$STUB_HOME/repos"; exit 0
fi
[ "${1:-}" = "api" ] || { echo "stub gh: unhandled command: $*" >&2; exit 64; }
shift
verb=GET; path=""; jqexpr=""; body=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -X) verb="$2"; shift 2 ;;
    -H|-F|-f) shift 2 ;;
    --jq) jqexpr="$2"; shift 2 ;;
    --input) [ "$2" = "-" ] && body="$(cat)"; shift 2 ;;
    -*) shift ;;
    *) [ -n "$path" ] || path="$1"; shift ;;
  esac
done
emit() { if [ -n "$jqexpr" ]; then printf '%s' "$1" | jq -r "$jqexpr"; else printf '%s\n' "$1"; fi; }
# repos/<owner>/<name>[/<rest>] — peel the segments one at a time. `${path#repos/*/}`
# looks like it would do this in one step, but for the bare `repos/owner/name` it
# strips through the SECOND slash and leaves the repo name as the "rest".
p="${path#repos/}"; p="${p#*/}"        # <name>[/<rest>]
name="${p%%/*}"
if [ "$p" = "$name" ]; then rest=""; else rest="${p#*/}"; fi
if [ "$verb" != GET ]; then
  [ -e "$STUB_HOME/fail-mutations" ] && exit 1
  echo "$verb $path" >>"$STUB_HOME/mutations.log"
  [ -e "$STUB_HOME/stale-writes" ] && exit 0
  case "$rest" in
    "")                           rm -f "$STUB_HOME/dbom-off.$name" ;;
    vulnerability-alerts)         rm -f "$STUB_HOME/alerts-off.$name" ;;
    code-scanning/default-setup)  rm -f "$STUB_HOME/cs-off.$name" ;;
    branches/main/protection)
      printf '%s' "$body" | jq -c '{required_status_checks: .required_status_checks}' >"$STUB_HOME/protection.$name" ;;
    branches/main/protection/required_status_checks)
      printf '%s' "$body" | jq -c '{required_status_checks: .}' >"$STUB_HOME/protection.$name" ;;
  esac
  [ -e "$STUB_HOME/unreadable-after-write.$name" ] && : >"$STUB_HOME/unreadable.$name"
  exit 0
fi
if [ -e "$STUB_HOME/unreadable.$name" ]; then
  echo "gh: API rate limit exceeded (HTTP 403)" >&2; exit 1
fi
if [ -e "$STUB_HOME/flaky.$name" ]; then
  rm -f "$STUB_HOME/flaky.$name"
  echo "gh: Bad Gateway (HTTP 502)" >&2; exit 1
fi
case "$rest" in
  "")
    if [ -e "$STUB_HOME/dbom-off.$name" ]; then emit '{"delete_branch_on_merge":false}'
    else emit '{"delete_branch_on_merge":true}'; fi ;;
  private-vulnerability-reporting)           emit '{"enabled":true}' ;;
  code-scanning/default-setup)
    if [ -e "$STUB_HOME/cs-off.$name" ]; then emit '{"state":"not-configured","languages":["actions"]}'
    else emit '{"state":"configured","languages":["actions"]}'; fi ;;
  vulnerability-alerts)
    if [ -e "$STUB_HOME/alerts-off.$name" ]; then echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
    exit 0 ;;
  automated-security-fixes)                  emit '{"enabled":true}' ;;
  rulesets)                                  emit '[]' ;;
  commits/HEAD/check-runs)
    [ -e "$STUB_HOME/check-runs-fail" ] && exit 1
    f="$STUB_HOME/check-runs.$name"
    if [ -f "$f" ]; then
      emit "$(jq -Rn '{check_runs: [inputs | {name: .}]}' <"$f")"
    else
      emit '{"check_runs":[]}'
    fi ;;
  branches/main/protection)
    if [ -e "$STUB_HOME/protection-unreadable.$name" ]; then echo "gh: API rate limit exceeded (HTTP 403)" >&2; exit 1; fi
    f="$STUB_HOME/protection.$name"
    if [ -f "$f" ]; then emit "$(cat "$f")"; else echo "gh: Branch not protected (HTTP 404)" >&2; exit 1; fi ;;
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

# A fleet in which `hasit` carries the CANONICAL caller and `lacks` carries none.
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

# The regression itself: a fleet still on the RETIRED hub reusable matches
# nothing. That must be a loud, non-zero failure, not a clean sweep.
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

# WITH_PROTECTION off: the zero-match check must stay quiet (it examined nothing).
run_script
if [ "$RC" -eq 0 ] && ! printf '%s' "$OUT" | grep -q "matched NONE"; then
  pass "the zero-match check is silent when protection is not requested"
else
  fail "the zero-match check is silent when protection is not requested"
fi

# APPLY mode in which every mutation fails (an expired token) must not report
# success. This is the second half of the same defect class: run() printed
# ::FAILED:: per call, counted nothing, and the script exited 0 regardless.
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

# ONLY= must still work — it is how the operator canaries one repo, and the
# fleet-change policy's canary stage depends on it.
STUB_HOME="$stub_dir/fleet-a"
run_script ONLY=lacks
if [ "$RC" -eq 0 ] \
  && printf '%s' "$OUT" | grep -q "== lacks (PUBLIC) ==" \
  && ! printf '%s' "$OUT" | grep -q "== hasit (PUBLIC) =="; then
  pass "ONLY= limits the run to one repo"
else
  fail "ONLY= limits the run to one repo"
fi

# The `build` context (t-jvdr): required ONLY where a check-run named `build`
# exists on the default branch HEAD — ground truth, because a required context
# that no run produces wedges every PR invisibly (the t-c51t shape). The swift
# family's `build` was hand-added per repo; every new repo opened the hole again.
STUB_HOME="$stub_dir/fleet-build"; mkdir -p "$STUB_HOME"
printf 'appish\tPUBLIC\nlibish\tPUBLIC\n' >"$STUB_HOME/repos"
cp "$canonical" "$STUB_HOME/commit-lint.appish"
cp "$canonical" "$STUB_HOME/commit-lint.libish"
printf 'build\nbite / bite\nAnalyze (actions)\n' >"$STUB_HOME/check-runs.appish"
# libish has runs on HEAD, none of them named `build`.
printf 'test-macos\ntest-linux\n' >"$STUB_HOME/check-runs.libish"

run_script WITH_PROTECTION=1
if [ "$RC" -eq 0 ] \
  && printf '%s' "$OUT" | grep -q "would: protection(PUT new): require \[build, lint / lint\]" \
  && printf '%s' "$OUT" | grep -q "would: protection(PUT new): require \[lint / lint\] (admin bypass"; then
  pass "build is required where HEAD demonstrably runs it, and only there"
else
  fail "build is required where HEAD demonstrably runs it, and only there"
fi

# A transient check-runs failure must NOT decide "no build" silently: it warns,
# requires lint alone this run, and leaves build to the next (idempotent) run.
: >"$STUB_HOME/check-runs-fail"
run_script WITH_PROTECTION=1
if [ "$RC" -eq 0 ] \
  && printf '%s' "$OUT" | grep -q "warn: cannot read check-runs on appish@HEAD" \
  && printf '%s' "$OUT" | grep -q "would: protection(PUT new): require \[lint / lint\] (admin bypass"; then
  pass "an unreadable check-run probe warns instead of silently deciding"
else
  fail "an unreadable check-run probe warns instead of silently deciding"
fi
rm -f "$STUB_HOME/check-runs-fail"

# A compliant fleet is a quiet green in both modes: the scheduled reconcile
# (repo-settings-sync.yml) runs APPLY=1 daily, and a run that writes nothing
# must say so under exit 0, not cry wolf.
STUB_HOME="$stub_dir/fleet-clean"; mkdir -p "$STUB_HOME"
printf 'hasit\tPUBLIC\n' >"$STUB_HOME/repos"
cp "$canonical" "$STUB_HOME/commit-lint.hasit"

run_script APPLY=1
if [ "$RC" -eq 0 ] \
  && ! printf '%s' "$OUT" | grep -qE "would:|landed:|applied:|::FAILED::" \
  && printf '%s' "$OUT" | grep -q "landed=0 async=0 failed=0 unreadable=0" \
  && [ ! -e "$STUB_HOME/mutations.log" ]; then
  pass "APPLY on a compliant fleet writes nothing and stays green"
else
  fail "APPLY on a compliant fleet writes nothing and stays green"
fi

# A drifted repo (a freshly created one, born with Dependabot alerts OFF — the
# t-qsea / t-4ghh shape) is repaired, and `landed:` is the READ-BACK, not the
# 2xx: the stub flips its state on the PUT and the script re-reads it.
STUB_HOME="$stub_dir/fleet-drifted"; mkdir -p "$STUB_HOME"
printf 'hasit\tPUBLIC\nfresh\tPUBLIC\n' >"$STUB_HOME/repos"
cp "$canonical" "$STUB_HOME/commit-lint.hasit"
: >"$STUB_HOME/alerts-off.fresh"

run_script
if [ "$RC" -eq 0 ] \
  && printf '%s' "$OUT" | grep -q "would: vulnerability-alerts=on" \
  && printf '%s' "$OUT" | grep -q "DRY-RUN — NOTHING WAS APPLIED): would=1 unreadable=0" \
  && [ ! -e "$STUB_HOME/mutations.log" ]; then
  pass "a dry run reports drift, writes nothing, and exits 0 (the operator's preview)"
else
  fail "a dry run reports drift, writes nothing, and exits 0 (the operator's preview)"
fi

run_script APPLY=1
if [ "$RC" -eq 0 ] \
  && printf '%s' "$OUT" | grep -q "landed: vulnerability-alerts=on" \
  && printf '%s' "$OUT" | grep -q "landed=1 async=0 failed=0 unreadable=0" \
  && [ "$(cat "$STUB_HOME/mutations.log")" = "PUT repos/akira-toriyama/fresh/vulnerability-alerts" ]; then
  pass "APPLY repairs a drifted repo and reads the setting back"
else
  fail "APPLY repairs a drifted repo and reads the setting back"
fi

# The same drift, but the API returns 2xx without changing anything: a 2xx is
# not "applied". The read-back must turn it into a ::FAILED:: and a non-zero exit.
STUB_HOME="$stub_dir/fleet-stale"; mkdir -p "$STUB_HOME"
printf 'fresh\tPUBLIC\n' >"$STUB_HOME/repos"
: >"$STUB_HOME/alerts-off.fresh"
: >"$STUB_HOME/stale-writes"

run_script APPLY=1
if [ "$RC" -ne 0 ] \
  && printf '%s' "$OUT" | grep -q "::FAILED:: vulnerability-alerts=on — the call returned 2xx but the read-back does not show it" \
  && ! printf '%s' "$OUT" | grep -q "landed:"; then
  pass "a 2xx whose read-back does not show the change is a FAILED mutation"
else
  fail "a 2xx whose read-back does not show the change is a FAILED mutation"
fi

# A setting the run cannot READ is neither compliant nor drifted. It is reported
# as `unreadable:`, never written to, and fails the run — in BOTH modes. The old
# shape read every failed GET as drift: 37 repos x 2 false `would:` lines under a
# rate-limited token on 2026-09-24, and in APPLY mode a PUT/PATCH on each (t-4ghh).
STUB_HOME="$stub_dir/fleet-unreadable"; mkdir -p "$STUB_HOME"
printf 'hasit\tPUBLIC\nghost\tPUBLIC\n' >"$STUB_HOME/repos"
cp "$canonical" "$STUB_HOME/commit-lint.hasit"
: >"$STUB_HOME/unreadable.ghost"

run_script
if [ "$RC" -ne 0 ] \
  && ! printf '%s' "$OUT" | grep -q "would:" \
  && [ "$(printf '%s\n' "$OUT" | grep -c "unreadable: .* in ghost")" -eq 5 ] \
  && printf '%s' "$OUT" | grep -q "would=0 unreadable=5" \
  && printf '%s' "$OUT" | grep -q "5 setting(s) could not be read"; then
  pass "an unreadable repo is reported per setting, never counted as drift, and fails the dry run"
else
  fail "an unreadable repo is reported per setting, never counted as drift, and fails the dry run"
fi

run_script APPLY=1
if [ "$RC" -ne 0 ] \
  && ! printf '%s' "$OUT" | grep -qE "landed:|applied:|::FAILED::" \
  && [ ! -e "$STUB_HOME/mutations.log" ] \
  && printf '%s' "$OUT" | grep -q "landed=0 async=0 failed=0 unreadable=5"; then
  pass "APPLY never writes to a setting it could not read"
else
  fail "APPLY never writes to a setting it could not read"
fi

# The read-back has the same three answers as the pre-read. A write that lands
# and is then unreadable (the rate limit runs out mid-run) is `unreadable:`, not
# "::FAILED:: … the read-back does not show it" — that sentence would be false,
# and the tally would say a mutation failed when it did not.
STUB_HOME="$stub_dir/fleet-readback-lost"; mkdir -p "$STUB_HOME"
printf 'fresh\tPUBLIC\n' >"$STUB_HOME/repos"
: >"$STUB_HOME/alerts-off.fresh"
: >"$STUB_HOME/unreadable-after-write.fresh"

# unreadable=2: the read-back, and the automated-security-fixes pre-read that
# follows it on the same now-unreadable repo (never written, as above).
run_script APPLY=1
if [ "$RC" -ne 0 ] \
  && printf '%s' "$OUT" | grep -q "unreadable: vulnerability-alerts=on in fresh — read-back after the write: the call returned 2xx" \
  && ! printf '%s' "$OUT" | grep -qE "::FAILED::|landed:" \
  && printf '%s' "$OUT" | grep -q "landed=0 async=0 failed=0 unreadable=2" \
  && [ "$(cat "$STUB_HOME/mutations.log")" = "PUT repos/akira-toriyama/fresh/vulnerability-alerts" ]; then
  pass "a write whose read-back cannot read is unreadable, not a failed mutation"
else
  fail "a write whose read-back cannot read is unreadable, not a failed mutation"
fi

# One transient failure is retried, not reported: a 502 on the first GET and a
# clean answer on the second is a normal run.
STUB_HOME="$stub_dir/fleet-flaky"; mkdir -p "$STUB_HOME"
printf 'blip\tPUBLIC\n' >"$STUB_HOME/repos"
: >"$STUB_HOME/flaky.blip"

run_script
if [ "$RC" -eq 0 ] \
  && ! printf '%s' "$OUT" | grep -qE "unreadable:|would:" \
  && printf '%s' "$OUT" | grep -q "would=0 unreadable=0 across 1 repo(s)"; then
  pass "a single transient GET failure is retried and leaves no trace"
else
  fail "a single transient GET failure is retried and leaves no trace"
fi

# The other baseline drifts, and the one asynchronous write. delete_branch_on_merge
# is read back like the rest; code scanning is `applied:` (the API validates it
# after the PATCH returns) and counted apart, so a repo re-applied every day is
# visible in the summary instead of hiding in a `landed=` it never earned.
STUB_HOME="$stub_dir/fleet-born"; mkdir -p "$STUB_HOME"
printf 'born\tPUBLIC\n' >"$STUB_HOME/repos"
: >"$STUB_HOME/dbom-off.born"
: >"$STUB_HOME/cs-off.born"

run_script
if [ "$RC" -eq 0 ] \
  && printf '%s' "$OUT" | grep -q "would: delete_branch_on_merge=true" \
  && printf '%s' "$OUT" | grep -q "would: code-scanning default setup=configured (languages=\[actions\])" \
  && printf '%s' "$OUT" | grep -q "would=2 unreadable=0"; then
  pass "delete_branch_on_merge and code-scanning drift are reported"
else
  fail "delete_branch_on_merge and code-scanning drift are reported"
fi

run_script APPLY=1
if [ "$RC" -eq 0 ] \
  && printf '%s' "$OUT" | grep -q "landed: delete_branch_on_merge=true" \
  && printf '%s' "$OUT" | grep -q "applied: code-scanning default setup=configured (languages=\[actions\]) (asynchronous" \
  && printf '%s' "$OUT" | grep -q "landed=1 async=1 failed=0 unreadable=0" \
  && [ "$(sort "$STUB_HOME/mutations.log" | tr '\n' ' ')" = "PATCH repos/akira-toriyama/born PATCH repos/akira-toriyama/born/code-scanning/default-setup " ]; then
  pass "delete_branch_on_merge is read back; the asynchronous code-scanning write is counted apart"
else
  fail "delete_branch_on_merge is read back; the asynchronous code-scanning write is counted apart"
fi

# A private repo gets three of the five baseline settings; the two that need a
# public repo (private vulnerability reporting, code scanning) are n/a, never
# drift, never written.
STUB_HOME="$stub_dir/fleet-private"; mkdir -p "$STUB_HOME"
printf 'vault\tPRIVATE\n' >"$STUB_HOME/repos"
: >"$STUB_HOME/alerts-off.vault"

run_script APPLY=1
if [ "$RC" -eq 0 ] \
  && printf '%s' "$OUT" | grep -q "n/a: private vuln reporting (private repo)" \
  && printf '%s' "$OUT" | grep -q "n/a: code scanning default setup (private repo" \
  && printf '%s' "$OUT" | grep -q "landed: vulnerability-alerts=on" \
  && printf '%s' "$OUT" | grep -q "landed=1 async=0 failed=0 unreadable=0" \
  && [ "$(cat "$STUB_HOME/mutations.log")" = "PUT repos/akira-toriyama/vault/vulnerability-alerts" ]; then
  pass "a private repo gets the three settings that apply to it and nothing else"
else
  fail "a private repo gets the three settings that apply to it and nothing else"
fi

# ONLY= is the canary. A name that matches nothing must not be a clean canary
# over zero repos.
STUB_HOME="$stub_dir/fleet-a"
run_script ONLY=lacsk APPLY=1
if [ "$RC" -ne 0 ] \
  && printf '%s' "$OUT" | grep -q "ONLY=lacsk matched no repo" \
  && printf '%s' "$OUT" | grep -q "across 0 repo(s)"; then
  pass "ONLY= naming no repo is a loud non-zero, not a clean canary"
else
  fail "ONLY= naming no repo is a loud non-zero, not a clean canary"
fi

# Branch protection (opt-in) has the same contract, and a sharper failure mode:
# a fresh PUT over protection the run merely failed to read would reset
# force-push / reviews / strict on a repo that had them. Only a 404 means
# "unprotected"; anything else is unreadable and untouched.
STUB_HOME="$stub_dir/fleet-protection"; mkdir -p "$STUB_HOME"
printf 'hasit\tPUBLIC\nheld\tPUBLIC\n' >"$STUB_HOME/repos"
cp "$canonical" "$STUB_HOME/commit-lint.hasit"
cp "$canonical" "$STUB_HOME/commit-lint.held"
: >"$STUB_HOME/protection-unreadable.held"

run_script APPLY=1 WITH_PROTECTION=1
if [ "$RC" -ne 0 ] \
  && printf '%s' "$OUT" | grep -q "landed: protection(PUT new): require \[lint / lint\]" \
  && printf '%s' "$OUT" | grep -q "unreadable: branch protection in held" \
  && [ "$(cat "$STUB_HOME/mutations.log")" = "PUT repos/akira-toriyama/hasit/branches/main/protection" ] \
  && jq -e '.required_status_checks.contexts == ["lint / lint"]' "$STUB_HOME/protection.hasit" >/dev/null; then
  pass "protection is read back after the PUT, and unreadable protection is never overwritten"
else
  fail "protection is read back after the PUT, and unreadable protection is never overwritten"
fi

[ "$fails" -eq 0 ] || { echo "$fails apply-repo-settings case(s) failed"; exit 1; }
echo "all apply-repo-settings cases passed"
