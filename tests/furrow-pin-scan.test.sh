#!/usr/bin/env bash
# Table-test scripts/furrow-pin-scan.sh — the extractor furrow-pin-audit.yml reads
# every fleet workflow through. Each case is one YAML document on stdin and the
# EXACT record stream it must produce (kind, tag, line). Runs the REAL script
# (drift-free); self-test.yml invokes this. Needs bash + awk only.
#
# The shapes below are the fleet's real ones, not invented: the fleet-synced
# task-status caller, the hub's two `go install …/cmd/furrow@vX` expiry-reminder
# steps (the shape no uses:-shaped scan can see — ef243fc is that drift shipped),
# and the commented example pin README-style docs carry.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
script="$root/scripts/furrow-pin-scan.sh"
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

# The fleet-synced caller: a reusable workflow pinned at job level. This is the
# shape fleet/task-status.yml itself has, so it doubles as the canonical-read
# case the audit depends on.
case_ "fleet caller pin" "$(cat <<'EOF'
name: task-status
on:
  pull_request:
jobs:
  sync:
    uses: akira-toriyama/furrow/.github/workflows/sync-task-status.yml@v1.0.0
    secrets:
      PROJECTS_WRITE_PAT: ${{ secrets.PROJECTS_WRITE_PAT }}
EOF
)" "$(printf 'uses\tv1.0.0\t6')"

# The hub's expiry reminders install the binary inside a run: block — the shape
# that drifted to v0.2.1/v0.12.0 against a v0.13.0 fleet (ef243fc) because no
# uses:-shaped scan could see it.
case_ "go install inside a run block" "$(cat <<'EOF'
jobs:
  remind:
    steps:
      - name: Install furrow
        run: go install github.com/akira-toriyama/furrow/cmd/furrow@v1.0.0
EOF
)" "$(printf 'go-install\tv1.0.0\t5')"

# A moving or symbolic ref is drift by definition, whatever it resolves to today.
case_ "unpinned refs are classified, not skipped" "$(cat <<'EOF'
jobs:
  a:
    uses: akira-toriyama/furrow/.github/workflows/sync-task-status.yml@main
  b:
    steps:
      - run: go install github.com/akira-toriyama/furrow/cmd/furrow@latest
EOF
)" "$(printf 'uses-unpinned\tmain\t3\ngo-install-unpinned\tlatest\t6')"

# A moving major and a prerelease are not release tags either.
case_ "moving major and prerelease are unpinned" "$(cat <<'EOF'
jobs:
  a:
    uses: akira-toriyama/furrow/.github/workflows/sync-task-status.yml@v1
  b:
    uses: akira-toriyama/furrow/.github/workflows/sync-task-status.yml@v1.0.0-rc.1
EOF
)" "$(printf 'uses-unpinned\tv1\t3\nuses-unpinned\tv1.0.0-rc.1\t5')"

# A furrow reference that is neither a uses: nor a go install must still emit a
# record — unseen and level must not look alike.
case_ "unclassifiable reference still reports" "$(cat <<'EOF'
jobs:
  a:
    steps:
      - run: echo akira-toriyama/furrow/cmd/furrow@v0.9.9
EOF
)" "$(printf 'ref\tv0.9.9\t4')"

# Commented example pins are documentation: matching them is eternal false drift.
case_ "commented example pin ignored" "$(cat <<'EOF'
# Example caller:
#   uses: akira-toriyama/furrow/.github/workflows/sync-task-status.yml@v0.1.0
jobs:
  sync:
    uses: akira-toriyama/furrow/.github/workflows/sync-task-status.yml@v1.0.0 # was v0.14.0
EOF
)" "$(printf 'uses\tv1.0.0\t5')"

# Quotes read like the bare form.
case_ "quoted ref reads like a bare one" "$(cat <<'EOF'
jobs:
  sync:
    uses: "akira-toriyama/furrow/.github/workflows/sync-task-status.yml@v1.0.0"
EOF
)" "$(printf 'uses\tv1.0.0\t3')"

# A file with no furrow reference produces no records — and exits 0.
case_ "no reference, no records" "$(cat <<'EOF'
jobs:
  lint:
    uses: akira-toriyama/glyph/.github/workflows/lint.yml@v0.12.0
EOF
)" ""

if [ "$fails" -gt 0 ]; then
  echo "FAIL - $fails case(s)"
  exit 1
fi
echo "ok - all furrow-pin-scan cases passed"
