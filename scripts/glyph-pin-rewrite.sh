#!/usr/bin/env bash
# Move every glyph pin in ONE workflow / action YAML to a target release tag.
# Reads the file on stdin, writes the rewritten file on stdout.
#
#   glyph-pin-rewrite.sh vX.Y.Z < in.yml > out.yml
#
# Exit codes are a machine API — the caller branches on the integer, never on
# truthiness (a `if rewrite …; then` cannot tell 3 from 4, and 3 and 4 mean
# opposite things about whose fault it is):
#
#   0  stdout is the file with every glyph pin at <want>. Byte-identical to the
#      input when nothing needed moving — the caller compares and skips.
#   2  usage.
#   3  REFUSED, and this is a bug in THIS script: the rewrite would have changed
#      a line that carries no glyph pin, changed the line count, or left a pin
#      still off <want>. Nothing is written. A caller must fail loudly, not skip.
#   4  REFUSED, and this is the FILE's state: it carries a glyph pin no
#      mechanical rewrite can move (an install step with no `version:`, or one
#      that computes it). Nothing is written. A caller warns and leaves the file
#      to the audit, which is already red about it.
#
# WHY A REWRITER EXISTS AT ALL. Five things reference glyph and fleet-sync
# distributes two (docs/glyph-rollout-runbook.md). The other three — a
# `release.yml` that calls glyph's release reusable, an `actions/install@` pin,
# and the `version:` two lines under it — live in files that are BESPOKE per
# repo, so they cannot be byte-copied: fleet-sync's MANIFEST would overwrite 14
# different release.yml files with one, and fleet-sync refuses that dest for
# exactly this reason. Until now the only propagation path for those three was a
# human opening one PR per repo per glyph release; the v0.11.2 rollout was 22
# references across 14 repos. This script is the machine half of that: it moves
# the pin LINES and nothing else, so a bespoke file survives the edit.
#
# WHY IT DELEGATES ITS EYES. Which lines are glyph pins is decided by
# scripts/glyph-pin-scan.sh — the same reader glyph-pin-audit.yml uses. One
# reader, one truth: a rewriter with its own idea of what a pin is would move
# lines the audit does not check and miss lines it does, and the disagreement
# would only ever surface as a red audit after the write had landed in ~14 repos.
#
# THE THREE TRAPS THIS ENCODES, all found by doing the v0.11.2 rollout by hand:
#
#   1. DO NOT SEARCH BY PATH. `sill` keeps its install step in
#      `.github/workflows/build.yml`; the other eight call it `release.yml`. A
#      path-keyed rewriter drops sill silently. This script is handed a file and
#      never chooses one, so the caller must enumerate by CONTENT.
#   2. DO NOT TOUCH COMMENTS. Every glyph reusable ships a commented caller stub
#      whose `@vX.Y.Z` placeholder must STAY a placeholder — glyph's own
#      internal/workflows test fails a concrete version in that comment, because
#      a tag is cut on an already-frozen tree so any version written there is
#      stale on arrival. The scanner skips comment lines, so they are never in
#      the rewrite set.
#   3. DO NOT TOUCH A STRANGER'S `version:`. It is a generic input name; the only
#      thing that makes one a glyph pin is the step it sits in. The scanner
#      resolves that, and this script rewrites the line NUMBERS it reported
#      rather than re-matching text of its own.
#
# AND THE CHECK THAT MAKES ALL THREE ENFORCED RATHER THAN INTENDED. After
# rewriting, the result is (a) compared line-by-line against the input — any
# differing line outside the reported set, or any change in line count, is exit 3
# — and (b) fed back through the scanner, which must now report every pin at
# <want>. (b) is the real oracle: it asks the audit's own eyes whether the file
# is level, rather than trusting the substitution that just ran.
set -uo pipefail

# The SAME shape glyph-pin-scan.sh calls a concrete release tag, deliberately:
# anything it would classify as `uses-unpinned` is drift, and a rewriter that
# accepted one as its TARGET would re-point the whole fleet at a moving ref in a
# single run. A `case` glob is not enough here — `v[0-9]*.[0-9]*.[0-9]*` happily
# swallows `v0.12.0-rc.1`.
want="${1:-}"
if ! [[ "$want" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: $0 vX.Y.Z < file.yml > rewritten.yml" >&2
  echo "  got '$want' — the target must be a concrete release tag: not a branch," >&2
  echo "  not a SHA, not a moving major, not a prerelease, not empty." >&2
  exit 2
fi

here="$(cd "$(dirname "$0")" && pwd)"
scan="$here/glyph-pin-scan.sh"
[ -f "$scan" ] || { echo "$0: missing $scan — the rewriter has no eyes without it" >&2; exit 3; }

tmp="$(mktemp)"; out="$(mktemp)"
trap 'rm -f "$tmp" "$out" "$out.trim"' EXIT
cat > "$tmp"

records="$(bash "$scan" < "$tmp")" || { echo "$0: scanner failed" >&2; exit 3; }

# An install step whose binary version cannot be read is not a rewrite this
# script may guess at: inserting a `version:` is a structural edit, and replacing
# a computed one silently freezes an expression someone wrote on purpose. Report
# and refuse — the audit is already red about these, and staying red is correct.
unfixable="$(printf '%s\n' "$records" | awk -F'\t' '$1 == "version-missing" || $1 == "version-unreadable" { print $1 " at line " $3 }')"
if [ -n "$unfixable" ]; then
  echo "$0: refusing — this file carries a glyph pin no mechanical rewrite can move:" >&2
  printf '%s\n' "$unfixable" | sed 's/^/  /' >&2
  exit 4
fi

# The lines to touch, and how. `uses`/`uses-unpinned` carry a ref after an `@`;
# `version` carries a bare tag after the key. Emitted even when already at
# <want> — rewriting a line to what it already says is a no-op, and narrowing the
# set here would mean two places decide what a pin is.
uses_lines="$(printf '%s\n' "$records" | awk -F'\t' '$1 == "uses" || $1 == "uses-unpinned" { print $3 }' | tr '\n' ' ')"
ver_lines="$(printf '%s\n' "$records" | awk -F'\t' '$1 == "version" { print $3 }' | tr '\n' ' ')"

if [ -z "${uses_lines// /}" ] && [ -z "${ver_lines// /}" ]; then
  cat "$tmp"   # no glyph reference at all — most of the fleet's ~36 repos of YAML
  exit 0
fi

awk -v want="$want" -v usesl="$uses_lines" -v verl="$ver_lines" '
BEGIN {
  n = split(usesl, a, " "); for (i = 1; i <= n; i++) if (a[i] != "") U[a[i] + 0] = 1
  n = split(verl,  b, " "); for (i = 1; i <= n; i++) if (b[i] != "") V[b[i] + 0] = 1
  # A literal quote cannot be written inside this single-quoted shell string.
  q = sprintf("%c%c", 39, 34)
  # A ref runs until the first character that cannot be in one. Branch names may
  # contain "/", tags "-" and "."; what ENDS a ref is whitespace, a quote, a
  # comment, or the flow-form punctuation.
  delim = "[^-A-Za-z0-9._/]"
}

# Replace the ref after the first `akira-toriyama/glyph/…@` on the line, keeping
# whatever follows it (a trailing comment, a closing quote, a flow-form comma).
function retag(line,   head, rest, n2) {
  if (!match(line, /akira-toriyama\/glyph\/[^@ \t]*@/)) return line
  head = substr(line, 1, RSTART + RLENGTH - 1)
  rest = substr(line, RSTART + RLENGTH)
  n2 = match(rest, delim)
  return head want (n2 > 0 ? substr(rest, n2) : "")
}

# Same idea for the binary pin. The optional quote goes in the HEAD so that
# `version: "v0.8.0"` keeps its quotes instead of growing a stray one.
function reversion(line,   head, rest) {
  if (!match(line, "[ \t{,]version:[ \t]*[" q "]?")) return line
  head = substr(line, 1, RSTART + RLENGTH - 1)
  rest = substr(line, RSTART + RLENGTH)
  if (!match(rest, /^v[0-9][0-9.]*/)) return line
  return head want substr(rest, RSTART + RLENGTH)
}

{
  line = $0
  # Not else-if: a flow-form step can carry both on one line.
  if (NR in U) line = retag(line)
  if (NR in V) line = reversion(line)
  print line
}
' "$tmp" > "$out"

# awk terminates its last line whether or not the input did. A file that ships
# without a trailing newline must come back without one, or "unchanged" stops
# being byte-exact and the caller opens the same no-op PR on every run forever.
if [ -s "$tmp" ] && [ "$(tail -c 1 "$tmp" | wc -l | tr -d ' ')" -eq 0 ]; then
  head -c "$(( $(wc -c < "$out") - 1 ))" "$out" > "$out.trim" && mv "$out.trim" "$out"
fi

# ---------------------------------------------------------------------------
# (a) Nothing outside the reported lines moved, and the file is the same length.
#
# This is the check that turns "the regexes above are careful" into something a
# reviewer does not have to take on faith. The hand rollout that motivated this
# script ran the same check by eye across 14 repos before applying; doing it in
# code is the only version that survives the next release.
# ---------------------------------------------------------------------------
stray="$(awk -v usesl="$uses_lines" -v verl="$ver_lines" '
BEGIN {
  n = split(usesl, a, " "); for (i = 1; i <= n; i++) if (a[i] != "") K[a[i] + 0] = 1
  n = split(verl,  b, " "); for (i = 1; i <= n; i++) if (b[i] != "") K[b[i] + 0] = 1
}
NR == FNR { old[FNR] = $0; oldn = FNR; next }
          { new[FNR] = $0; newn = FNR }
END {
  if (oldn != newn) { print "line count changed: " oldn " -> " newn; exit }
  for (i = 1; i <= oldn; i++)
    if (old[i] != new[i] && !(i in K)) print "line " i " changed but carries no glyph pin"
}
' "$tmp" "$out")"
if [ -n "$stray" ]; then
  echo "$0: refusing — the rewrite touched something that is not a glyph pin:" >&2
  printf '%s\n' "$stray" | sed 's/^/  /' >&2
  exit 3
fi

# ---------------------------------------------------------------------------
# (b) The audit's own eyes, run over the result. A substitution that quietly
# matched nothing leaves the file unchanged and would otherwise be reported as a
# clean rewrite — this is what catches that.
# ---------------------------------------------------------------------------
left="$(bash "$scan" < "$out" | awk -F'\t' -v want="$want" '$2 != want { print $1 " " $2 " at line " $3 }')"
if [ -n "$left" ]; then
  echo "$0: refusing — after rewriting, these pins are still not $want:" >&2
  printf '%s\n' "$left" | sed 's/^/  /' >&2
  exit 3
fi

cat "$out"
