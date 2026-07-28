#!/usr/bin/env bash
# Table-test scripts/fleet-rollout-gate.sh — the ledger gate that decides
# whether an apply run of fleet-sync may write (t-yyfv). Runs the REAL script
# (drift-free) against throwaway fleet/ directories and a stubbed `gh` on PATH,
# the fleet-commit-bundle.test.sh pattern. Needs bash + jq only.
#
# The property under test: NO combination of ledger state and run scope lets
# bytes reach the fleet without (a) the ledger covering exactly those bytes and
# (b) the rollout having reached the stage that allows that scope. The refusal
# cases matter more than the allow cases — a gate that only ever runs on
# correct input is decoration (the glyph-pin-rewrite rule) — so most of the
# table is refusals, each pinned to its distinct exit code.
#
# The last case is a REAL-TREE invariant, not a fixture: the repo's own
# fleet/rollout.json must be valid and must cover the repo's own fleet/ bytes.
# That is what moves "a canonical changed without a rollout entry" from a red
# daily run (a day late, in a log nobody opens) to a red check on the PR that
# makes the change.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
script="$root/scripts/fleet-rollout-gate.sh"
fails=0

ok() { echo "ok   - $1"; }
bad() {
  echo "FAIL - $1"
  shift
  for line in "$@"; do echo "       $line"; done
  fails=$((fails + 1))
}

[ -f "$script" ] || { echo "FAIL - $script is missing"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL - jq is required"; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# A `gh` that answers GET repos/<hub>/actions/runs/<id> from
# $STUB_HOME/run-<id>.json and 404s anything else.
stub_dir="$work/bin"
mkdir -p "$stub_dir"
cat > "$stub_dir/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
[ "${1:-}" = "api" ] || { echo "stub gh: unhandled command: $*" >&2; exit 64; }
id="${2##*/}"
f="$STUB_HOME/run-$id.json"
[ -f "$f" ] || { echo "HTTP 404: Not Found" >&2; exit 1; }
cat "$f"
STUB
chmod +x "$stub_dir/gh"
stub_home="$work/stub-home"
mkdir -p "$stub_home"

HUB="owner/.github"
NOW="2026-07-30T00:00:00Z"
PAST="2026-07-29T00:00:00Z"
FUTURE="2026-08-01T00:00:00Z"

# One throwaway fleet/ with a couple of canonical-shaped files.
fleet="$work/fleet"
mkdir -p "$fleet/dependabot.d"
printf 'name: canonical-a\n' > "$fleet/a.yml"
printf 'updates: []\n' > "$fleet/dependabot.d/gomod.yml"

ledger="$fleet/rollout.json"

# write_ledger <covers> <stage> <soak-json> <evidence-json>
write_ledger() {
  jq -n --arg covers "$1" --arg stage "$2" --argjson soak "$3" --argjson evidence "$4" \
    '{change: "test change", covers: $covers, stage: $stage, canary: ["canary-repo"], soak_until: $soak, evidence: $evidence}' \
    > "$ledger"
}

# evidence <covers> <run_id>
evidence() {
  jq -n --arg covers "$1" --argjson run "$2" \
    '{canary: {"canary-repo": {run_id: $run, recorded_at: "2026-07-28T00:00:00Z", covers: $covers, reads: []}}}'
}

# expect <name> <want-rc> <only-repo> [<substring the output must carry>]
expect() {
  local name="$1" want="$2" only="$3" substr="${4:-}" out rc
  out="$(ROLLOUT_NOW="$NOW" ROLLOUT_HUB="$HUB" STUB_HOME="$stub_home" \
    PATH="$stub_dir:$PATH" bash "$script" "$ledger" "$only" 2>&1)"
  rc=$?
  if [ "$rc" -ne "$want" ]; then
    bad "$name" "want exit $want, got $rc" "output: $out"
    return
  fi
  if [ -n "$substr" ] && ! printf '%s' "$out" | grep -qF -- "$substr"; then
    bad "$name" "exit $rc as expected, but output lacks '$substr'" "output: $out"
    return
  fi
  ok "$name"
}

# ---------------------------------------------------------------------------
# --print-covers: stable, and blind to the ledger and README (so recording
# evidence or documenting the directory can never change what it covers).
# ---------------------------------------------------------------------------
covers0="$(bash "$script" --print-covers "$ledger")"
write_ledger "$covers0" "canary" null '{"canary":{}}'
printf '# docs\n' > "$fleet/README.md"
covers1="$(bash "$script" --print-covers "$ledger")"
if [ "$covers0" = "$covers1" ]; then
  ok "print-covers ignores the ledger and README.md"
else
  bad "print-covers ignores the ledger and README.md" "before: $covers0" "after: $covers1"
fi
printf 'name: canonical-a (edited)\n' > "$fleet/a.yml"
covers2="$(bash "$script" --print-covers "$ledger")"
if [ "$covers0" != "$covers2" ]; then
  ok "print-covers moves when a canonical moves"
else
  bad "print-covers moves when a canonical moves" "hash did not change"
fi
printf 'name: canonical-a\n' > "$fleet/a.yml"

# ---------------------------------------------------------------------------
# The uncovered-change refusal — the check that ends "merge to main = deploy".
# It outranks EVERY stage: even a fleet-stage ledger with perfect evidence
# refuses bytes it does not cover.
# ---------------------------------------------------------------------------
jq -n '{id: 555, path: ".github/workflows/fleet-sync.yml", conclusion: "success"}' > "$stub_home/run-555.json"
write_ledger "$covers0" "fleet" "\"$PAST\"" "$(evidence "$covers0" 555)"
printf 'name: canonical-b\n' > "$fleet/b.yml"
expect "an uncovered canonical change refuses everything, even at stage fleet" 11 "" "without a rollout entry"
rm "$fleet/b.yml"

# ---------------------------------------------------------------------------
# Stage "canary": exactly the listed canary may be written, nothing else.
# ---------------------------------------------------------------------------
write_ledger "$covers0" "canary" null '{"canary":{}}'
expect "canary stage allows an apply scoped to the canary" 0 "canary-repo" "allow: canary canary-repo"
expect "canary stage holds an unscoped (fleet-wide) apply" 10 ""
expect "canary stage holds an apply scoped to a non-canary" 10 "some-other-repo"

write_ledger "$covers0" "glyph-test" null '{"canary":{}}'
expect "a pre-canary stage holds everything, canary scope included" 10 "canary-repo"

# ---------------------------------------------------------------------------
# Stage "fleet": evidence + soak, every piece load-bearing.
# ---------------------------------------------------------------------------
write_ledger "$covers0" "fleet" "\"$PAST\"" "$(evidence "$covers0" 555)"
expect "fleet stage with verified evidence and a past soak allows" 0 "" "allow: fleet"

write_ledger "$covers0" "fleet" "\"$FUTURE\"" "$(evidence "$covers0" 555)"
expect "fleet stage before soak_until holds" 12 "" "soaking"

write_ledger "$covers0" "fleet" null "$(evidence "$covers0" 555)"
expect "fleet stage with no soak_until refuses" 13 "" "soak_until is unset"

write_ledger "$covers0" "fleet" "\"$PAST\"" '{"canary":{}}'
expect "fleet stage with no canary evidence refuses" 13 "" "no canary evidence"

write_ledger "$covers0" "fleet" "\"$PAST\"" "$(evidence "sha256:0000000000000000000000000000000000000000000000000000000000000000" 555)"
expect "fleet stage with evidence for different bytes refuses" 13 "" "different bytes"

write_ledger "$covers0" "fleet" "\"$PAST\"" "$(evidence "$covers0" 556)"
expect "fleet stage with an unverifiable run id refuses" 13 "" "cannot verify run 556"

jq -n '{id: 557, path: ".github/workflows/fleet-sync.yml", conclusion: "failure"}' > "$stub_home/run-557.json"
write_ledger "$covers0" "fleet" "\"$PAST\"" "$(evidence "$covers0" 557)"
expect "fleet stage with a failed evidence run refuses" 13 "" "not success"

jq -n '{id: 558, path: ".github/workflows/zizmor.yml", conclusion: "success"}' > "$stub_home/run-558.json"
write_ledger "$covers0" "fleet" "\"$PAST\"" "$(evidence "$covers0" 558)"
expect "fleet stage with a non-fleet-sync evidence run refuses" 13 "" "not a fleet-sync run"

write_ledger "$covers0" "fleet" "\"$PAST\"" "$(jq -n --arg covers "$covers0" '{canary: {"canary-repo": {run_id: "five-five-five", recorded_at: "2026-07-28T00:00:00Z", covers: $covers, reads: []}}}')"
expect "fleet stage with a non-numeric run id refuses" 13 "" "no numeric run_id"

jq -n --arg covers "$covers0" \
  '{change: "test change", covers: $covers, stage: "fleet", canary: [], soak_until: "2026-07-29T00:00:00Z", evidence: {canary: {}}}' \
  > "$ledger"
expect "fleet stage with an empty canary list refuses" 13 "" "canary list is empty"

# ---------------------------------------------------------------------------
# A broken ledger is a HOLD, never a bypass.
# ---------------------------------------------------------------------------
printf '{ not json' > "$ledger"
expect "a malformed ledger holds loudly" 2 ""
rm "$ledger"
expect "a missing ledger holds loudly" 2 ""
write_ledger "$covers0" "canary" null '{"canary":{}}'

# ---------------------------------------------------------------------------
# REAL-TREE invariant: the repo's own ledger is valid and covers the repo's
# own fleet/ bytes. This is the PR-time gate — every PR that edits a canonical
# must update fleet/rollout.json in the same PR, or fail here before merging.
# (No run-id verification here: PR CI has no token, and the evidence check is
# the daily gate's job; what a PR must prove is coverage.)
# ---------------------------------------------------------------------------
real_ledger="$root/fleet/rollout.json"
if [ ! -f "$real_ledger" ]; then
  bad "the repo's own ledger exists" "missing $real_ledger — the gate would hold every apply run"
elif ! jq -e '
    type == "object"
    and (.change | type == "string")
    and (.covers | type == "string")
    and (.stage | type == "string")
    and (.canary | type == "array") and all(.canary[]; type == "string")
    and (.evidence | type == "object")
  ' "$real_ledger" >/dev/null 2>&1; then
  bad "the repo's own ledger is schema-valid" "$real_ledger does not parse as {change, covers, stage, canary[], evidence}"
else
  real_covers="$(bash "$script" --print-covers "$real_ledger")"
  ledger_covers="$(jq -r '.covers' "$real_ledger")"
  if [ "$real_covers" = "$ledger_covers" ]; then
    ok "the repo's own ledger covers the repo's own fleet/ ($real_covers)"
  else
    bad "the repo's own ledger covers the repo's own fleet/" \
      "fleet/ is       $real_covers" \
      "the ledger says $ledger_covers" \
      "a canonical changed without a rollout entry — update fleet/rollout.json in THIS PR:" \
      "set covers to the value above, stage to \"canary\", and canary to the repo(s) that go first"
  fi
fi

[ "$fails" -eq 0 ] || { echo "$fails fleet-rollout-gate case(s) failed"; exit 1; }
echo "all fleet-rollout-gate cases passed"
