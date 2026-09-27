#!/usr/bin/env bash
# Classify ONE open bot pull request for fleet-automerge: may the machine arm
# auto-merge on it, or does a person have to look?
#
#   usage:  automerge-tier.sh <head-branch> <title> [< commit-messages]
#   stdout: <verdict>TAB<detail>   exactly one line
#           auto    a minor / patch bump, or a fleet-sync canonical — arm it
#           major   a major bump — a person merges (or declines) it
#           hold    unclassifiable — a person looks: prerelease, a non-semver
#                   bump (SHA -> SHA), no version pair, an unknown branch family
#   exit:   0 with a verdict; 2 usage
#
# THE FAMILY IS THE HEAD BRANCH, the tier is read where each producer writes it:
#
#   glyph-pin/*    the title glyph-pin-rewrite composes carries `(vA -> vB)`;
#                  the tier is the first differing component of A and B.
#   fleet-sync/*   always auto. The bytes are a canonical the hub already pushed
#                  straight onto 30+ default branches; the pull request exists
#                  only because this one repo protects its branch, and the
#                  protection's required checks are the reviewer.
#   dependabot/*   the `updated-dependencies:` trailer of the commit message, the
#                  same source dependabot/fetch-metadata reads. Every entry has
#                  `update-type: version-update:semver-{major,minor,patch}` — a
#                  group takes its highest — EXCEPT a bump between two commit
#                  SHAs (an action pinned by hash), which carries no update-type
#                  at all: that is a hold, never a guess from the digest.
#
# FAIL CLOSED. Anything this cannot read as a tier is `hold`, and hold arms
# nothing. The cost of a wrong hold is one bot PR merged by hand, as all of them
# were until now; the cost of a wrong auto is a major landing unread.
#
# Why not parse "from A to B" prose for dependabot: the commit body quotes
# release notes, and release notes say "from X to Y" about anything. The trailer
# is structured and dependabot's own verdict.
#
# Why the semver components decide even under 0.x: the repo's required checks
# (build + tests) are the reviewer of a minor bump, and the fleet's own 0.x
# dependencies (golang.org/x/*) move that way monthly. Whether a 0.x minor may
# break is a question those checks answer better than a version string.
set -uo pipefail

head="${1:-}"; title="${2:-}"
if [ -z "$head" ] || [ -z "$title" ]; then
  echo "usage: automerge-tier.sh <head-branch> <title> [< commit-messages]" >&2
  exit 2
fi

verdict() { printf '%s\t%s\n' "$1" "$2"; exit 0; }

# component <version> <index> — the Nth dot-separated number of a `v`-less
# version, 0 when absent (`v4` is 4.0.0).
component() {
  local v="${1#v}" i="$2" IFS=.
  # shellcheck disable=SC2086  # word-splitting on `.` is the point
  set -- $v
  local n="${!i:-0}"
  printf '%s' "${n:-0}"
}

# tier_of <from> <to> — the first differing component; "same" when none.
tier_of() {
  local a b i
  for i in 1 2 3; do
    a="$(component "$1" "$i")"; b="$(component "$2" "$i")"
    if [ "$a" != "$b" ]; then
      case "$i" in 1) echo major ;; 2) echo minor ;; 3) echo patch ;; esac
      return
    fi
  done
  echo same
}

case "$head" in
  fleet-sync/*)
    verdict auto "fleet-sync canonical" ;;

  glyph-pin/*)
    pair="$(printf '%s\n' "$title" | grep -oE '\(v?[0-9][^ ()]* -> v?[0-9][^ ()]*\)' | head -n1)"
    [ -n "$pair" ] || verdict hold 'no "(vA -> vB)" in the title'
    pair="${pair#(}"; pair="${pair%)}"
    from="${pair%% -> *}"; to="${pair##* -> }"
    for v in "$from" "$to"; do
      printf '%s' "${v#v}" | grep -qE '^[0-9]+(\.[0-9]+)*$' || verdict hold "$from -> $to is not a release-to-release move"
    done
    t="$(tier_of "$from" "$to")"
    case "$t" in
      major) verdict major "$from -> $to" ;;
      same)  verdict hold "$from -> $to moves nothing" ;;
      *)     verdict auto "$from -> $to ($t)" ;;
    esac ;;

  dependabot/*)
    # The trailer is YAML between `---` and `...`; entries begin at
    # `- dependency-name:`. Several commits on stdin accumulate (a rebased
    # dependabot PR still carries one, but nothing here depends on that).
    summary="$(awk '
      /^updated-dependencies:/ { inside = 1; next }
      /^\.\.\.$/                { inside = 0; next }
      !inside                   { next }
      /^- dependency-name:/ {
        entries++
        name = $0; sub(/^- dependency-name:[[:space:]]*/, "", name); gsub(/^["'"'"']|["'"'"']$/, "", name)
        names[entries] = name; typed[entries] = ""
        next
      }
      entries && /^[[:space:]]+update-type:[[:space:]]*version-update:semver-(major|minor|patch)[[:space:]]*$/ {
        t = $0; sub(/.*semver-/, "", t); sub(/[[:space:]]+$/, "", t)
        typed[entries] = t
      }
      END {
        if (!entries) { print "none"; exit }
        rank["patch"] = 1; rank["minor"] = 2; rank["major"] = 3
        high = ""; highrank = 0; untyped = ""
        for (i = 1; i <= entries; i++) {
          if (typed[i] == "") { if (untyped == "") untyped = names[i]; continue }
          if (rank[typed[i]] > highrank) { highrank = rank[typed[i]]; high = typed[i] }
        }
        if (untyped != "") { print "untyped\t" untyped; exit }
        print high "\t" entries
      }')"
    kind="${summary%%	*}"; rest="${summary#*	}"
    case "$kind" in
      none)    verdict hold "no updated-dependencies trailer in the commit message" ;;
      untyped) verdict hold "$rest has no semver update-type (a SHA or non-semver bump)" ;;
      major)   verdict major "$rest update(s), highest semver-major" ;;
      *)       verdict auto "$rest update(s), highest semver-$kind" ;;
    esac ;;

  *)
    verdict hold "$head is not a bot branch family (glyph-pin/ fleet-sync/ dependabot/)" ;;
esac
