#!/usr/bin/env bash
# Land a repo's rewritten glyph pins on its `glyph-pin/vX.Y.Z` branch as ONE
# commit on the default-branch tip the rewrite was computed from — and land
# nothing when that is already what the branch holds. glyph-pin-rewrite.yml
# calls this once per repo whose pins (or glyph.toml) need moving.
#
#   usage:  glyph-pin-land.sh <owner/repo> <base-sha> <pin-branch> <message> <src:dest>...
#   stdout: landed <n> <commit-sha>   the branch now points at a fresh commit
#           level <commit-sha>        the branch already held it; nothing written
#   exit:   0  landed or level
#           3  the branch carries commits this workflow did not author — left
#              untouched (the caller warns; a person owns that branch now)
#           1  any other API failure (the caller counts it skipped; the next
#              scheduled run is idempotent)
#           2  usage error
#
# THE INVARIANT: the pin branch is a pure function of (default-branch tip,
# canonical pin) — exactly one commit, parented on that tip, carrying the
# rewritten files. Every run re-derives that commit and force-moves the ref onto
# it; a branch already in that state is left alone. Two measured failures of the
# Contents-API-per-path writer this replaces (t-xr4k, 2026-09-24):
#
#   - the Contents API commits on every PUT, identical bytes included, so the
#     nightly apply stacked one EMPTY commit per night on every open pin branch
#     (chord#219: 9 commits, 8 empty, net diff one line);
#   - an existing branch was adopted as-is and never followed its base, so the
#     first fleet-sync push after the branch opened left every pin PR BEHIND
#     under `required_status_checks.strict` — 6 of the 17 v3.3.1 PRs sat
#     unmergeable for 8 days, `gh pr merge` refusing each one.
#
# Rebuilding on the tip closes both: identical bytes mean no commit, and a moved
# tip means one fresh commit on it. The force is safe BECAUSE of the author
# guard — the branch is rebuilt only when every commit on it is this workflow's
# own (exit 3 otherwise), so nothing a person pushed there is ever discarded.
#
# The base is the sha the CALLER read its files from, not the tip re-read here:
# a tip that moved between the read and the landing would otherwise have the
# rewrite of an older file planted over the newer one. Built on the older sha,
# the branch is merely behind by that commit, and the next run rebuilds it.
#
# WHAT IT PRESERVES, deliberately:
#   - the glyph-pin-rewrite[bot] AUTHOR: attribution, and the guard's key — it
#     is how a rebuild tells its own commits from a person's. The committer
#     stays the PAT user, as with the Contents API path this replaces.
#   - the message is passed in whole. The caller composes it from the pull
#     request's title, so a squash merge — which takes the commit's own subject
#     when a PR holds exactly one commit — carries the same `=` sigil the PR
#     title does.
#
# Files are written mode 100644 — pin sites live in workflow YAML and glyph.toml.
set -uo pipefail

full="${1:-}"; base="${2:-}"; branch="${3:-}"; message="${4:-}"; shift 4 2>/dev/null || true
if [ -z "$full" ] || [ -z "$base" ] || [ -z "$branch" ] || [ -z "$message" ] || [ "$#" -lt 1 ]; then
  echo "usage: glyph-pin-land.sh <owner/repo> <base-sha> <pin-branch> <message> <src:dest>..." >&2
  exit 2
fi

author='glyph-pin-rewrite[bot]'

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

base_tree="$(gh api "repos/$full/git/commits/$base" --jq .tree.sha)" \
  || { echo "cannot read the tree of $full@$base" >&2; exit 1; }

# blobs → one tree entry per file, on the base's tree. Blobs and trees are
# content-addressed: re-posting what already exists answers the same sha and
# writes nothing, so building the tree first is what lets "level" be decided by
# comparing whole trees rather than trusting a per-path read.
entries="[]"
for pair in "$@"; do
  src="${pair%%:*}"; dest="${pair##*:}"
  [ -f "$src" ] || { echo "source file missing: $src" >&2; exit 1; }
  b64="$(base64 < "$src" | tr -d '\n')"
  blob="$(gh api -X POST "repos/$full/git/blobs" -f "content=$b64" -f "encoding=base64" --jq .sha)" \
    || { echo "cannot create a blob for $dest on $full" >&2; exit 1; }
  entries="$(printf '%s' "$entries" | jq --arg p "$dest" --arg s "$blob" \
    '. + [{path: $p, mode: "100644", type: "blob", sha: $s}]')" \
    || { echo "cannot build the tree entry for $dest" >&2; exit 1; }
done
jq -n --arg base "$base_tree" --argjson tree "$entries" '{base_tree: $base, tree: $tree}' > "$tmp/tree.json" \
  || { echo "cannot build the tree payload" >&2; exit 1; }
tree="$(gh api -X POST "repos/$full/git/trees" --input "$tmp/tree.json" --jq .sha)" \
  || { echo "cannot create the tree on $full" >&2; exit 1; }

# The branch, if it exists. Level = one commit on the base with this exact
# tree; anything else (a moved tip, stacked commits, different bytes) is
# rebuilt — but only over this workflow's own commits.
exists=0
if head="$(gh api "repos/$full/git/ref/heads/$branch" --jq .object.sha 2>"$tmp/ref.err")"; then
  exists=1
  head_meta="$(gh api "repos/$full/git/commits/$head" --jq '"\(.tree.sha) \(.parents[0].sha // "-")"')" \
    || { echo "cannot read the commit at $full@$branch" >&2; exit 1; }
  if [ "${head_meta%% *}" = "$tree" ] && [ "${head_meta##* }" = "$base" ]; then
    echo "level $head"
    exit 0
  fi
  foreign="$(gh api "repos/$full/compare/$base...$branch" \
    | jq -r --arg a "$author" '[.commits[] | select(.commit.author.name != $a) | .sha[0:7]] | join(" ")')" \
    || { echo "cannot compare $full@$branch against $base" >&2; exit 1; }
  if [ -n "$foreign" ]; then
    echo "$full@$branch carries commit(s) not authored by $author ($foreign) — left untouched" >&2
    exit 3
  fi
elif ! grep -q 'HTTP 404' "$tmp/ref.err"; then
  # Only a 404 proves absence. Any other answer leaves the branch's state
  # UNKNOWN, and creating over an unknown branch is exactly what the author
  # guard above exists to prevent.
  echo "cannot read $full@$branch: $(head -c 200 "$tmp/ref.err")" >&2
  exit 1
fi

jq -n --arg msg "$message" --arg tree "$tree" --arg parent "$base" --arg a "$author" \
  '{message: $msg, tree: $tree, parents: [$parent],
    author: {name: $a, email: ($a + "@users.noreply.github.com")}}' > "$tmp/commit.json" \
  || { echo "cannot build the commit payload" >&2; exit 1; }
commit="$(gh api -X POST "repos/$full/git/commits" --input "$tmp/commit.json" --jq .sha)" \
  || { echo "cannot create the commit on $full" >&2; exit 1; }

if [ "$exists" -eq 1 ]; then
  gh api -X PATCH "repos/$full/git/refs/heads/$branch" -f "sha=$commit" -F force=true >/dev/null \
    || { echo "cannot move $full@$branch onto $commit" >&2; exit 1; }
else
  gh api -X POST "repos/$full/git/refs" -f "ref=refs/heads/$branch" -f "sha=$commit" >/dev/null \
    || { echo "cannot create $full@$branch at $commit" >&2; exit 1; }
fi
echo "landed $# $commit"
