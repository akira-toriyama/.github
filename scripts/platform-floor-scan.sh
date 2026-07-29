#!/usr/bin/env bash
# Read ONE Package.swift on stdin; write what the platform-floor audit needs to
# stdout as TAB-separated records, one per line:
#
#   macos-floor  <ver>      <line>   a `.macOS(…)` platform floor, normalized:
#                                    `.macOS(.v13)` -> 13, `.macOS("26.0")` -> 26.0
#   sill-dep     url|path   <line>   a `.package(…)` reference to akira-toriyama/sill
#                                    (the published-tag url form, or the local
#                                    `.package(path: "../sill")` dev form)
#
# The sibling of scripts/furrow-pin-scan.sh, for Package.swift instead of YAML.
# platform-floor-audit.yml reads every consumer's floor through this script, so a
# parser regression here does not fail loudly — it silently stops SEEING a floor
# or a dependency, which reads exactly like a repo with nothing to audit. The
# table test (tests/platform-floor-scan.test.sh) pins that distinction.
#
# COMMENTS ARE IGNORED, and that is load-bearing, not hygiene: sill's own
# Package.swift carries `.macOS("26.0")` inside a // comment (the line that
# explains why the string form is used), and several consumers narrate historical
# floors in prose. Matching those produces eternal false floors. Swift comments
# are `//…` and `/*…*/`; the `//` strip must NOT eat the `://` inside the
# dependency URLs it exists to preserve.
#
# BOTH floor spellings are matched: the family standardized on the string form
# (`.macOS("26.0")` — see sill's Package.swift for why), but `.macOS(.v13)` is
# exactly what a drifted repo looks like (the t-tbar leftovers this audit exists
# to catch), so the scanner must read the drifted form, not just the current one.
#
# Second mode — the comparison the audit makes, kept HERE so it is table-tested
# with the parser instead of living untested in workflow YAML:
#
#   platform-floor-scan.sh cmp <consumer-floor> <required-floor>
#
# exits 0 when consumer >= required, 1 when consumer < required (drift), and
# 2 when either floor is unparsable — an unreadable floor must not be
# indistinguishable from a compliant one (the fail-open shape t-a8zh reported
# in glyph-pin-audit).
set -uo pipefail

if [ "${1:-}" = "cmp" ]; then
  a="${2:-}"; b="${3:-}"
  vre='^[0-9]+(\.[0-9]+){0,2}$'
  [[ "$a" =~ $vre ]] || { echo "cmp: unparsable floor '$a'" >&2; exit 2; }
  [[ "$b" =~ $vre ]] || { echo "cmp: unparsable floor '$b'" >&2; exit 2; }
  # Numeric, segment by segment — a lexical compare calls 9 >= 13 false drift.
  awk -v a="$a" -v b="$b" 'BEGIN {
    split(a, A, "."); split(b, B, ".")
    for (i = 1; i <= 3; i++) {
      if (A[i] + 0 > B[i] + 0) exit 0
      if (A[i] + 0 < B[i] + 0) exit 1
    }
    exit 0
  }'
  exit "$?"
fi

awk '
BEGIN {
  # A dynamic regex, because a literal quote cannot be written inside the
  # single-quoted awk program this script passes to the shell. \x01 is the
  # stand-in that keeps `://` alive while `//…` comments are stripped.
  qre = "[" sprintf("%c%c", 39, 34) "]"
  hide = sprintf("%c", 1)
  inblock = 0
}

{
  line = $0

  # /* … */ block comments: strip closed blocks in place, then track the open
  # state across lines. Runs BEFORE the // strip so `/* http:// */` cannot
  # resurrect a URL scheme, and before matching so a commented-out dependency
  # block reads as documentation, not drift.
  while (inblock) {
    if (match(line, /\*\//)) { line = substr(line, RSTART + 2); inblock = 0 }
    else next
  }
  while (match(line, /\/\*/)) {
    head = substr(line, 1, RSTART - 1)
    tail = substr(line, RSTART + 2)
    if (match(tail, /\*\//)) line = head substr(tail, RSTART + 2)
    else { line = head; inblock = 1 }
  }

  # //… line comments, with the URL scheme protected: hide `://`, strip from
  # the first remaining `//`, restore. Without the hide, stripping a trailing
  # comment from the sill url line truncates it at `https:` and the dependency
  # silently vanishes from the audit.
  gsub(/:\/\//, hide, line)
  sub(/\/\/.*$/, "", line)
  gsub(hide, "://", line)

  if (line ~ /^[ \t]*$/) next
  gsub(qre, "", line)                # a quoted floor/url reads like a bare one

  # `.macOS(.v13)` — the drifted legacy form.
  if (match(line, /\.macOS\(\.v[0-9]+\)/)) {
    ver = substr(line, RSTART, RLENGTH)
    sub(/^\.macOS\(\.v/, "", ver); sub(/\)$/, "", ver)
    print "macos-floor\t" ver "\t" NR
  }
  # `.macOS(26.0)` — the string form, quotes already erased.
  else if (match(line, /\.macOS\([0-9][0-9.]*\)/)) {
    ver = substr(line, RSTART, RLENGTH)
    sub(/^\.macOS\(/, "", ver); sub(/\)$/, "", ver)
    print "macos-floor\t" ver "\t" NR
  }

  # The published-tag dependency: …github.com/akira-toriyama/sill[.git]… with a
  # word boundary after it, so sill-themes / sillier can never read as sill.
  if (match(line, /github\.com\/akira-toriyama\/sill(\.git)?/)) {
    following = substr(line, RSTART + RLENGTH, 1)
    if (following !~ /[A-Za-z0-9_-]/) print "sill-dep\turl\t" NR
  }
  # The local-dev path form (`.package(path: "../sill")`) — same boundary rule.
  else if (line ~ /path:/ && match(line, /sill/)) {
    following = substr(line, RSTART + RLENGTH, 1)
    if (following !~ /[A-Za-z0-9_-]/) print "sill-dep\tpath\t" NR
  }
}
'
