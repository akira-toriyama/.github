#!/usr/bin/env bash
# Table-test scripts/covered-pull-scan.sh — the extractor
# glyph-covered-pull-audit.yml sees the whole fleet through. Each case is one
# input on stdin and the EXACT record stream it must produce. Runs the REAL
# script (drift-free); self-test.yml invokes this. Needs bash + awk only.
#
# Both halves of the audit assert an ABSENCE ("no bot-authored merge commits",
# "no --merge/--rebase anywhere"), and a matcher that silently stops matching
# is indistinguishable from a clean fleet — so every arming shape below is a
# POSITIVE CONTROL proving the pattern still fires, and the harmless shapes
# (squash, comments, `-R`) pin that firing does not spread. The shapes are the
# fleet's real ones where they exist: glossary-site's `--auto --squash` is the
# one live `gh pr merge` in the fleet today.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
script="$root/scripts/covered-pull-scan.sh"
fails=0

[ -f "$script" ] || { echo "FAIL - $script is missing"; exit 1; }

# case_ <mode> <name> <input> <expected-records>
case_() {
  local mode="$1" name="$2" input="$3" want="$4" got rc
  got="$(printf '%s\n' "$input" | bash "$script" "$mode" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && [ "$got" = "$want" ]; then
    echo "ok   - $mode: $name"
  else
    echo "FAIL - $mode: $name (rc=$rc)"
    echo "       want:"; printf '%s\n' "$want" | sed 's/^/         /'
    echo "       got:";  printf '%s\n' "$got"  | sed 's/^/         /'
    fails=$((fails + 1))
  fi
}

tab="$(printf '\t')"

# ---- merges: commits that arm the trap ------------------------------------

# The exact shape `gh pr merge --merge` leaves on main: a two-parent commit
# authored by the merging integration. This is the record the audit reds on.
case_ merges "bot-authored merge commit is reported" \
"aaaa111${tab}2${tab}renovate[bot]" \
"covered-merge${tab}aaaa111${tab}renovate[bot]"

case_ merges "github-actions author is reported (prefix rule)" \
"bbbb222${tab}2${tab}github-actions" \
"covered-merge${tab}bbbb222${tab}github-actions"

case_ merges "web-flow author is reported (exact rule)" \
"cccc333${tab}2${tab}web-flow" \
"covered-merge${tab}cccc333${tab}web-flow"

# An octopus merge is still a merge — the gate is >= 2, not == 2.
case_ merges "octopus merge (three parents) is reported" \
"dddd444${tab}3${tab}github-actions[bot]" \
"covered-merge${tab}dddd444${tab}github-actions[bot]"

# A human merge commit resolves normally in glyph — nothing armed.
case_ merges "human-authored merge commit is not reported" \
"eeee555${tab}2${tab}Akira Toriyama" \
""

# A bot's ordinary (single-parent) commit is everyday fleet traffic.
case_ merges "bot-authored non-merge commit is not reported" \
"ffff666${tab}1${tab}dependabot[bot]" \
""

# `web-flow` is an EXACT match in glyph, so a lookalike must pass — matching
# it would red every merge a user named like this ever authored.
case_ merges "web-flow-ish author is not reported (exact, not prefix)" \
"aaaa777${tab}2${tab}web-flow-2" \
""

case_ merges "blank lines are ignored" \
"$(cat <<EOF

gggg888${tab}2${tab}renovate[bot]

EOF
)" \
"covered-merge${tab}gggg888${tab}renovate[bot]"

# Garbage in must be VISIBLE out: a shape change in the API plumbing feeding
# this scanner must not read as a clean fleet.
case_ merges "wrong arity is malformed, not skipped" \
"hhhh999${tab}2" \
"malformed-input${tab}-${tab}1"

case_ merges "non-numeric parent count is malformed, not skipped" \
"iiii000${tab}two${tab}renovate[bot]" \
"malformed-input${tab}-${tab}1"

# ---- workflows: the word before the commit exists -------------------------

# The arming line this audit exists to catch: one word in a workflow, and the
# next release walk silently drops a pull from notes and version.
case_ workflows "gh pr merge --merge is reported" "$(cat <<'EOF'
      - name: Merge it
        run: gh pr merge --auto --merge "$PR_URL"
EOF
)" \
"merge-strategy${tab}merge${tab}2"

case_ workflows "--rebase is reported" "$(cat <<'EOF'
        run: gh pr merge "$N" --rebase
EOF
)" \
"merge-strategy${tab}rebase${tab}1"

case_ workflows "short flag -m is the same word as --merge" "$(cat <<'EOF'
        run: gh pr merge -m "$N"
EOF
)" \
"merge-strategy${tab}merge${tab}1"

# The fleet's one real invocation today (glossary-site): squash is the normal
# path and must stay green, or the audit cries wolf on day one.
case_ workflows "--auto --squash is recorded as squash" "$(cat <<'EOF'
      - name: Enable auto-merge
        run: gh pr merge --auto --squash "$PR_URL"
EOF
)" \
"merge-strategy${tab}squash${tab}2"

# A commented example must not red the fleet — the same rule that keeps
# glyph-pin-audit from matching the stale caller stubs.
case_ workflows "a commented invocation is documentation" "$(cat <<'EOF'
        # gh pr merge --merge would arm the covered-pull trap
        run: echo advising only
EOF
)" \
""

case_ workflows "a trailing comment is stripped before matching" "$(cat <<'EOF'
        run: gh pr merge --squash "$N"  # never --merge here
EOF
)" \
"merge-strategy${tab}squash${tab}1"

# The joined form is what the shell executes.
case_ workflows "a backslash continuation is joined before matching" "$(cat <<'EOF'
        run: |
          gh pr merge "$N" \
            --merge
EOF
)" \
"merge-strategy${tab}merge${tab}2"

# Whole tokens only: --match-head-commit is not --merge, -R (repo) is not
# -r (rebase).
case_ workflows "--match-head-commit does not read as --merge" "$(cat <<'EOF'
        run: gh pr merge --match-head-commit abc123 --squash "$N"
EOF
)" \
"merge-strategy${tab}squash${tab}1"

case_ workflows "-R (repo) does not read as -r (rebase)" "$(cat <<'EOF'
        run: gh pr merge -R akira-toriyama/glyph --squash 7
EOF
)" \
"merge-strategy${tab}squash${tab}1"

# A strategy this scanner cannot read is a record, not a pass — the
# fail-loud rule glyph-pin-scan.sh established.
case_ workflows "a strategy held in a variable is unreadable, not silent" "$(cat <<'EOF'
        run: gh pr merge "$N" $MERGE_FLAGS
EOF
)" \
"merge-strategy-unreadable${tab}-${tab}1"

case_ workflows "quotes are erased before matching" "$(cat <<'EOF'
        run: gh pr merge "--merge" "$N"
EOF
)" \
"merge-strategy${tab}merge${tab}1"

case_ workflows "other gh pr subcommands are not invocations" "$(cat <<'EOF'
        run: gh pr comment "$N" --body "merge when green (--merge)"
EOF
)" \
""

case_ workflows "gh as a word suffix is not gh" "$(cat <<'EOF'
        run: ./not-gh pr merge --merge
EOF
)" \
""

# ---- the audit must not flag itself ---------------------------------------

# The audit workflow sits inside its own scan scope, and its error messages
# are executable echo lines with their quotes erased before matching — the
# first run on main flagged its OWN two messages as unreadable invocations,
# something no pre-merge check saw because the file was not on main yet. So
# the REAL file is the fixture here: a future edit that spells the audited
# command out inside a string turns this red locally, before it merges.
audit_yml="$root/.github/workflows/glyph-covered-pull-audit.yml"
if [ -f "$audit_yml" ]; then
  self_scan="$(bash "$script" workflows < "$audit_yml" 2>&1)"
  if [ -z "$self_scan" ]; then
    echo "ok   - workflows: the audit workflow itself scans clean"
  else
    echo "FAIL - workflows: the audit workflow flags itself"
    printf '%s\n' "$self_scan" | sed 's/^/         /'
    fails=$((fails + 1))
  fi
else
  echo "FAIL - workflows: $audit_yml is missing (self-scan fixture gone)"
  fails=$((fails + 1))
fi

# ---- mode dispatch --------------------------------------------------------

if usage_out="$(printf '' | bash "$script" 2>&1)"; then
  echo "FAIL - missing mode must refuse, got rc=0: $usage_out"
  fails=$((fails + 1))
else
  echo "ok   - missing mode refuses with usage"
fi

if [ "$fails" -gt 0 ]; then
  echo "$fails case(s) failed"
  exit 1
fi
echo "all cases passed"
