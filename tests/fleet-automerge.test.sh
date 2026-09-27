#!/usr/bin/env bash
# Table-test scripts/fleet-automerge.sh — the orchestrator that arms auto-merge
# on the fleet's bot pull requests. Runs the REAL script (drift-free) against a
# stubbed `gh` on PATH, the glyph-pin-land.test.sh pattern. Needs bash + jq.
#
# What a live run cannot show and these cases pin: a dry run reads everything
# and arms NOTHING; a repo with allow_auto_merge=false is skipped and counted,
# never merged blind; every person-owned shape (major, draft, `hold`, conflict,
# foreign author, unclassifiable) is one held / major-left line and no arm; an
# arm that gh reports as success is READ BACK, and an arm the API refuses is
# either the counted "unprotected" skip or a failure that reds the run.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
script="$root/scripts/fleet-automerge.sh"
fails=0

[ -f "$script" ] || { echo "FAIL - $script is missing"; exit 1; }

stub_dir="$(mktemp -d)"
trap 'rm -rf "$stub_dir"' EXIT

# A `gh` that answers from files under $STUB_HOME and appends every call to
# $STUB_HOME/calls.log:
#   repos                 one repo name per line (gh repo list)
#   repo-<r>.json         {"allow_auto_merge":…, "default_branch":…}; absent = 500
#   prs-<r>.json          the open pull list (gh pr list); absent = []
#   prs-<r>.fail          present = listing fails
#   commits-<r>-<n>.txt   commit message(s) for pulls/<n>/commits; absent = 500
#   merge-<r>-<n>         arm outcome: armed (default) | merged | unprotected |
#                         noauto | boom | ghost (arm "succeeds", read-back shows nothing)
cat >"$stub_dir/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
cmd="${1:-}"; shift
sub=""; case "$cmd" in pr|repo) sub="${1:-}"; shift ;; esac
verb=GET; path=""; jqexpr=""; repo=""; num=""; fields=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -X) verb="$2"; shift 2 ;;
    --jq|-q) jqexpr="$2"; shift 2 ;;
    --repo) repo="$2"; shift 2 ;;
    --json|--limit|--state|-f|-F) fields="$fields $1=$2"; shift 2 ;;
    --auto|--squash|--no-archived|--source) fields="$fields $1"; shift ;;
    -*) shift ;;
    *) if [ -z "$path" ]; then path="$1"; else num="$1"; fi; shift ;;
  esac
done
[ "$cmd" = "pr" ] && { num="$path"; path=""; }
printf '%s %s %s %s %s%s\n' "$cmd" "$sub" "$verb" "${repo:-$path}" "$num" "$fields" >> "$STUB_HOME/calls.log"
emit() { if [ -n "$jqexpr" ]; then printf '%s' "$1" | jq -r "$jqexpr"; else printf '%s\n' "$1"; fi; }
r="${repo##*/}"
case "$cmd $sub $verb" in
  "repo list GET")
    emit "$(jq -R '{name: .}' "$STUB_HOME/repos" | jq -s .)" ;;
  "api  GET")
    case "$path" in
      repos/*/pulls/*/commits)
        p="${path#repos/*/}"; rr="${p%%/*}"; n="${path##*/pulls/}"; n="${n%%/*}"
        f="$STUB_HOME/commits-$rr-$n.txt"
        [ -e "$f" ] || { echo "gh: HTTP 500" >&2; exit 1; }
        emit "$(jq -Rs '[{commit:{message: .}}]' "$f")" ;;
      repos/*)
        rr="${path#repos/*/}"
        f="$STUB_HOME/repo-$rr.json"
        [ -e "$f" ] || { echo "gh: HTTP 500" >&2; exit 1; }
        emit "$(cat "$f")" ;;
      *) echo "stub gh: unhandled api $path" >&2; exit 64 ;;
    esac ;;
  "pr list GET")
    [ -e "$STUB_HOME/prs-$r.fail" ] && { echo "gh: HTTP 502" >&2; exit 1; }
    f="$STUB_HOME/prs-$r.json"; [ -e "$f" ] || f=/dev/null
    emit "$( [ -s "$f" ] && cat "$f" || echo '[]')" ;;
  "pr merge GET")
    mode="$(cat "$STUB_HOME/merge-$r-$num" 2>/dev/null || echo armed)"
    case "$mode" in
      unprotected) echo "GraphQL: Pull request Protected branch rules not configured for this branch (enablePullRequestAutoMerge)" >&2; exit 1 ;;
      noauto)      echo "GraphQL: Auto merge is not allowed for this repository (enablePullRequestAutoMerge)" >&2; exit 1 ;;
      boom)        echo "GraphQL: Something went wrong (enablePullRequestAutoMerge)" >&2; exit 1 ;;
      *) echo "✓ Pull request $repo#$num will be automatically merged via squash when all requirements are met"; exit 0 ;;
    esac ;;
  "pr view GET")
    mode="$(cat "$STUB_HOME/merge-$r-$num" 2>/dev/null || echo armed)"
    case "$mode" in
      merged) emit '{"state":"MERGED","autoMergeRequest":null}' ;;
      ghost)  emit '{"state":"OPEN","autoMergeRequest":null}' ;;
      *)      emit '{"state":"OPEN","autoMergeRequest":{"enabledBy":{"login":"o"}}}' ;;
    esac ;;
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
repo() { # repo <name> <allow_auto_merge> — register a repo with default branch main
  printf '%s\n' "$1" >> "$STUB_HOME/repos"
  printf '{"allow_auto_merge":%s,"default_branch":"main"}\n' "$2" > "$STUB_HOME/repo-$1.json"
}
# pr <repo> <number> <head> <author> <title> [draft] [mergeState] [armed] [labels-json] [base]
pr() {
  local r="$1" n="$2" head="$3" author="$4" title="$5" draft="${6:-false}" ms="${7:-BLOCKED}" armed="${8:-false}" labels="${9:-[]}" base="${10:-main}"
  local f="$STUB_HOME/prs-$r.json"; [ -s "$f" ] || echo '[]' > "$f"
  local auto=null; [ "$armed" = "true" ] && auto='{"enabledBy":{"login":"o"}}'
  jq --argjson n "$n" --arg head "$head" --arg author "$author" --arg title "$title" --argjson draft "$draft" \
     --arg ms "$ms" --argjson auto "$auto" --argjson labels "$labels" --arg base "$base" \
     '. + [{number:$n, title:$title, headRefName:$head, baseRefName:$base, author:{login:$author}, isDraft:$draft,
            mergeStateStatus:$ms, autoMergeRequest:$auto, labels:($labels | map({name: .}))}]' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}
trailer() { # trailer <repo> <n> <entries: name[:type]...>
  local r="$1" n="$2"; shift 2
  { printf 'bump\n\n---\nupdated-dependencies:\n'
    local e name type
    for e in "$@"; do
      name="${e%%:*}"; type=""; [ "$e" != "$name" ] && type="${e#*:}"
      printf -- '- dependency-name: %s\n' "$name"
      [ -z "$type" ] || printf '  update-type: version-update:semver-%s\n' "$type"
    done
    printf '...\n'; } > "$STUB_HOME/commits-$r-$n.txt"
}

run_script() { PATH="$stub_dir:$PATH" bash "$script" "$@" >"$stub_dir/out" 2>"$stub_dir/err"; }
out() { grep -c -- "$1" "$stub_dir/out"; }
merges() { grep -c '^pr merge' "$STUB_HOME/calls.log"; }
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

# ── the dry run: every shape, no writes ─────────────────────────────────────
fresh
repo alpha true
pr alpha 1 dependabot/go_modules/gomod-1 app/dependabot ':arrow_up:(deps) bump go-gh in the gomod group'
trailer alpha 1 go-gh:patch
pr alpha 2 glyph-pin/v4.0.0 o ':arrow_up:(ci)= pin glyph v4.0.0 (v3.3.1 -> v4.0.0)'
pr alpha 3 fleet-sync/commit-lint o ':wrench:(fleet)= sync .github/workflows/commit-lint.yml' false CLEAN
pr alpha 4 dependabot/github_actions/actions-4 app/dependabot 'Bump nix-installer-action'
trailer alpha 4 DeterminateSystems/nix-installer-action
pr alpha 5 feature/human akira 'a person'"'"'s pull request' false CLEAN
pr alpha 6 dependabot/npm_and_yarn/npm-6 app/dependabot 'bump (draft)' true
trailer alpha 6 x:patch
pr alpha 7 dependabot/npm_and_yarn/npm-7 app/dependabot 'bump (hold)' false BLOCKED false '["dependencies","hold"]'
trailer alpha 7 x:patch
pr alpha 8 glyph-pin/v3.3.1 o 'pin (v3.3.0 -> v3.3.1) already armed' false BLOCKED true
pr alpha 9 dependabot/npm_and_yarn/npm-9 app/dependabot 'bump (conflict)' false DIRTY
trailer alpha 9 x:minor
pr alpha 10 glyph-pin/v3.3.1 someone-else 'pin (v3.3.0 -> v3.3.1) by a stranger'
pr alpha 11 dependabot/npm_and_yarn/npm-11 akira 'bump by a stranger'
trailer alpha 11 x:patch
pr alpha 12 glyph-pin/v3.3.1 o 'pin (v3.3.0 -> v3.3.1) to another base' false BLOCKED false '[]' release
repo beta false
pr beta 1 dependabot/go_modules/gomod-1 app/dependabot 'bump' false CLEAN
trailer beta 1 y:patch
repo gamma true
pr gamma 1 feature/only akira 'nothing for the machine here'
run_script o; rc=$?
check "dry run exits 0" [ "$rc" -eq 0 ]
check "dry run arms nothing" [ "$(merges)" -eq 0 ]
check "patch dependabot would arm" line "would-arm: o/alpha#1 dependabot 1 update(s), highest semver-patch — :arrow_up:(deps) bump go-gh"
check "major glyph-pin is left to a person" line "major-left: o/alpha#2 glyph-pin v3.3.1 -> v4.0.0 — "
check "fleet-sync would arm even when CLEAN" line "would-arm: o/alpha#3 fleet-sync fleet-sync canonical — "
check "SHA bump is held" line "held: o/alpha#4 dependabot DeterminateSystems/nix-installer-action has no semver update-type"
check "a person's branch family is not even mentioned" [ "$(out 'alpha#5')" -eq 0 ]
check "draft is held" line "held: o/alpha#6 dependabot draft — "
check "label hold is held" line "held: o/alpha#7 dependabot label hold — "
check "already armed is reported, not re-armed" line "already-armed: o/alpha#8 glyph-pin — "
check "conflict is held" line "held: o/alpha#9 dependabot merge conflict — "
check "glyph-pin by a stranger is held" line "held: o/alpha#10 glyph-pin author someone-else is not the hub's PAT user o — "
check "dependabot/ by a non-bot is held" line "held: o/alpha#11 dependabot author akira is not dependabot — "
check "a pull not aimed at the default branch is held" line "held: o/alpha#12 glyph-pin base release is not the default branch main — "
check "allow_auto_merge=false skips the repo and counts its candidates" line "skipped(no-auto-merge): o/beta allow_auto_merge=false (1 candidate pull request(s) left to a person)"
check "the no-auto-merge repo's commits are never read" [ "$(grep -c 'pulls/1/commits' "$STUB_HOME/calls.log")" -eq 1 ]
check "counts line" line "done: armed=0 merged-now=0 would-arm=2 major-left=1 held=7 already-armed=1 skipped-no-auto-merge=1 skipped-unprotected=0 failed=0 dry-run=true across 3 repo(s)"

# ── apply: arm, read back, classify refusals ────────────────────────────────
fresh
repo alpha true
pr alpha 1 dependabot/go_modules/gomod-1 app/dependabot 'bump (armed)'
trailer alpha 1 go-gh:patch
pr alpha 2 glyph-pin/v3.4.0 o 'pin (v3.3.1 -> v3.4.0) already mergeable' false CLEAN
printf merged > "$STUB_HOME/merge-alpha-2"
pr alpha 3 fleet-sync/x o 'sync on an unprotected branch'
printf unprotected > "$STUB_HOME/merge-alpha-3"
pr alpha 4 fleet-sync/y o 'sync where auto-merge was just switched off'
printf noauto > "$STUB_HOME/merge-alpha-4"
APPLY=1 run_script o; rc=$?
check "apply with only counted refusals exits 0" [ "$rc" -eq 0 ]
check "arms with --auto --squash and the repo" [ "$(grep -c '^pr merge GET o/alpha 1 --auto --squash' "$STUB_HOME/calls.log")" -eq 1 ]
check "an armed pull is read back" [ "$(grep -c '^pr view GET o/alpha 1' "$STUB_HOME/calls.log")" -eq 1 ]
check "armed line" line "armed: o/alpha#1 dependabot 1 update(s), highest semver-patch — bump (armed)"
check "an already-mergeable pull gh merged outright is merged-now" line "merged-now: o/alpha#2 glyph-pin v3.3.1 -> v3.4.0 (minor) — "
check "no protection is the counted unprotected skip" line "skipped(unprotected): o/alpha#3 fleet-sync the base branch has no protection"
check "auto-merge disallowed at arm time is the counted no-auto-merge skip" line "skipped(no-auto-merge): o/alpha#4 fleet-sync auto-merge is not allowed on this repository"
check "apply counts" line "done: armed=1 merged-now=1 would-arm=0 major-left=0 held=0 already-armed=0 skipped-no-auto-merge=1 skipped-unprotected=1 failed=0 dry-run=false across 1 repo(s)"

# an arm the API refuses for any other reason is a failure, and reds the run
fresh
repo alpha true
pr alpha 1 fleet-sync/x o 'sync'
printf boom > "$STUB_HOME/merge-alpha-1"
APPLY=1 run_script o; rc=$?
check "an unclassified arm refusal is exit 1" [ "$rc" -eq 1 ]
check "…and says so with the API's words" line "::error::fleet-automerge: failed: o/alpha#1 fleet-sync arm refused: GraphQL: Something went wrong"

# "gh exited 0" is a claim: a read-back showing neither auto-merge nor MERGED fails
fresh
repo alpha true
pr alpha 1 fleet-sync/x o 'sync'
printf ghost > "$STUB_HOME/merge-alpha-1"
APPLY=1 run_script o; rc=$?
check "a ghost arm is exit 1" [ "$rc" -eq 1 ]
check "…named as a read-back failure" line "failed: o/alpha#1 fleet-sync arm answered success but the pull request shows neither auto-merge nor MERGED"

# reads that fail are failures, never silent skips
fresh
printf 'alpha\nbeta\n' > "$STUB_HOME/repos"
repo beta true
pr beta 1 dependabot/go_modules/gomod-1 app/dependabot 'bump with unreadable commits'
APPLY=1 run_script o; rc=$?
check "unreadable settings and commits are exit 1" [ "$rc" -eq 1 ]
check "unreadable repo settings is failed" line "failed: o/alpha cannot read the repository settings"
check "unreadable commits is failed, not held" line "failed: o/beta#1 dependabot cannot read its commits"
check "nothing was armed on the way" [ "$(merges)" -eq 0 ]
fresh
repo alpha true
: > "$STUB_HOME/prs-alpha.fail"
run_script o; rc=$?
check "an unlistable pull list is exit 1" [ "$rc" -eq 1 ]
check "…as failed" line "failed: o/alpha cannot list its open pull requests"

# only-repo: the fleet is never listed, and only that repo is read
fresh
repo alpha true
repo beta true
pr beta 1 fleet-sync/x o 'sync'
run_script o beta; rc=$?
check "only-repo exits 0" [ "$rc" -eq 0 ]
check "only-repo never lists the fleet" [ "$(grep -c '^repo list' "$STUB_HOME/calls.log")" -eq 0 ]
check "only-repo reads that repo alone" [ "$(grep -c 'GET repos/o/alpha' "$STUB_HOME/calls.log")" -eq 0 ]
check "only-repo counts one repo" line "across 1 repo(s)"

# the step summary is the counts as a table
fresh
repo alpha true
pr alpha 1 fleet-sync/x o 'sync'
export GITHUB_STEP_SUMMARY="$stub_dir/summary.md"; : > "$GITHUB_STEP_SUMMARY"
run_script o; rc=$?
check "summary written" grep -q '^| 0 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 |$' "$GITHUB_STEP_SUMMARY"
unset GITHUB_STEP_SUMMARY

[ "$fails" -eq 0 ] || { echo "$fails fleet-automerge case(s) failed"; exit 1; }
echo "all fleet-automerge cases passed"
