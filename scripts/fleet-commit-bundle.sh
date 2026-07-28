#!/usr/bin/env bash
# Land every changed manifest file on a repo's default branch as ONE commit —
# one push, not N. fleet-sync.yml calls this once per repo that has changes.
#
#   usage:  fleet-commit-bundle.sh <owner/repo> <branch> <src:dest>...
#   stdout: bundled <n> <commit-sha>          (on success)
#   exit:   0  the ref moved to the bundled commit
#           3  the ref update was REFUSED with the branch tip unmoved — a
#              protected branch; the caller falls back to its per-file PR path
#           1  any other API failure (the caller counts it failed; the next
#              scheduled run is idempotent)
#           2  usage error
#
# WHY ONE COMMIT. The Contents API writes one commit per file, so a sync that
# updates two canonicals pushes twice, seconds apart — and every push fires the
# repo's release run. Across a fleet sweep those windows stack until several
# repos' release runs PATCH their rolling drafts in the same second and GitHub
# answers bare 403s (no Retry-After): the intermittent red t-z7c1 measured on
# 2026-07-21/26. The Git Data API (blob → tree → commit → ref) is the supported
# way to write N files in one push; this script exists because that sequence is
# too long to live readably inside a `run:` block, and extraction is what makes
# it table-testable (tests/fleet-commit-bundle.test.sh, stubbed `gh` — the
# apply-repo-settings.sh pattern).
#
# WHAT IT PRESERVES, deliberately:
#   - the fleet-sync[bot] AUTHOR — glyph's lint and release folds skip *[bot]
#     authors, and these commits must stay out of both (t-kbqx). The Git Data
#     API takes the author explicitly; the committer stays the PAT user, same
#     as the Contents API path this replaces.
#   - the single-file commit message, byte for byte — tooling and humans have
#     seen `:robot: chore(fleet): sync <dest>` since the first sync; only the
#     multi-file case gets a new (subject + body) shape.
#   - no force. The ref update names the base it built on; if the branch moved
#     meanwhile the update fails, the script re-reads the tip and rebuilds ON
#     the new base (twice at most). A REFUSED update with an unmoved tip is not
#     a race — it is branch protection, and that verdict (exit 3) is what
#     routes the caller to its PR fallback, the same split the Contents API
#     gave it for free.
#
# Files are written mode 100644 — every canonical fleet file is .yml/.md; an
# executable canonical would need a mode column in the manifest first.
set -uo pipefail

full="${1:-}"; branch="${2:-}"; shift 2 2>/dev/null || true
if [ -z "$full" ] || [ -z "$branch" ] || [ "$#" -lt 1 ]; then
  echo "usage: fleet-commit-bundle.sh <owner/repo> <branch> <src:dest>..." >&2
  exit 2
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# One message for one push. n=1 keeps the historical form exactly; n>1 says
# how many and lists them in the body, one per line.
message() {
  if [ "$#" -eq 1 ]; then
    printf ':robot: chore(fleet): sync %s' "$1"
  else
    printf ':robot: chore(fleet): sync %d standard files in one push\n\n' "$#"
    printf '%s\n' "$@"
  fi
}

attempt=0
while :; do
  attempt=$((attempt + 1))

  base="$(gh api "repos/$full/git/ref/heads/$branch" --jq .object.sha)" \
    || { echo "cannot read the tip of $full@$branch" >&2; exit 1; }
  base_tree="$(gh api "repos/$full/git/commits/$base" --jq .tree.sha)" \
    || { echo "cannot read the tree of $full@$base" >&2; exit 1; }

  # blobs → one tree entry per changed file
  entries="[]"
  dests=()
  for pair in "$@"; do
    src="${pair%%:*}"; dest="${pair##*:}"
    [ -f "$src" ] || { echo "source file missing: $src" >&2; exit 1; }
    b64="$(base64 < "$src" | tr -d '\n')"
    blob="$(gh api -X POST "repos/$full/git/blobs" \
      -f "content=$b64" -f "encoding=base64" --jq .sha)" \
      || { echo "cannot create a blob for $dest on $full" >&2; exit 1; }
    entries="$(printf '%s' "$entries" | jq --arg p "$dest" --arg s "$blob" \
      '. + [{path: $p, mode: "100644", type: "blob", sha: $s}]')" \
      || { echo "cannot build the tree entry for $dest" >&2; exit 1; }
    dests+=("$dest")
  done

  jq -n --arg base "$base_tree" --argjson tree "$entries" \
    '{base_tree: $base, tree: $tree}' > "$tmp/tree.json" \
    || { echo "cannot build the tree payload" >&2; exit 1; }
  tree="$(gh api -X POST "repos/$full/git/trees" --input "$tmp/tree.json" --jq .sha)" \
    || { echo "cannot create the tree on $full" >&2; exit 1; }

  jq -n --arg msg "$(message "${dests[@]}")" --arg tree "$tree" --arg parent "$base" \
    '{message: $msg, tree: $tree, parents: [$parent],
      author: {name: "fleet-sync[bot]", email: "fleet-sync[bot]@users.noreply.github.com"}}' \
    > "$tmp/commit.json" \
    || { echo "cannot build the commit payload" >&2; exit 1; }
  commit="$(gh api -X POST "repos/$full/git/commits" --input "$tmp/commit.json" --jq .sha)" \
    || { echo "cannot create the commit on $full" >&2; exit 1; }

  if gh api -X PATCH "repos/$full/git/refs/heads/$branch" -f "sha=$commit" >/dev/null 2>"$tmp/ref.err"; then
    echo "bundled $# $commit"
    exit 0
  fi

  # The update failed. A moved tip is a race — rebuild on the new base. An
  # unmoved tip means the branch itself refused us: protection, so hand the
  # caller its PR-fallback verdict instead of guessing from an error string.
  now="$(gh api "repos/$full/git/ref/heads/$branch" --jq .object.sha)" \
    || { echo "ref update failed and the tip of $full@$branch cannot be re-read: $(head -c 200 "$tmp/ref.err")" >&2; exit 1; }
  if [ "$now" = "$base" ]; then
    echo "ref update refused on $full@$branch with the tip unmoved — protected branch: $(head -c 200 "$tmp/ref.err")" >&2
    exit 3
  fi
  if [ "$attempt" -ge 2 ]; then
    echo "the tip of $full@$branch keeps moving ($base -> $now); giving up this run (the next sync is idempotent)" >&2
    exit 1
  fi
done
