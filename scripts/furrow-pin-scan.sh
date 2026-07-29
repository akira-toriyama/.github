#!/usr/bin/env bash
# Read ONE workflow / action YAML on stdin; write every furrow pin it declares to
# stdout as TAB-separated records, one per line:
#
#   uses                 <tag>  <line>   a `uses:` of akira-toriyama/furrow/…@vX.Y.Z
#   uses-unpinned        <ref>  <line>   … pinned to something that is NOT a release
#                                        tag: a branch, a commit SHA, a moving
#                                        major, or a prerelease
#   go-install           <tag>  <line>   a `go install …/furrow/…@vX.Y.Z` inside a
#                                        run: block
#   go-install-unpinned  <ref>  <line>   … at @latest, @main, a SHA, …
#   ref                  <tag>  <line>   any other akira-toriyama/furrow…@vX.Y.Z
#   ref-unpinned         <ref>  <line>   … at a non-release ref
#
# The sibling of scripts/glyph-pin-scan.sh, and simpler on purpose: furrow has no
# install composite, so there is no `version:` input to attribute to a step and no
# block structure to track. What furrow has instead is the shape no `uses:`-shaped
# scanner can see — `go install github.com/akira-toriyama/furrow/cmd/furrow@vX`
# inside a run: block. That shape has already drifted for real (ef243fc fixed the
# expiry reminders sitting on v0.2.1/v0.12.0 against a v0.13.0 fleet), which is
# why every occurrence of `akira-toriyama/furrow…@ref` emits a record and the
# `ref`/`ref-unpinned` catch-all exists: a furrow reference this scanner cannot
# classify must not be indistinguishable from a file with no furrow reference at
# all.
#
# Comment and quote handling is glyph-pin-scan.sh's, for glyph-pin-scan.sh's
# reasons:
#
#   - a line whose first non-space character is `#` is documentation, skipped
#     outright; commented caller stubs carry permanently stale example pins, and
#     matching them produces eternal false drift.
#   - a ` #…` trailer is stripped, so `@v1.0.0 # was v0.14.0` reports one pin.
#   - quotes are erased before matching, so a quoted ref reads like a bare one.
#
# One record per line: no fleet workflow names furrow twice on one line, and the
# audit's job is "which versions are in play", not "how many times".
set -euo pipefail

awk '
BEGIN {
  # A dynamic regex, because a literal quote cannot be written inside the
  # single-quoted awk program this script passes to the shell.
  qre = "[" sprintf("%c%c", 39, 34) "]"
}

{
  line = $0
  if (line ~ /^[ \t]*#/) next        # a whole-line comment is documentation
  sub(/[ \t]+#.*$/, "", line)        # and so is a trailing one
  if (line ~ /^[ \t]*$/) next
  gsub(qre, "", line)

  # Match ANY ref, then classify — an unreadable pin and a correct pin must not
  # look alike. `[^@ \t]*` spans the path (…/cmd/furrow, …/.github/workflows/…),
  # `[^ \t]+` runs to the end of the ref; comments and quotes are already gone.
  if (match(line, /akira-toriyama\/furrow[^@ \t]*@[^ \t]+/)) {
    ref = substr(line, RSTART, RLENGTH)
    tag = ref; sub(/^.*@/, "", tag)
    kind = "ref"
    if (line ~ /uses:/)                kind = "uses"
    else if (line ~ /go[ \t]+install/) kind = "go-install"
    # A concrete release tag, and nothing else: not `@main`, not `@latest`, not
    # a SHA, not a moving `@v1`, not a prerelease. The convention is that the
    # sync-task-status reusable installs the furrow binary of its own tag
    # (skew-free), so anything that can move out from under the audit is drift
    # by definition.
    if (tag ~ /^v[0-9]+\.[0-9]+\.[0-9]+$/) print kind "\t" tag "\t" NR
    else                                   print kind "-unpinned\t" tag "\t" NR
  }
}
'
