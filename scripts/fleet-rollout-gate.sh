#!/usr/bin/env bash
# Decide whether an APPLY run of fleet-sync may write to the fleet, from the
# rollout ledger (fleet/rollout.json). This is the machine form of the staged
# sequence in docs/fleet-change-policy.md: merging a canonical to the hub's main
# no longer means "deployed on the next timer tick" — the ledger has to cover
# exactly the bytes on disk, and the rollout has to have reached a stage that
# lets THIS run write.
#
#   usage:  fleet-rollout-gate.sh <ledger.json> [<only-repo>]
#           fleet-rollout-gate.sh --print-covers <ledger.json>
#   stdout: "allow: fleet" or "allow: canary <repo>"   (gate mode, exit 0)
#           "sha256:<64 hex>"                          (--print-covers)
#   exit:   0  writes are allowed for this run's scope
#           2  usage error, missing/malformed ledger, missing tool — fail
#              LOUD: a broken ledger must read as "held", never as "go"
#           10 held — the rollout has not reached a stage that lets this run
#              write (stage is pre-canary, or stage is "canary" and this run
#              is not scoped to a listed canary)
#           11 uncovered — fleet/ content is not what the ledger covers: a
#              canonical changed without a rollout entry
#           12 soaking — canary evidence is in, soak_until is not yet reached
#           13 evidence — stage says "fleet" but the canary evidence is
#              missing, is for different bytes, or its run id cannot be
#              verified as a successful fleet-sync run (a hand-written ledger
#              is refused here, not by review)
#
# env:  ROLLOUT_HUB  owner/repo whose fleet-sync runs are the evidence source;
#                    required only when stage is "fleet" (the workflow passes
#                    github.repository). Run verification calls `gh api`.
#       ROLLOUT_NOW  ISO8601 UTC instant to treat as "now" (tests only).
#
# The ledger (all fields required; see fleet/README.md "Rollout ledger"):
#   change     one line naming what is being rolled out
#   covers     "sha256:<hex>" over every file under the ledger's directory
#              except the ledger itself and README.md — i.e. the distributable
#              bytes. --print-covers computes it; tests/fleet-rollout-gate.
#              test.sh holds the repo's own ledger to it at PR time.
#   stage      free string. Exactly two values mean something to the machine:
#              "canary" (only a canary-scoped apply may write) and "fleet"
#              (everything may write, once evidence + soak hold). Anything
#              else — "local", "poc", "glyph-test" — holds all writes.
#   canary     list of repo names (no owner prefix). At stage "canary", an
#              apply scoped to one of them may write; at stage "fleet", EVERY
#              listed canary must carry valid evidence.
#   soak_until ISO8601 UTC, or null until the recorder sets it.
#   evidence   .canary.<repo> records are MACHINE-written by fleet-sync's
#              recorder step from the read-back's real output: run_id,
#              recorded_at, covers, reads.
set -uo pipefail

err() { printf 'rollout-gate: %s\n' "$*" >&2; }
die2() {
  err "$*"
  exit 2
}

mode=gate
if [ "${1:-}" = "--print-covers" ]; then
  mode=covers
  shift
fi
ledger="${1:-}"
only="${2:-}"
[ -n "$ledger" ] || die2 "usage: fleet-rollout-gate.sh [--print-covers] <ledger.json> [<only-repo>]"
command -v jq >/dev/null 2>&1 || die2 "jq is required"

ledger_base="$(basename "$ledger")"
fleet_dir="$(cd "$(dirname "$ledger")" 2>/dev/null && pwd)" \
  || die2 "ledger directory does not exist: $(dirname "$ledger")"

# sha256 of stdin, GNU or BSD userland (posix-portability runs this on macOS).
digest() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1
  fi
}

# One hash over the DISTRIBUTABLE bytes: every file under the ledger's
# directory except the ledger itself (it cannot cover its own bytes) and
# README.md (documentation, never distributed — the same exclusion
# tests/fleet-manifest.test.sh makes). A new canonical is covered by default;
# forgetting it here is impossible, forgetting a MANIFEST line is check 3's job.
covers_hash() {
  (
    cd "$fleet_dir" || exit 1
    find . -type f ! -path "./$ledger_base" ! -path "./README.md" -print \
      | LC_ALL=C sort \
      | while IFS= read -r f; do
        printf '%s ' "$f"
        digest < "$f"
      done
  ) | digest | sed 's/^/sha256:/'
}

if [ "$mode" = "covers" ]; then
  covers_hash
  exit 0
fi

[ -f "$ledger" ] || die2 "ledger not found: $ledger — the gate holds; restore fleet/rollout.json"
jq -e '
  type == "object"
  and (.change | type == "string")
  and (.covers | type == "string")
  and (.stage | type == "string")
  and (.canary | type == "array") and all(.canary[]; type == "string")
  and (.evidence | type == "object")
' "$ledger" >/dev/null 2>&1 \
  || die2 "ledger is not valid JSON with {change, covers, stage, canary[], evidence} — the gate holds until it parses"

# ISO8601 UTC -> epoch seconds, GNU date or BSD date.
iso_epoch() {
  if date -u -d '@0' +%s >/dev/null 2>&1; then
    date -u -d "$1" +%s 2>/dev/null
  else
    date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null
  fi
}
if [ -n "${ROLLOUT_NOW:-}" ]; then
  now_epoch="$(iso_epoch "$ROLLOUT_NOW")" || die2 "unparseable ROLLOUT_NOW: ${ROLLOUT_NOW}"
else
  now_epoch="$(date -u +%s)"
fi

change="$(jq -r '.change' "$ledger")"
want="$(jq -r '.covers' "$ledger")"
current="$(covers_hash)"

# The FIRST check, before any stage logic: whatever the ledger says about its
# own rollout, it says it about specific bytes. If fleet/ moved on without it,
# nothing may ship — this is the check that ends "merge to main = deploy".
if [ "$current" != "$want" ]; then
  err "fleet/ content ($current) is not what the ledger covers ($want)."
  err "a canonical changed without a rollout entry — nothing will be distributed until fleet/rollout.json describes this change:"
  err "  set change to what is rolling out, stage to \"canary\" (or an earlier stage), canary to the repo(s) that go first,"
  err "  and covers to the current value: $current"
  err "  (compute it with: bash scripts/fleet-rollout-gate.sh --print-covers fleet/rollout.json)"
  exit 11
fi

stage="$(jq -r '.stage' "$ledger")"
case "$stage" in
  canary)
    if [ -n "$only" ] && jq -e --arg r "$only" '.canary | index($r) != null' "$ledger" >/dev/null; then
      echo "allow: canary $only"
      exit 0
    fi
    err "held: '$change' is at stage \"canary\" — only an apply scoped to a listed canary may write ($(jq -r '.canary | join(", ")' "$ledger"))."
    err "run: gh workflow run fleet-sync.yml -f dry-run=false -f only-repo=<canary>"
    exit 10
    ;;
  fleet)
    soak="$(jq -r '.soak_until // empty' "$ledger")"
    if [ -z "$soak" ]; then
      err "stage says \"fleet\" but soak_until is unset — canary evidence was never recorded for '$change'."
      exit 13
    fi
    soak_epoch="$(iso_epoch "$soak")" || die2 "unparseable soak_until: $soak"
    if [ "$now_epoch" -lt "$soak_epoch" ]; then
      err "held: '$change' is soaking on its canary until $soak — the fleet applies on the first run after that."
      exit 12
    fi
    [ "$(jq -r '.canary | length' "$ledger")" -ge 1 ] || {
      err "stage says \"fleet\" but the canary list is empty — a rollout that skipped its canary may not reach the fleet."
      exit 13
    }
    while IFS= read -r c; do
      e="$(jq -c --arg r "$c" '(.evidence.canary // {})[$r] // empty' "$ledger")"
      if [ -z "$e" ]; then
        err "no canary evidence for '$c' — stage \"fleet\" requires a recorded canary apply for every listed canary."
        exit 13
      fi
      e_covers="$(printf '%s' "$e" | jq -r '.covers // empty')"
      if [ "$e_covers" != "$want" ]; then
        err "the canary evidence for '$c' is for different bytes ($e_covers, ledger covers $want) — re-run the canary for this change."
        exit 13
      fi
      run_id="$(printf '%s' "$e" | jq -r '.run_id // empty')"
      case "$run_id" in
        '' | *[!0-9]*)
          err "the canary evidence for '$c' has no numeric run_id — evidence is machine-written by the recorder step, not by hand."
          exit 13
          ;;
      esac
      [ -n "${ROLLOUT_HUB:-}" ] || die2 "ROLLOUT_HUB is unset — cannot verify evidence run ids"
      if ! run_json="$(gh api "repos/$ROLLOUT_HUB/actions/runs/$run_id" 2>/dev/null)"; then
        err "cannot verify run $run_id on $ROLLOUT_HUB — a hand-written run id is refused; a transient API failure heals on the next scheduled run."
        exit 13
      fi
      run_path="$(printf '%s' "$run_json" | jq -r '.path // empty')"
      run_concl="$(printf '%s' "$run_json" | jq -r '.conclusion // empty')"
      if [ "$run_path" != ".github/workflows/fleet-sync.yml" ]; then
        err "run $run_id is not a fleet-sync run (path: ${run_path:-unknown}) — it cannot be canary evidence."
        exit 13
      fi
      if [ "$run_concl" != "success" ]; then
        err "run $run_id concluded '${run_concl:-in progress}', not success — a failed canary is not evidence."
        exit 13
      fi
    done < <(jq -r '.canary[]' "$ledger")
    echo "allow: fleet"
    exit 0
    ;;
  *)
    err "held: '$change' is at stage \"$stage\" — no fleet writes before the canary stage. Finish the earlier stages, then set stage to \"canary\"."
    exit 10
    ;;
esac
