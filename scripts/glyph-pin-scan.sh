#!/usr/bin/env bash
# Read ONE workflow / action YAML on stdin; write every glyph pin it declares to
# stdout as TAB-separated records, one per line:
#
#   uses                <tag>         <line>   a real `uses:` of akira-toriyama/glyph/…@vX.Y.Z
#   version             <tag>         <line>   the literal `version:` a glyph install step passes
#   version-missing     <action-tag>  <line>   … that step passes no `version:` at all
#   version-unreadable  <action-tag>  <line>   … it passes one this scanner cannot resolve
#
# WHY THIS IS A SCRIPT AND NOT A GREP. The `uses:` half is a line-local match and
# was a grep for months. The `version:` half is not: `version:` is a generic input
# name (taplo, setup-*, half the fleet's third-party steps take one), so the only
# thing that makes an occurrence a GLYPH pin is the STEP it sits in. Reading that
# needs block structure, and block structure needs somewhere a test can reach —
# hence tests/glyph-pin-scan.test.sh, the same reason actions/go-bite and
# actions/bump-formula are extracted .sh files rather than inline `run:` blocks.
#
# The `version:` input is the FIFTH thing that references glyph and the one no
# check could see until now: seven repos sat on a v0.8.0 BINARY while every
# workflow around it said v0.10.2, so their CI enforced a three-release-old
# convention and reported green doing it (docs/glyph-rollout-runbook.md).
#
# WHAT IS DELIBERATELY NOT PARSED. No YAML library — the runner is not guaranteed
# one, and this reads files fetched over the API, one at a time, in a loop over
# ~36 repos. What it does instead:
#
#   - a line whose first non-space character is `#` is documentation, skipped
#     outright; every glyph reusable ships a commented caller stub with a
#     permanently stale example pin, and matching those produces eternal false
#     drift (that mistake predates this file — see glyph-pin-audit.yml).
#   - a ` #…` trailer is stripped for the same reason, so `@v0.11.1 # was v0.8.0`
#     reports one pin and not two. A value that legitimately contains " #" would
#     be truncated; no fleet workflow has one, and the blast radius is limited to
#     pin detection.
#   - quotes are erased before matching, so `version: "v0.11.1"` reads the same
#     as the bare form.
#   - a step block runs from a `- ` list item to the next line indented no deeper
#     than it. Blank and comment lines never close a block; a list NESTED inside
#     a step does not start a new one.
#
# FAIL LOUD, NOT OPEN. A step pinned to `…/actions/install@vX.Y.Z` that this
# scanner cannot read a literal version out of is reported (version-missing /
# version-unreadable), never passed over. An unreadable pin and a correct pin
# must not look alike — that indistinguishability is the whole bug this closes.
# glyph's OWN reusables are not affected: they reach the composite by relative
# path (`./.glyph-action/…`), which never matches, so their computed
# `version: ${{ steps.glyph.outputs.version }}` is invisible here by construction.
set -euo pipefail

awk '
BEGIN {
  # A dynamic regex, because a literal quote cannot be written inside the
  # single-quoted awk program this script passes to the shell.
  qre = "[" sprintf("%c%c", 39, 34) "]"
}

# emit closes the current step block, reporting the version pin it turned out to
# carry — or that it carried none this scanner could read.
function emit(   ) {
  if (blocktag != "") {
    if (blockver != "")     print "version\t" blockver "\t" blockverline
    else if (blockverseen)  print "version-unreadable\t" blocktag "\t" blocktagline
    else                    print "version-missing\t" blocktag "\t" blocktagline
  }
  inblock = 0; blocktag = ""; blockver = ""; blockverseen = 0
}

{
  line = $0
  if (line ~ /^[ \t]*#/) next        # a whole-line comment is documentation
  sub(/[ \t]+#.*$/, "", line)        # and so is a trailing one
  if (line ~ /^[ \t]*$/) next        # blanks never close a block
  gsub(qre, "", line)

  match(line, /^[ \t]*/); ind = RLENGTH
  isitem = (line ~ /^[ \t]*-[ \t]/)

  # A line indented no deeper than the `- ` that opened the block has left it.
  if (inblock && ind <= curind) emit()
  # …so a list nested INSIDE a step (still deeper) is not a new step.
  if (isitem && !inblock) { inblock = 1; curind = ind }

  if (match(line, /uses:[ \t]*akira-toriyama\/glyph\/[^@ \t]*@v[0-9][0-9.]*/)) {
    ref = substr(line, RSTART, RLENGTH)
    tag = ref; sub(/^.*@/, "", tag)
    print "uses\t" tag "\t" NR
    # Only the install composite carries a binary version; the reusable
    # workflows derive theirs from the tag the caller pinned.
    if (ref ~ /\/\.github\/actions\/install@/) { blocktag = tag; blocktagline = NR }
  }

  # Leading [ \t{,] rather than an anchored alternation: mawk is the awk on the
  # runner, and it also keeps `glyph-version:` from reading as `version:`. The
  # `{`/`,` cases are the flow form, `with: { version: vX.Y.Z, token: … }`.
  if (inblock && match(line, /[ \t{,]version:[ \t]*/)) {
    blockverseen = 1
    rest = substr(line, RSTART + RLENGTH)
    if (match(rest, /^v[0-9][0-9.]*/)) {
      blockver = substr(rest, RSTART, RLENGTH); blockverline = NR
    }
  }
}

END { emit() }
'
