#!/usr/bin/env bash
# Table-test scripts/glyph-pin-land.sh — the writer that lands a repo's pin
# move on its `glyph-pin/vX.Y.Z` branch. Runs the REAL script (drift-free)
# against a stubbed `gh` on PATH, the fleet-commit-bundle.test.sh pattern.
# Needs bash + jq only.
#
# The properties under test are the two t-xr4k exists for. A branch that
# already holds the rewrite — one commit on the base with the same tree —
# receives NOTHING: the Contents-API writer this replaced committed on every
# PUT and stacked one empty commit per night on every open pull request. And a
# branch whose base moved (or that stacked commits) is REBUILT as one commit on
# the base, its ref force-moved: 6 of the 17 v3.3.1 pull requests sat BEHIND
# under strict protection for 8 days because the old writer only ever adopted
# the branch it found. The force is fenced by the author guard, pinned here
# too: a commit this workflow did not author leaves the branch untouched.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
script="$root/scripts/glyph-pin-land.sh"
fails=0

[ -f "$script" ] || { echo "FAIL - $script is missing"; exit 1; }

stub_dir="$(mktemp -d)"
trap 'rm -rf "$stub_dir"' EXIT

# A `gh` that answers the Git Data API from files under $STUB_HOME and appends
# every call (verb, path, then any -f/-F fields) to $STUB_HOME/calls.log:
#   $STUB_HOME/pin            sha of the pin branch; absent = the ref 404s
#   $STUB_HOME/pin-meta       "<tree> <parent>" of the pin branch's commit
#   $STUB_HOME/authors        one author per line: compare's commit list
#   $STUB_HOME/ref-500        present = reading the pin ref fails, not 404
#   $STUB_HOME/fail-blobs     present = POST git/blobs fails
cat >"$stub_dir/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
[ "${1:-}" = "api" ] || { echo "stub gh: unhandled command: $*" >&2; exit 64; }
shift
verb=GET; path=""; jqexpr=""; input=""; fields=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -X) verb="$2"; shift 2 ;;
    -f|-F) fields="$fields $2"; shift 2 ;;
    --jq) jqexpr="$2"; shift 2 ;;
    --input) input="$2"; shift 2 ;;
    -*) shift ;;
    *) [ -n "$path" ] || path="$1"; shift ;;
  esac
done
printf '%s %s%s\n' "$verb" "$path" "$fields" >> "$STUB_HOME/calls.log"
emit() { if [ -n "$jqexpr" ]; then printf '%s' "$1" | jq -r "$jqexpr"; else printf '%s\n' "$1"; fi; }
case "$verb $path" in
  "GET "*/git/commits/base-*)
    emit '{"tree":{"sha":"tree-of-base"},"parents":[{"sha":"base-0"}]}' ;;
  "GET "*/git/commits/pin-*)
    read -r t p < "$STUB_HOME/pin-meta"
    emit "{\"tree\":{\"sha\":\"$t\"},\"parents\":[{\"sha\":\"$p\"}]}" ;;
  "GET "*/git/ref/heads/glyph-pin/*)
    [ -e "$STUB_HOME/ref-500" ] && { echo "HTTP 500" >&2; exit 1; }
    [ -e "$STUB_HOME/pin" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    emit "{\"object\":{\"sha\":\"$(cat "$STUB_HOME/pin")\"}}" ;;
  "GET "*/compare/*)
    commits="$(jq -R '{sha: ("c-" + (. | gsub(" "; "-"))), commit: {author: {name: .}}}' "$STUB_HOME/authors" | jq -s .)"
    emit "{\"commits\":$commits}" ;;
  "POST "*/git/blobs)
    [ -e "$STUB_HOME/fail-blobs" ] && { echo "HTTP 500" >&2; exit 1; }
    n="$(grep -c 'POST .*git/blobs' "$STUB_HOME/calls.log")"
    emit "{\"sha\":\"blob-$n\"}" ;;
  "POST "*/git/trees)
    cp "$input" "$STUB_HOME/tree-payload.json"
    emit '{"sha":"tree-new"}' ;;
  "POST "*/git/commits)
    cp "$input" "$STUB_HOME/commit-payload.json"
    n="$(grep -c 'POST .*git/commits' "$STUB_HOME/calls.log")"
    emit "{\"sha\":\"commit-$n\"}" ;;
  "POST "*/git/refs) exit 0 ;;
  "PATCH "*/git/refs/heads/*) exit 0 ;;
  *) echo "stub gh: unhandled $verb $path" >&2; exit 64 ;;
esac
STUB
chmod +x "$stub_dir/gh"

# fresh [pin-sha] — reset the stub world (a pin branch at that sha, if given)
# and the two source files.
fresh() {
  export STUB_HOME="$stub_dir/home"
  rm -rf "$STUB_HOME"; mkdir -p "$STUB_HOME"
  : > "$STUB_HOME/calls.log"; : > "$STUB_HOME/authors"
  [ -z "${1:-}" ] || printf '%s\n' "$1" > "$STUB_HOME/pin"
  printf 'pinned one\n' > "$stub_dir/one.yml"
  printf 'pinned two\n' > "$stub_dir/two.toml"
}

msg=':arrow_up:(ci)= pin glyph v9.9.9 (v9.9.8 -> v9.9.9)

.github/workflows/release.yml
glyph.toml'
pairs=("$stub_dir/one.yml:.github/workflows/release.yml" "$stub_dir/two.toml:glyph.toml")

run_script() { PATH="$stub_dir:$PATH" bash "$script" "$@" 2>"$stub_dir/err"; }
land() { run_script o/r base-1 glyph-pin/v9.9.9 "$msg" "${pairs[@]}"; }

jqe() { jq -e "$1" "$2" >/dev/null; }
calls() { grep -c -- "$1" "$STUB_HOME/calls.log"; }

check() { # check <name> <condition...>
  local name="$1"; shift
  if "$@"; then echo "ok   - $name"; else
    echo "FAIL - $name"
    sed 's/^/         stderr: /' "$stub_dir/err"
    sed 's/^/         calls:  /' "$STUB_HOME/calls.log" 2>/dev/null
    fails=$((fails + 1))
  fi
}

# usage
fresh
run_script >/dev/null; rc=$?
check "no arguments is usage (exit 2)" [ "$rc" -eq 2 ]
run_script o/r base-1 glyph-pin/v9.9.9 "$msg" >/dev/null; rc=$?
check "no files is usage (exit 2)" [ "$rc" -eq 2 ]

# no branch yet: created at ONE commit on the base
fresh
out="$(land)"; rc=$?
check "a missing branch lands: exit 0, landed 2" \
  [ "$rc" -eq 0 -a "$out" = "landed 2 commit-1" ]
check "the ref is CREATED at that commit, never PATCHed" \
  [ "$(calls '^POST .*git/refs ref=refs/heads/glyph-pin/v9.9.9 sha=commit-1$')" -eq 1 -a "$(calls '^PATCH')" -eq 0 ]
check "exactly ONE commit for two files" \
  [ "$(calls '^POST .*git/commits$')" -eq 1 ]
check "the tree carries both paths on the base tree, mode 100644" \
  jqe '.base_tree == "tree-of-base"
         and (.tree | map(.path) == [".github/workflows/release.yml", "glyph.toml"])
         and (.tree | all(.mode == "100644"))' "$STUB_HOME/tree-payload.json"
check "the commit is the bot's, parented on the base, message verbatim" \
  jqe '.author.name == "glyph-pin-rewrite[bot]"
         and .author.email == "glyph-pin-rewrite[bot]@users.noreply.github.com"
         and .parents == ["base-1"]
         and .message == ":arrow_up:(ci)= pin glyph v9.9.9 (v9.9.8 -> v9.9.9)\n\n.github/workflows/release.yml\nglyph.toml"' \
  "$STUB_HOME/commit-payload.json"

# level: one commit on the base with this tree → NOTHING is written
# The empty-commit-per-night failure: the old writer PUT identical bytes here.
fresh pin-1
printf 'tree-new base-1\n' > "$STUB_HOME/pin-meta"
out="$(land)"; rc=$?
check "a branch already holding the rewrite is level: exit 0" \
  [ "$rc" -eq 0 -a "$out" = "level pin-1" ]
check "…and receives NO commit and NO ref update" \
  [ "$(calls '^POST .*git/commits$')" -eq 0 -a "$(calls '^PATCH')" -eq 0 -a "$(calls '^POST .*git/refs ')" -eq 0 ]

# behind: same tree, but not on the base → rebuilt ON the base
# The BEHIND failure: fleet-sync moved main under the branch, and the stacked
# nightly commits sit on the old tip. All the bot's own, so the force is safe.
fresh pin-9
printf 'tree-new base-0\n' > "$STUB_HOME/pin-meta"
printf 'glyph-pin-rewrite[bot]\n%.0s' 1 2 3 > "$STUB_HOME/authors"
out="$(land)"; rc=$?
check "a branch behind its base is rebuilt: exit 0, landed" \
  [ "$rc" -eq 0 -a "$out" = "landed 2 commit-1" ]
check "the new commit parents on the base, not on the stale head" \
  jqe '.parents == ["base-1"]' "$STUB_HOME/commit-payload.json"
check "the ref is force-moved exactly once, not re-created" \
  [ "$(calls '^PATCH .*git/refs/heads/glyph-pin/v9.9.9 sha=commit-1 force=true$')" -eq 1 -a "$(calls '^POST .*git/refs ')" -eq 0 ]

# on the base but with other bytes (a partial earlier write) → rebuilt
fresh pin-2
printf 'tree-old base-1\n' > "$STUB_HOME/pin-meta"
printf 'glyph-pin-rewrite[bot]\n' > "$STUB_HOME/authors"
out="$(land)"; rc=$?
check "a branch on the base with other bytes is rebuilt" \
  [ "$rc" -eq 0 -a "$out" = "landed 2 commit-1" -a "$(calls '^PATCH')" -eq 1 ]

# a person's commit on the branch → untouched, exit 3
fresh pin-3
printf 'tree-new base-0\n' > "$STUB_HOME/pin-meta"
printf 'glyph-pin-rewrite[bot]\nSome Person\n' > "$STUB_HOME/authors"
out="$(land)"; rc=$?
check "a commit this workflow did not author exits 3" [ "$rc" -eq 3 ]
check "…names the stranger, and moves nothing" \
  sh -c "grep -q 'not authored by glyph-pin-rewrite\[bot\] (c-Some-)' '$stub_dir/err' \
         && [ \"\$(grep -c '^PATCH' '$STUB_HOME/calls.log')\" -eq 0 ] \
         && [ \"\$(grep -c '^POST .*git/commits\$' '$STUB_HOME/calls.log')\" -eq 0 ]"

# the ref cannot be read, and it is not a 404 → exit 1, nothing created
fresh
touch "$STUB_HOME/ref-500"
out="$(land)"; rc=$?
check "an unreadable ref that is not a 404 exits 1" [ "$rc" -eq 1 ]
check "…and neither creates nor moves nor commits" \
  [ "$(calls '^POST .*git/refs ')" -eq 0 -a "$(calls '^PATCH')" -eq 0 -a "$(calls '^POST .*git/commits$')" -eq 0 ]

# a failed blob → exit 1 before anything moves
fresh pin-1
printf 'tree-new base-1\n' > "$STUB_HOME/pin-meta"
touch "$STUB_HOME/fail-blobs"
out="$(land)"; rc=$?
check "a failed blob exits 1 with no commit and no ref update" \
  [ "$rc" -eq 1 -a "$(calls '^POST .*git/commits$')" -eq 0 -a "$(calls '^PATCH')" -eq 0 ]

echo
if [ "$fails" -gt 0 ]; then
  echo "$fails glyph-pin-land case(s) failed"
  exit 1
fi
echo "all glyph-pin-land cases passed"
