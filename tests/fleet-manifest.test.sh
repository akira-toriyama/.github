#!/usr/bin/env bash
# Gate the hub's own bookkeeping — the invariants that until now lived ONLY in
# prose (CLAUDE.md, fleet/README.md) and that nothing executed.
#
# Why these, and why here: every one of them is a single edit away, and every one
# of them fails SILENTLY. fleet-sync runs on a daily schedule and manual runs
# default to dry-run, so a MANIFEST that names a file that does not exist shows up
# (at best) a day later in a log nobody opens — and a canonical that nobody
# documented simply lands in ~36 repos unannounced. The hand-maintained hub copy
# of task-status.yml is worse still: fleet-sync EXCLUDEs `.github`, so there is no
# sync to correct a drift, ever. A PR-time check is the only moment any of this is
# cheap to fix.
#
# Static and offline: reads the repo, calls no API, needs bash + awk only.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
sync="$root/.github/workflows/fleet-sync.yml"
readme="$root/fleet/README.md"
fails=0

ok() { echo "ok   - $1"; }
bad() {
  echo "FAIL - $1"
  shift
  for line in "$@"; do echo "       $line"; done
  fails=$((fails + 1))
}

[ -f "$sync" ] || { echo "FAIL - $sync is missing"; exit 1; }
[ -f "$readme" ] || { echo "FAIL - $readme is missing"; exit 1; }

# Pull a shell assignment's value out of the workflow's run: block. Reading the
# workflow rather than restating its lists here is the whole point — a copy would
# be one more thing to drift. An unreadable assignment is a HARD failure, never an
# empty list: an empty list would make every check below pass vacuously, which is
# the exact failure mode this file exists to prevent.
assign_value() { # $1 = variable name
  local name="$1" line
  line="$(grep -E "^[[:space:]]*${name}=\"" "$sync" | head -1)"
  [ -n "$line" ] || return 1
  printf '%s' "$line" | sed -e 's/^[^"]*"//' -e 's/"[[:space:]]*$//'
}

MANIFEST="$(assign_value MANIFEST)" || {
  echo "FAIL - could not read MANIFEST=\"...\" from $sync"
  echo "       the checks below would all pass vacuously; fix the parser or the workflow"
  exit 1
}
GLYPH_REUSABLES="$(assign_value GLYPH_REUSABLES)" || {
  echo "FAIL - could not read GLYPH_REUSABLES=\"...\" from $sync"
  exit 1
}

# ---------------------------------------------------------------------------
# 1. Every MANIFEST src exists, and every dest is distinct.
# ---------------------------------------------------------------------------
missing=""
dests=""
dupes=""
for pair in $MANIFEST; do
  src="${pair%%:*}"
  dest="${pair##*:}"
  [ -f "$root/$src" ] || missing="$missing $src"
  case " $dests " in *" $dest "*) dupes="$dupes $dest" ;; esac
  dests="$dests $dest"
done
if [ -n "$missing" ]; then
  bad "every MANIFEST src exists" "missing:$missing" \
    "fleet-sync would abort mid-fleet on the first repo it reached"
else
  ok "every MANIFEST src exists"
fi
if [ -n "$dupes" ]; then
  bad "MANIFEST dests are distinct" "duplicated:$dupes" \
    "the later pair silently wins and the earlier canonical never ships"
else
  ok "MANIFEST dests are distinct"
fi

# ---------------------------------------------------------------------------
# 2. No MANIFEST dest collides with a glyph reusable DEFINITION.
#
# fleet-sync already refuses this at run time, but that run is daily and
# dry-run-by-default. On 2026-07-17 exactly this collision overwrote glyph's
# 287-line pr-verdict reusable with a 25-line caller; only the fact that callers
# pin tags rather than main kept the fleet up. Catch it on the PR that adds the
# MANIFEST line instead.
# ---------------------------------------------------------------------------
collisions=""
for pair in $MANIFEST; do
  dest="${pair##*:}"
  case "$dest" in
    .github/workflows/*)
      base="${dest##*/}"
      case " $GLYPH_REUSABLES " in *" $base "*) collisions="$collisions $dest" ;; esac
      ;;
  esac
done
if [ -n "$collisions" ]; then
  bad "no MANIFEST dest collides with a glyph reusable" "colliding:$collisions" \
    "glyph is inside this fleet — syncing a caller to that path overwrites its reusable definition"
else
  ok "no MANIFEST dest collides with a glyph reusable"
fi

# ---------------------------------------------------------------------------
# 3. Every distributable file in fleet/ is actually distributed.
#
# A canonical that no MANIFEST line names is dead weight that reads as live: the
# next author edits it, sees a green PR, and ships nothing. Excluded on purpose:
# README.md (documentation), dependabot.yml + dependabot.d/* (ASSEMBLED per
# repo inside the sync loop rather than listed as a pair), and rollout.json
# (the rollout LEDGER fleet-sync reads before writing — hub-only state, never
# distributed; tests/fleet-rollout-gate.test.sh is what holds it honest).
# ---------------------------------------------------------------------------
undistributed=""
for f in "$root"/fleet/*; do
  [ -f "$f" ] || continue
  rel="fleet/${f##*/}"
  case "$rel" in fleet/README.md | fleet/dependabot.yml | fleet/rollout.json) continue ;; esac
  case " $MANIFEST " in *" $rel:"*) ;; *) undistributed="$undistributed $rel" ;; esac
done
if [ -n "$undistributed" ]; then
  bad "every fleet/ canonical is in MANIFEST" "not distributed:$undistributed" \
    "add a MANIFEST pair in $sync, or delete the file"
else
  ok "every fleet/ canonical is in MANIFEST"
fi

# ---------------------------------------------------------------------------
# 4. Every distributed canonical is DOCUMENTED in fleet/README.md.
#
# These files appear unannounced in ~36 repos. fleet/README.md's "Files" section
# is where a consumer finds out what a file is and who owns it; a canonical that
# is missing from it is invisible until someone wonders what it is doing there.
# (version-preview.yml shipped fleet-wide undocumented for exactly this reason.)
# ---------------------------------------------------------------------------
undocumented=""
for pair in $MANIFEST; do
  src="${pair%%:*}"
  base="${src##*/}"
  grep -q -- "$base" "$readme" || undocumented="$undocumented $base"
done
if [ -n "$undocumented" ]; then
  bad "every distributed canonical is documented in fleet/README.md" \
    "undocumented:$undocumented" "add it to the Files list in $readme"
else
  ok "every distributed canonical is documented in fleet/README.md"
fi

# ---------------------------------------------------------------------------
# 5. dependabot.d/ blocks and their manifest probes agree.
#
# The assembly loop appends fleet/dependabot.d/$eco.yml for each `manifest:eco`
# probe pair. A block with no probe never ships; a probe with no block makes
# `cat` fail mid-assembly and skips dependabot.yml for that repo. fleet/README.md
# tells a future author to keep both in step — this makes it true.
# ---------------------------------------------------------------------------
probe_line="$(grep -E '^[[:space:]]*for probe in ' "$sync" | head -1)"
if [ -z "$probe_line" ]; then
  bad "dependabot probe pairs are readable" "no \`for probe in ...\` loop found in $sync"
else
  probes="$(printf '%s' "$probe_line" | sed -e 's/^[[:space:]]*for probe in //' -e 's/;[[:space:]]*do.*$//')"
  ecos=""
  probe_missing=""
  for probe in $probes; do
    eco="${probe##*:}"
    ecos="$ecos $eco"
    [ -f "$root/fleet/dependabot.d/$eco.yml" ] || probe_missing="$probe_missing $eco"
  done
  block_missing=""
  for f in "$root"/fleet/dependabot.d/*.yml; do
    [ -f "$f" ] || continue
    base="${f##*/}"
    eco="${base%.yml}"
    case " $ecos " in *" $eco "*) ;; *) block_missing="$block_missing $eco" ;; esac
  done
  if [ -n "$probe_missing" ] || [ -n "$block_missing" ]; then
    bad "dependabot.d blocks and probe pairs agree" \
      "probe with no block:${probe_missing:-" (none)"}" \
      "block with no probe:${block_missing:-" (none)"}"
  else
    ok "dependabot.d blocks and probe pairs agree"
  fi
fi

# ---------------------------------------------------------------------------
# 6. The hub's hand-maintained task-status caller matches the canonical.
#
# fleet-sync EXCLUDEs `.github` (it IS the hub), so fleet/task-status.yml never
# syncs onto the hub and the hub's own copy is maintained BY HAND. The two must
# agree below their provenance headers — most importantly on the furrow pin, which
# has to be bumped in BOTH files. Only the leading comment block may differ.
# ---------------------------------------------------------------------------
canonical="$root/fleet/task-status.yml"
hub="$root/.github/workflows/task-status.yml"
# Drop the leading run of `#` lines (the provenance header) and compare the rest.
# Only the LEADING run: a comment further down is part of the caller body and must
# match like everything else.
strip_header() { awk 'started { print; next } !/^#/ { started = 1; print }' "$1"; }
if [ ! -f "$canonical" ] || [ ! -f "$hub" ]; then
  bad "hub task-status caller matches the canonical" "missing $canonical or $hub"
elif diff_out="$(diff -u <(strip_header "$canonical") <(strip_header "$hub"))"; then
  ok "hub task-status caller matches the canonical"
else
  bad "hub task-status caller matches the canonical" \
    "fleet-sync EXCLUDEs .github, so nothing will ever reconcile these two by itself" \
    "$(printf '%s' "$diff_out" | head -30)"
fi

# ---------------------------------------------------------------------------
# 7. The hub's hand-maintained commit-lint caller pins the same glyph as the
#    canonical.
#
# The SECOND hand-maintained twin, and the one CLAUDE.md's invariants list does
# not mention. .github/workflows/self-commit-lint.yml says in its own header
# "Keep the glyph pin below in LOCKSTEP with fleet/commit-lint.yml", for the same
# reason as task-status: fleet-sync EXCLUDEs the hub. Its job id differs on
# purpose (`commit-lint`, so main's required check keeps its context), so this
# compares the PIN rather than the file.
# ---------------------------------------------------------------------------
pin_of() { # $1 = file — the tag of the first akira-toriyama `uses:` in it
  awk '$1 == "uses:" && $2 ~ /^akira-toriyama\// { sub(/^.*@/, "", $2); print $2; exit }' "$1"
}
canonical_glyph="$(pin_of "$root/fleet/commit-lint.yml")"
hub_glyph="$(pin_of "$root/.github/workflows/self-commit-lint.yml")"
if [ -z "$canonical_glyph" ] || [ -z "$hub_glyph" ]; then
  bad "the hub commit-lint caller pins the canonical glyph" \
    "could not read a pin (canonical='$canonical_glyph' hub='$hub_glyph')"
elif [ "$canonical_glyph" = "$hub_glyph" ]; then
  ok "the hub commit-lint caller pins the canonical glyph ($canonical_glyph)"
else
  bad "the hub commit-lint caller pins the canonical glyph" \
    "fleet/commit-lint.yml pins $canonical_glyph" \
    ".github/workflows/self-commit-lint.yml pins $hub_glyph" \
    "bump both in the same PR — fleet-sync EXCLUDEs .github and will not fix this"
fi

# ---------------------------------------------------------------------------
# 8. Every furrow reference in the repo names the same release.
#
# The furrow pin has no canonical and three call sites, one of which no `uses:`-
# shaped scanner can see (a `FURROW_RELEASE:` env on a run: step). This
# is not a theoretical drift: ef243fc is ":bug:(ci) fix the expiry reminders'
# stale furrow pin (v0.2.1/v0.12.0 → v0.13.0)", and the tracker has carried
# several separate one-off bump tasks for the same mechanical invariant. Bumping
# furrow should fail here until every site moves together.
# ---------------------------------------------------------------------------
furrow_refs="$(grep -rhoE 'akira-toriyama/furrow[^ ]*@v[0-9]+\.[0-9]+\.[0-9]+' \
  "$root/.github/workflows" "$root/fleet" 2>/dev/null | sed 's/^.*@//' | sort -u)"
furrow_count="$(grep -rlE 'akira-toriyama/furrow[^ ]*@v[0-9]+\.[0-9]+\.[0-9]+' \
  "$root/.github/workflows" "$root/fleet" 2>/dev/null | wc -l | tr -d ' ')"
if [ -z "$furrow_refs" ]; then
  bad "every furrow reference names the same release" \
    "found no furrow pin at all — the matcher has drifted from how they are written"
elif [ "$(printf '%s\n' "$furrow_refs" | wc -l | tr -d ' ')" -eq 1 ]; then
  ok "every furrow reference names the same release ($furrow_refs, across $furrow_count file(s))"
else
  bad "every furrow reference names the same release" \
    "versions in play: $(printf '%s' "$furrow_refs" | tr '\n' ' ')" \
    "one call site is a \`FURROW_RELEASE:\` env on a run: step, invisible to any uses:-shaped scan"
fi

# ---------------------------------------------------------------------------
# 9. README.md indexes every consumable and every design record.
#
# CLAUDE.md declares README.md "the consumer index", and it is the front page a
# fleet author reads to find out what they may consume. Three separate inventories
# of the same things had drifted apart before this check existed: README called
# itself "a composite action" while shipping three and listing two, the ref policy
# named seven reusables when there were eight, and the docs index listed eight of
# ten files — the two missing being the fleet-change policy and the glyph rollout
# runbook, i.e. the two a fleet author most needs to find.
# ---------------------------------------------------------------------------
top_readme="$root/README.md"
unindexed=""
# A reusable is a workflow that declares `on: workflow_call`. Matched at the start
# of a line inside the on: block rather than anywhere in the file: fleet-sync.yml
# merely mentions the string in a comment and in a grep, and is not consumable.
for f in "$root"/.github/workflows/*.yml; do
  base="${f##*/}"
  awk '/^on:/ { inon = 1; next } /^[^[:space:]#]/ { inon = 0 } inon && /^[[:space:]]+workflow_call:/ { found = 1 } END { exit !found }' "$f" || continue
  grep -q -- "$base" "$top_readme" || unindexed="$unindexed workflows/$base"
done
for f in "$root"/actions/*/action.yml; do
  [ -f "$f" ] || continue
  d="${f%/action.yml}"; d="${d##*/}"
  grep -q -- "actions/$d" "$top_readme" || unindexed="$unindexed actions/$d"
done
for f in "$root"/docs/*.md; do
  [ -f "$f" ] || continue
  base="${f##*/}"
  grep -q -- "$base" "$top_readme" || unindexed="$unindexed docs/$base"
done
if [ -n "$unindexed" ]; then
  bad "README.md indexes every consumable and design record" \
    "missing from README.md:$unindexed" \
    "README.md is the single index — the ref policy and CLAUDE.md point at it rather than keeping their own lists"
else
  ok "README.md indexes every consumable and design record"
fi

# ---------------------------------------------------------------------------
# The rollout gate's exit code must survive being captured.
#
# The gate publishes FIVE distinct codes (2 broken ledger / 10 held / 11
# uncovered / 12 soaking / 13 evidence) and their remediations differ; the job
# summary and the ::error:: annotation are where an operator reads which one
# held the run. fleet-sync captured it with `if ! <gate>; then rc=$?`, and in
# the then-branch of a NEGATED condition `$?` is the status of the compound the
# `!` already inverted — 0, always. Measured on run 30691779105: the annotation
# said "(gate exit 0)" while the gate had exited 12. Nothing was wrong with the
# rollout and nothing was wrong with the gate; the one number naming the reason
# was a constant.
#
# Two parts, and the first is the canary the second needs: a guard that asserts
# an ABSENCE dies green the day its premise stops holding, so the premise is
# executed here rather than trusted.
# ---------------------------------------------------------------------------
gate_stub() { return 12; }

negated_rc=""
if ! gate_stub; then negated_rc=$?; fi
capture_rc=0
gate_stub || capture_rc=$?

if [ "$negated_rc" = "0" ] && [ "$capture_rc" = "12" ]; then
  ok "the \`if ! …; then rc=\$?\` idiom really does lose the exit code (canary)"
else
  bad "the \`if ! …; then rc=\$?\` idiom really does lose the exit code (canary)" \
    "negated-if captured '$negated_rc' (expected 0), || captured '$capture_rc' (expected 12)" \
    "this shell no longer behaves as the guard below assumes — re-derive the guard and the comment in fleet-sync.yml before touching either"
fi

gate_call='scripts/fleet-rollout-gate.sh fleet/rollout.json'
if grep -q "if ! bash $gate_call" "$sync"; then
  bad "fleet-sync captures the rollout gate's exit code, not the negation's" \
    "fleet-sync.yml still calls the gate inside \`if ! …; then\`, so \$? is 0 whatever the gate returned" \
    "capture it first: rc=0; bash $gate_call \"\$ONLY_REPO\" || rc=\$?"
elif ! grep -q "$gate_call .* || rc=\$?" "$sync"; then
  bad "fleet-sync captures the rollout gate's exit code, not the negation's" \
    "no \`|| rc=\$?\` capture found on the gate call in fleet-sync.yml" \
    "the summary and the ::error:: annotation both interpolate \$rc; an uncaptured code makes both lie"
else
  ok "fleet-sync captures the rollout gate's exit code, not the negation's"
fi

[ "$fails" -eq 0 ] || { echo "$fails fleet-manifest case(s) failed"; exit 1; }
echo "all fleet-manifest cases passed"
