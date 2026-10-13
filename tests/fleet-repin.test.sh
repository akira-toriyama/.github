#!/usr/bin/env bash
# Table-test scripts/fleet-repin.sh — the orchestrator that lands a vendorHash
# re-pin on the fleet's dependabot gomod branches. Runs the REAL script
# (drift-free) against a stubbed `gh` on PATH, the fleet-automerge.test.sh
# pattern; the per-repo ritual it clones and runs is a stub too, because the
# ritual has its own table (tests/repin-vendorhash.test.sh). Needs bash + jq.
#
# What a live run cannot show and these cases pin: a dry run reads everything
# and writes NOTHING; only a dependabot/go_modules/ pull whose diff moves go.sum
# and not flake.nix is a candidate, every other shape is one held / skipped /
# already-repinned line and no clone; a head without a flake, a vendorHash or
# the synced script is a counted skip, never a guess; a write gh reports as
# success is READ BACK, and a ritual or write that fails reds the run.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
script="$root/scripts/fleet-repin.sh"
fails=0

[ -f "$script" ] || { echo "FAIL - $script is missing"; exit 1; }

stub_dir="$(mktemp -d)"
trap 'rm -rf "$stub_dir"' EXIT

# A `gh` that answers from files under $STUB_HOME and appends every call to
# $STUB_HOME/calls.log:
#   repos                 one repo name per line (gh repo list)
#   repo-<r>.json         {"default_branch":…}; absent = 500
#   prs-<r>.json          the open pull list (gh pr list); absent = []
#   files-<r>-<n>.txt     the pull's changed filenames; absent = 500
#   head-<r>-<ref>/       the files at that head (flake.nix, scripts/…); a
#                         missing file is 404, a missing dir is 500
#   clone-<r>-<ref>.fail  present = the clone fails
#   put-<r>               write outcome: ok (default; appends flake.nix to the
#                         pull's files) | refuse | ghost (ok, files unchanged)
cat >"$stub_dir/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
cmd="${1:-}"; shift
sub=""; case "$cmd" in pr|repo) sub="${1:-}"; shift ;; esac
verb=GET; path=""; jqexpr=""; repo=""; num=""; fields=""; dest=""; ref=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -X) verb="$2"; shift 2 ;;
    --jq|-q) jqexpr="$2"; shift 2 ;;
    --repo) repo="$2"; shift 2 ;;
    --branch) ref="$2"; shift 2 ;;
    -f|-F) fields="$fields $2"; shift 2 ;;
    --json|--limit|--state) shift 2 ;;
    --) shift ;;
    -*) shift ;;
    *) if [ -z "$path" ]; then path="$1"; elif [ -z "$dest" ]; then dest="$1"; fi; shift ;;
  esac
done
printf '%s %s %s %s %s %s\n' "$cmd" "$sub" "$verb" "${repo:-$path}" "$ref" "$fields" | tr '\n' ' ' >> "$STUB_HOME/calls.log"; echo >> "$STUB_HOME/calls.log"
emit() { if [ -n "$jqexpr" ]; then printf '%s' "$1" | jq -r "$jqexpr"; else printf '%s\n' "$1"; fi; }
r="${repo##*/}"
case "$cmd $sub $verb" in
  "repo list GET")
    emit "$(jq -R '{name: .}' "$STUB_HOME/repos" | jq -s .)" ;;
  "repo clone GET")
    rr="${path##*/}"
    [ -e "$STUB_HOME/clone-$rr-$ref.fail" ] && { echo "fatal: Remote branch $ref not found" >&2; exit 1; }
    [ -d "$STUB_HOME/head-$rr-$ref" ] || { echo "fatal: no such head" >&2; exit 1; }
    mkdir -p "$dest" && cp -R "$STUB_HOME/head-$rr-$ref/." "$dest/" ;;
  "pr list GET")
    f="$STUB_HOME/prs-$r.json"; [ -e "$f" ] || f=/dev/null
    emit "$( [ -s "$f" ] && cat "$f" || echo '[]')" ;;
  "api  GET")
    case "$path" in
      repos/*/pulls/*/files)
        p="${path#repos/*/}"; rr="${p%%/*}"; n="${path##*/pulls/}"; n="${n%%/*}"
        f="$STUB_HOME/files-$rr-$n.txt"
        [ -e "$f" ] || { echo "gh: HTTP 500" >&2; exit 1; }
        emit "$(jq -R '{filename: .}' "$f" | jq -s .)" ;;
      repos/*/contents/*)
        p="${path#repos/*/}"; rr="${p%%/*}"; file="${path#*/contents/}"; qref="${file##*\?ref=}"; file="${file%%\?*}"
        d="$STUB_HOME/head-$rr-$qref"
        [ -d "$d" ] || { echo "gh: HTTP 500" >&2; exit 1; }
        [ -f "$d/$file" ] || { echo "gh: HTTP 404: Not Found" >&2; exit 1; }
        emit "$(jq -n --arg sha "blob-$rr-$qref" --arg c "$(base64 < "$d/$file" | tr -d '\n')" '{sha: $sha, content: $c}')" ;;
      repos/*)
        rr="${path#repos/*/}"
        f="$STUB_HOME/repo-$rr.json"
        [ -e "$f" ] || { echo "gh: HTTP 500" >&2; exit 1; }
        emit "$(cat "$f")" ;;
      *) echo "stub gh: unhandled api $path" >&2; exit 64 ;;
    esac ;;
  "api  PUT")
    p="${path#repos/*/}"; rr="${p%%/*}"
    mode="$(cat "$STUB_HOME/put-$rr" 2>/dev/null || echo ok)"
    case "$mode" in
      refuse) echo 'gh: HTTP 409: flake.nix does not match blob-x (https://docs.github.com/rest/repos/contents#create-or-update-file-contents)' >&2; exit 1 ;;
      ghost)  ;;
      *) printf '%s' "$fields" | tr ' ' '\n' | sed -n 's/^content=//p' | base64 -d > "$STUB_HOME/written-$rr.nix"
         n="$(ls "$STUB_HOME" | sed -n "s/^files-$rr-\([0-9]*\)\.txt$/\1/p" | head -1)"; echo flake.nix >> "$STUB_HOME/files-$rr-$n.txt" ;;
    esac
    emit '{"commit":{"sha":"c0ffee"}}' ;;
  *) echo "stub gh: unhandled $cmd $sub $verb $path" >&2; exit 64 ;;
esac
STUB
chmod +x "$stub_dir/gh"

fresh() {
  export STUB_HOME="$stub_dir/home"
  rm -rf "$STUB_HOME"; mkdir -p "$STUB_HOME"
  : > "$STUB_HOME/calls.log"; : > "$STUB_HOME/repos"
  unset GITHUB_STEP_SUMMARY
}
repo() { # repo <name> — register a repo with default branch main
  printf '%s\n' "$1" >> "$STUB_HOME/repos"
  printf '{"default_branch":"main"}\n' > "$STUB_HOME/repo-$1.json"
}
# pr <repo> <number> <head> <author> <title> [draft] [mergeState] [labels-json] [base]
pr() {
  local r="$1" n="$2" head="$3" author="$4" title="$5" draft="${6:-false}" ms="${7:-BLOCKED}" labels="${8:-[]}" base="${9:-main}"
  local f="$STUB_HOME/prs-$r.json"; [ -s "$f" ] || echo '[]' > "$f"
  jq --argjson n "$n" --arg head "$head" --arg author "$author" --arg title "$title" --argjson draft "$draft" \
     --arg ms "$ms" --argjson labels "$labels" --arg base "$base" \
     '. + [{number:$n, title:$title, headRefName:$head, baseRefName:$base, author:{login:$author}, isDraft:$draft,
            mergeStateStatus:$ms, labels:($labels | map({name: .}))}]' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}
files() { local r="$1" n="$2"; shift 2; printf '%s\n' "$@" > "$STUB_HOME/files-$r-$n.txt"; }
# head <repo> <ref> [flake|noflake|novendor] [script|noscript] [ritual: repin|same|fail]
head_() {
  local r="$1" ref="$2" flake="${3:-flake}" script="${4:-script}" ritual="${5:-repin}"
  local d="$STUB_HOME/head-$r-$ref"; mkdir -p "$d/scripts"
  printf 'x v1 h1:a=\n' > "$d/go.sum"
  case "$flake" in
    flake)    printf '{\n  vendorHash = "sha256-OLD=";\n}\n' > "$d/flake.nix" ;;
    novendor) printf '{\n  # nothing pinned here\n}\n' > "$d/flake.nix" ;;
    noflake)  ;;
  esac
  if [ "$script" = script ]; then
    case "$ritual" in
      repin) printf '#!/bin/sh\nsed -i.bak "s/sha256-OLD=/sha256-NEW=/" flake.nix && rm -f flake.nix.bak\necho "re-pinned — vendorHash sha256-OLD= -> sha256-NEW=; no stamp line to refresh"\n' ;;
      same)  printf '#!/bin/sh\necho "ok — flake.nix vendorHash stamp already matches go.sum (sha256-OLD=)"\n' ;;
      fail)  printf '#!/bin/sh\necho "error: builder failed" >&2\necho "✖ nix build printed no got: — flake.nix left untouched" >&2\nexit 1\n' ;;
    esac > "$d/scripts/repin-vendorhash.sh"
    chmod +x "$d/scripts/repin-vendorhash.sh"
  fi
}

run_script() { PATH="$stub_dir:$PATH" bash "$script" "$@" >"$stub_dir/out" 2>"$stub_dir/err"; }
out() { grep -c -- "$1" "$stub_dir/out"; }
puts() { grep -c '^api  PUT' "$STUB_HOME/calls.log"; }
clones() { grep -c '^repo clone' "$STUB_HOME/calls.log"; }
line() { grep -F -- "$1" "$stub_dir/out" >/dev/null; }

check() { # check <name> <condition...>
  local name="$1"; shift
  if "$@"; then echo "ok   - $name"; else
    echo "FAIL - $name"
    sed 's/^/         stdout: /' "$stub_dir/out"
    sed 's/^/         stderr: /' "$stub_dir/err"
    sed 's/^/         calls:  /' "$STUB_HOME/calls.log" 2>/dev/null
    fails=$((fails + 1))
  fi
}

# usage
fresh
run_script; rc=$?
check "no owner is usage (exit 2)" [ "$rc" -eq 2 ]

# an unreadable or empty repo list is a red run, never an empty fleet
fresh
run_script o; rc=$?
check "an empty repo list is exit 1" [ "$rc" -eq 1 ]

# ── the dry run: every shape, no writes, no clones ─────────────────────────
fresh
repo alpha
pr alpha 1 dependabot/go_modules/gomod-1 app/dependabot ':arrow_up:(deps) Bump golang.org/x/term in the gomod group'
files alpha 1 go.mod go.sum
head_ alpha dependabot/go_modules/gomod-1
pr alpha 2 dependabot/go_modules/gomod-2 app/dependabot 'bump already re-pinned'
files alpha 2 go.mod go.sum flake.nix
pr alpha 3 dependabot/go_modules/gomod-3 app/dependabot 'bump of a go directive only'
files alpha 3 go.mod
pr alpha 4 dependabot/github_actions/actions-4 app/dependabot 'Bump actions/checkout'
pr alpha 5 feature/human akira 'a person'"'"'s pull request'
pr alpha 6 dependabot/go_modules/gomod-6 app/dependabot 'bump (draft)' true
pr alpha 7 dependabot/go_modules/gomod-7 app/dependabot 'bump (hold)' false BLOCKED '["dependencies","hold"]'
pr alpha 8 dependabot/go_modules/gomod-8 akira 'bump by a stranger'
pr alpha 9 dependabot/go_modules/gomod-9 app/dependabot 'bump to another base' false BLOCKED '[]' release
pr alpha 10 dependabot/go_modules/gomod-10 app/dependabot 'bump (conflict)' false DIRTY
pr alpha 11 dependabot/go_modules/gomod-11 app/dependabot 'bump where the head has no flake'
files alpha 11 go.mod go.sum
head_ alpha dependabot/go_modules/gomod-11 noflake
pr alpha 12 dependabot/go_modules/gomod-12 app/dependabot 'bump where the flake pins nothing'
files alpha 12 go.mod go.sum
head_ alpha dependabot/go_modules/gomod-12 novendor
pr alpha 13 dependabot/go_modules/gomod-13 app/dependabot 'bump before fleet-sync shipped the script'
files alpha 13 go.mod go.sum
head_ alpha dependabot/go_modules/gomod-13 flake noscript
repo beta
pr beta 1 feature/only akira 'nothing for the machine here'
run_script o; rc=$?
check "dry run exits 0" [ "$rc" -eq 0 ]
check "dry run writes nothing" [ "$(puts)" -eq 0 ]
check "dry run clones nothing" [ "$(clones)" -eq 0 ]
check "a go.sum-moving gomod bump would be re-pinned" line "would-repin: o/alpha#1 — :arrow_up:(deps) Bump golang.org/x/term"
check "a diff already carrying flake.nix is already-repinned" line "already-repinned: o/alpha#2 — bump already re-pinned"
check "a bump that leaves go.sum alone is skipped" line "skipped(no-go.sum): o/alpha#3 the bump leaves go.sum alone"
check "an actions bump is not even mentioned" [ "$(out 'alpha#4')" -eq 0 ]
check "a person's branch is not even mentioned" [ "$(out 'alpha#5')" -eq 0 ]
check "draft is held" line "held: o/alpha#6 draft — "
check "label hold is held" line "held: o/alpha#7 label hold — "
check "dependabot/ by a non-bot is held" line "held: o/alpha#8 author akira is not dependabot — "
check "another base is held" line "held: o/alpha#9 base release is not the default branch main — "
check "conflict is held" line "held: o/alpha#10 merge conflict"
check "no flake at the head is a counted skip" line "skipped(no-flake): o/alpha#11 no flake.nix at dependabot/go_modules/gomod-11"
check "a flake without vendorHash is a counted skip" line "skipped(no-vendorhash): o/alpha#12 flake.nix pins no vendorHash"
check "no synced script at the head is a counted skip" line "skipped(no-script): o/alpha#13 scripts/repin-vendorhash.sh is not on dependabot/go_modules/gomod-13 (fleet-sync has not shipped it)"
check "the held pulls' files are never read" [ "$(grep -c 'pulls/6/files\|pulls/7/files\|pulls/8/files\|pulls/9/files\|pulls/10/files' "$STUB_HOME/calls.log")" -eq 0 ]
check "counts line" line "done: repinned=0 would-repin=1 already-repinned=1 unchanged=0 held=5 skipped=4 failed=0 dry-run=true across 2 repo(s)"

# ── apply: clone, run the repo's ritual, write, read back ──────────────────
fresh
repo alpha
pr alpha 1 dependabot/go_modules/gomod-1 app/dependabot 'bump (re-pinned)'
files alpha 1 go.mod go.sum
head_ alpha dependabot/go_modules/gomod-1
APPLY=1 run_script o; rc=$?
check "apply exits 0" [ "$rc" -eq 0 ]
check "clones the pull's head branch" [ "$(grep -c '^repo clone GET o/alpha dependabot/go_modules/gomod-1' "$STUB_HOME/calls.log")" -eq 1 ]
check "writes flake.nix on that branch with the head's blob sha and the bot author" \
  [ "$(grep -c '^api  PUT repos/o/alpha/contents/flake.nix .*branch=dependabot/go_modules/gomod-1 sha=blob-alpha-dependabot/go_modules/gomod-1' "$STUB_HOME/calls.log")" -eq 1 ]
check "…as :package:(nix)= with the = sigil" [ "$(grep -c 'message=:package:(nix)= re-pin vendorHash for the gomod bump' "$STUB_HOME/calls.log")" -eq 1 ]
check "…authored fleet-repin\[bot\]" [ "$(grep -c 'author\[name\]=fleet-repin\[bot\]' "$STUB_HOME/calls.log")" -eq 1 ]
check "…with the ritual's output as the content" grep -q 'vendorHash = "sha256-NEW=";' "$STUB_HOME/written-alpha.nix"
check "the pull is read back" [ "$(grep -c '^api  GET repos/o/alpha/pulls/1/files' "$STUB_HOME/calls.log")" -eq 2 ]
check "repinned line carries the ritual's report" line "repinned: o/alpha#1 re-pinned — vendorHash sha256-OLD= -> sha256-NEW=; no stamp line to refresh — bump (re-pinned)"
check "apply counts" line "done: repinned=1 would-repin=0 already-repinned=0 unchanged=0 held=0 skipped=0 failed=0 dry-run=false across 1 repo(s)"

# a ritual that changes nothing writes nothing
fresh
repo alpha
pr alpha 1 dependabot/go_modules/gomod-1 app/dependabot 'bump (same hash)'
files alpha 1 go.mod go.sum
head_ alpha dependabot/go_modules/gomod-1 flake script same
APPLY=1 run_script o; rc=$?
check "an unchanged flake.nix is exit 0" [ "$rc" -eq 0 ]
check "…and writes nothing" [ "$(puts)" -eq 0 ]
check "…reported as unchanged" line "unchanged: o/alpha#1 the ritual left flake.nix as it was (ok — flake.nix vendorHash stamp already matches"

# the ritual failing is a failure with its last lines, and nothing is written
fresh
repo alpha
pr alpha 1 dependabot/go_modules/gomod-1 app/dependabot 'bump (ritual fails)'
files alpha 1 go.mod go.sum
head_ alpha dependabot/go_modules/gomod-1 flake script fail
APPLY=1 run_script o; rc=$?
check "a failed ritual is exit 1" [ "$rc" -eq 1 ]
check "…named with its words" line "::error::fleet-repin: failed: o/alpha#1 scripts/repin-vendorhash.sh failed: error: builder failed ✖ nix build printed no got:"
check "…and nothing is written" [ "$(puts)" -eq 0 ]

# a refused write (the branch moved) is a failure, never a clobber
fresh
repo alpha
pr alpha 1 dependabot/go_modules/gomod-1 app/dependabot 'bump (branch moved)'
files alpha 1 go.mod go.sum
head_ alpha dependabot/go_modules/gomod-1
printf refuse > "$STUB_HOME/put-alpha"
APPLY=1 run_script o; rc=$?
check "a refused write is exit 1" [ "$rc" -eq 1 ]
check "…with the API's words" line "failed: o/alpha#1 write refused: gh: HTTP 409: flake.nix does not match"

# "gh exited 0" is a claim: a read-back without flake.nix in the diff fails
fresh
repo alpha
pr alpha 1 dependabot/go_modules/gomod-1 app/dependabot 'bump (ghost write)'
files alpha 1 go.mod go.sum
head_ alpha dependabot/go_modules/gomod-1
printf ghost > "$STUB_HOME/put-alpha"
APPLY=1 run_script o; rc=$?
check "a ghost write is exit 1" [ "$rc" -eq 1 ]
check "…named as a read-back failure" line "failed: o/alpha#1 write answered success but the pull request's diff shows no flake.nix"

# a clone that fails is a failure
fresh
repo alpha
pr alpha 1 dependabot/go_modules/gomod-1 app/dependabot 'bump (clone fails)'
files alpha 1 go.mod go.sum
head_ alpha dependabot/go_modules/gomod-1
mkdir -p "$STUB_HOME/clone-alpha-dependabot/go_modules" && : > "$STUB_HOME/clone-alpha-dependabot/go_modules/gomod-1.fail"
APPLY=1 run_script o; rc=$?
check "a failed clone is exit 1" [ "$rc" -eq 1 ]
check "…named" line "failed: o/alpha#1 cannot clone dependabot/go_modules/gomod-1: fatal: Remote branch"
check "…and nothing is written" [ "$(puts)" -eq 0 ]

# reads that fail are failures, never silent skips
fresh
printf 'alpha\nbeta\n' > "$STUB_HOME/repos"
repo beta
pr beta 1 dependabot/go_modules/gomod-1 app/dependabot 'bump with unreadable files'
pr beta 2 dependabot/go_modules/gomod-2 app/dependabot 'bump with an unreadable head'
files beta 2 go.mod go.sum
pr alpha 1 dependabot/go_modules/gomod-1 app/dependabot 'bump on a repo whose settings cannot be read'
run_script o; rc=$?
check "unreadable settings, files and heads are exit 1" [ "$rc" -eq 1 ]
check "unreadable repo settings is failed" line "failed: o/alpha cannot read the repository settings"
check "unreadable files is failed, not skipped" line "failed: o/beta#1 cannot read its changed files"
check "an unreadable head is failed, not no-flake" line "failed: o/beta#2 cannot read flake.nix at dependabot/go_modules/gomod-2: gh: HTTP 500"
check "nothing was written on the way" [ "$(puts)" -eq 0 ]

# only-repo narrows the fleet to one repository without listing
fresh
repo alpha
pr alpha 1 dependabot/go_modules/gomod-1 app/dependabot 'bump'
files alpha 1 go.mod go.sum
head_ alpha dependabot/go_modules/gomod-1
run_script o alpha; rc=$?
check "only-repo exits 0" [ "$rc" -eq 0 ]
check "only-repo never lists the fleet" [ "$(grep -c '^repo list' "$STUB_HOME/calls.log")" -eq 0 ]
check "only-repo counts one repo" line "dry-run=true across 1 repo(s)"

# the step summary mirrors the counts
fresh
repo alpha
pr alpha 1 dependabot/go_modules/gomod-1 app/dependabot 'bump'
files alpha 1 go.mod go.sum
head_ alpha dependabot/go_modules/gomod-1
export GITHUB_STEP_SUMMARY="$stub_dir/summary.md"; : > "$GITHUB_STEP_SUMMARY"
run_script o; rc=$?
check "step summary is written" grep -q '| 0 | 1 | 0 | 0 | 0 | 0 | 0 |' "$GITHUB_STEP_SUMMARY"
unset GITHUB_STEP_SUMMARY

[ "$fails" -eq 0 ] || { echo "$fails fleet-repin case(s) failed"; exit 1; }
echo "all fleet-repin cases passed"
