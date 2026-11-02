#!/usr/bin/env bash
# Open ONE pull request that drops ONE exact line from a repository's
# glyph.toml — the config half of a glyph major that removes a key, landed
# under the current pin before the major ships (docs/glyph-rollout-runbook.md,
# "A major that removes a `glyph.toml` key"). Everything goes through the API;
# nothing is cloned.
#
#   usage:  glyph-config-drop.sh <owner/repo> <exact-line> <branch> <message-file> <body-file> [--dry]
#   env:    GLYPH  the glyph binary to lint with — the binary of the CURRENT
#                  pin (required: this script installs nothing)
#   stdout: <owner/repo> <pr-url> commit=<sha>         the pull request is open
#           <owner/repo> dry ok <branch>@<short-sha>   --dry: every check passed
#                                                      and <branch> is free; it
#                                                      would start at that tip
#                                                      sha. Nothing was written
#   exit:   0  opened, or dry ok
#           3  skipped: the default branch has no glyph.toml, holds the line
#              zero times or more than once, or dropping it would change more
#              than that one line
#           4  the message, or its first line as the pull request's title,
#              fails lint, or lints only as unlandable, under the repository's
#              old or new glyph.toml
#           1  any API failure, an existing <branch> included — reported,
#              never forced
#           2  usage
#
# The file is read at the default branch's TIP SHA and the branch is created on
# that same sha, so the blob sha the PUT names is the blob the new branch holds
# and the pull's one commit sits on the commit its edit was computed from.
#
# The line is matched as a whole string (awk `==` over ENVIRON), never as a
# pattern — a TOML line can carry regex metacharacters — and both sides are
# concatenated with "" first: awk compares two numeric-looking strings as
# numbers, so a bare `2` would otherwise match `  2`, `2.0` and `+2`. A file
# with CRLF endings matches nothing and is skipped. The one-line-diff check
# refuses a rewrite that would touch anything else, e.g. a last line awk would
# add a newline to.
#
# WHY BOTH CONFIGS. The pull request is judged under both files: glyph's
# pr-verdict.yml checks out the BASE branch (the old glyph.toml) and lint.yml
# the pull's own ref (the new one) — their checkout steps in glyph's
# .github/workflows. The first line is linted on its own as well because
# lint.yml's "Lint the squash title" step lints the pull's title
# (`lint --pr`), and the title is that line. `lint --stdin` is the authoring
# mode: a message an `unlandable` pattern claims passes it at exit 0 with a
# `::warning::` naming it unlandable, and every gate that judges an existing
# commit refuses it (glyph's words) — so that warning is a refusal here. Each lint runs in a throwaway
# `git init` under mktemp with no global or system git config, so neither the
# target's history nor this machine's settings (a commentChar, a cleanup mode)
# play a part.
set -uo pipefail

usage() {
  echo "usage: glyph-config-drop.sh <owner/repo> <exact-line> <branch> <message-file> <body-file> [--dry]" >&2
  exit 2
}

[ "$#" -eq 5 ] || [ "$#" -eq 6 ] || usage
full="$1"; line="$2"; branch="$3"; msg_file="$4"; body_file="$5"; dry=0
if [ "$#" -eq 6 ]; then
  [ "$6" = "--dry" ] || usage
  dry=1
fi
case "$full" in */*) ;; *) usage ;; esac
{ [ -n "$line" ] && [ -n "$branch" ]; } || usage
[ -s "$msg_file" ] || { echo "message file missing or empty: $msg_file" >&2; exit 2; }
[ -f "$body_file" ] || { echo "body file missing: $body_file" >&2; exit 2; }
{ [ -n "${GLYPH:-}" ] && glyph="$(command -v "$GLYPH")" && [ -x "$glyph" ]; } \
  || { echo "GLYPH must name an executable glyph binary (the current pin's)" >&2; exit 2; }
# The lints run after a cd into the throwaway repository.
case "$glyph" in /*) ;; *) glyph="$(pwd)/$glyph" ;; esac

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

{ db="$(gh api "repos/$full" --jq .default_branch)" && [ -n "$db" ]; } \
  || { echo "$full: cannot read the default branch" >&2; exit 1; }
{ tip="$(gh api "repos/$full/git/ref/heads/$db" --jq .object.sha)" && [ -n "$tip" ]; } \
  || { echo "$full: cannot read the tip of $db" >&2; exit 1; }

if ! gh api "repos/$full/contents/glyph.toml?ref=$tip" > "$tmp/contents.json" 2>"$tmp/contents.err"; then
  if grep -q 'HTTP 404' "$tmp/contents.err"; then
    echo "$full: no glyph.toml at $db@$tip — nothing to drop, skipped" >&2
    exit 3
  fi
  echo "$full: cannot read glyph.toml at $tip: $(head -c 200 "$tmp/contents.err")" >&2
  exit 1
fi
{ blob="$(jq -r .sha "$tmp/contents.json")" && [ -n "$blob" ] && [ "$blob" != null ]; } \
  || { echo "$full: glyph.toml answered without a blob sha" >&2; exit 1; }
jq -r .content "$tmp/contents.json" | base64 -d > "$tmp/old.toml" \
  || { echo "$full: cannot decode glyph.toml" >&2; exit 1; }

n="$(DROP_LINE="$line" awk '($0 "") == (ENVIRON["DROP_LINE"] "") { n++ } END { print n + 0 }' "$tmp/old.toml")"
if [ "$n" -ne 1 ]; then
  echo "$full: glyph.toml holds the line $n time(s), not exactly once — skipped" >&2
  exit 3
fi
DROP_LINE="$line" awk '($0 "") != (ENVIRON["DROP_LINE"] "")' "$tmp/old.toml" > "$tmp/new.toml"
d="$(diff "$tmp/old.toml" "$tmp/new.toml" | grep -c '^[<>]')"
if [ "$d" -ne 1 ]; then
  echo "$full: dropping the line changes $d line(s), not one — skipped" >&2
  exit 3
fi

title="$(head -n 1 "$msg_file")"
printf '%s\n' "$title" > "$tmp/title.txt"
in_lint_repo() { ( cd "$1" && shift && GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null "$@" ); }
# lint_or_exit4 <message|title> <old|new> <lint-dir> < input — never called in
# a pipeline: its exit must end the script, not a subshell.
lint_or_exit4() {
  local what="$1" cfg="$2" dir="$3" rc
  in_lint_repo "$dir" "$glyph" lint --stdin >/dev/null 2>"$tmp/lint.err"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "$full: the $what fails lint under the $cfg glyph.toml (exit $rc): $(head -c 300 "$tmp/lint.err" | tr '\n' ' ')" >&2
    exit 4
  fi
  if grep -q unlandable "$tmp/lint.err"; then
    echo "$full: the $what lints only as unlandable under the $cfg glyph.toml, which every gate that judges an existing commit refuses: $(head -c 300 "$tmp/lint.err" | tr '\n' ' ')" >&2
    exit 4
  fi
}
for cfg in old new; do
  lint_dir="$tmp/lint-$cfg"
  mkdir -p "$lint_dir"
  cp "$tmp/$cfg.toml" "$lint_dir/glyph.toml"
  in_lint_repo "$lint_dir" git init -q \
    || { echo "$full: cannot create the throwaway lint repository" >&2; exit 1; }
  lint_or_exit4 message "$cfg" "$lint_dir" < "$msg_file"
  lint_or_exit4 title "$cfg" "$lint_dir" < "$tmp/title.txt"
done

# Only a 404 proves the branch is free; a branch that exists may be a person's
# work, and this never moves a ref it did not create.
if gh api "repos/$full/git/ref/heads/$branch" >/dev/null 2>"$tmp/ref.err"; then
  echo "$full: branch $branch already exists — not forcing it; delete it or pick another name" >&2
  exit 1
elif ! grep -q 'HTTP 404' "$tmp/ref.err"; then
  echo "$full: cannot tell whether $branch exists: $(head -c 200 "$tmp/ref.err")" >&2
  exit 1
fi

if [ "$dry" -eq 1 ]; then
  echo "$full dry ok $branch@$(printf '%.7s' "$tip")"
  exit 0
fi

gh api -X POST "repos/$full/git/refs" -f "ref=refs/heads/$branch" -f "sha=$tip" >/dev/null \
  || { echo "$full: cannot create $branch at $tip" >&2; exit 1; }
{ commit="$(gh api -X PUT "repos/$full/contents/glyph.toml" \
  -f "message=$(cat "$msg_file")" \
  -f "content=$(base64 < "$tmp/new.toml" | tr -d '\n')" \
  -f "sha=$blob" -f "branch=$branch" --jq .commit.sha)" && [ -n "$commit" ]; } \
  || { echo "$full: cannot commit glyph.toml on $branch (the branch exists now, at $tip)" >&2; exit 1; }
url="$(gh pr create --repo "$full" --base "$db" --head "$branch" --title "$title" --body-file "$body_file")" \
  || { echo "$full: cannot open the pull request ($branch carries $commit; open it by hand)" >&2; exit 1; }
echo "$full $url commit=$commit"
