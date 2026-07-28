#!/usr/bin/env bash
# swift-bite — run a pull request's NEW/CHANGED Swift tests against the source as
# it was BEFORE the pull request, and fail when every one of them still passes.
# The Swift half of go-bite: same claim, same exit contract, same opt-outs.
#
# Why: a diff can be reviewed; the claim "I verified this fix" cannot. A test
# added beside a fix is only evidence if it would have FAILED without the fix.
# Nothing re-checks that by hand — so a machine does. If the new tests all pass
# against the pre-change tree they pin nothing, and the pull request is asserting
# something it has not shown.
#
# Verdict (the exit codes are the contract, identical to go-bite):
#   0  at least one selected test BIT — failed, crashed, hung, or could not be
#      built without the change. Also 0 when there is nothing to check.
#   1  every selected test passed against the pre-change tree. The gate's failure.
#   2  the gate could not judge: usage or environment error, a pre-change tree
#      broken for reasons of its own, or an opt-out with no stated reason.
#
# Every selected test is judged BY NAME in `swift test`'s own output, never by
# the process exit code — measured on the real runner (macos-15, Xcode 26.3):
#   - `swift test --filter` that matches nothing prints ONE warning and exits 0,
#     so an unverified filter is a false green. Every selected test must appear.
#   - XCTest prints `Test Case '-[Module.Class testFoo]' passed/failed/skipped`.
#   - swift-testing prints `✔/✘/➜ Test name() passed/failed/skipped …` with the
#     name UNQUALIFIED, and its internal test ID carries a trailing
#     `/File.swift:line:col` segment, so an exact filter is `^Module\.name\(\)/`
#     (never `…$`) while an XCTest exact filter is `^Module\.Class/testFoo$`.
#   - `--filter` is an UNANCHORED regex: `stPasses` also selects `testPasses`.
#     Patterns below are anchored and metacharacter-escaped, always.
#   - `swift build` does NOT compile test targets, which makes it the
#     discriminator between "the tests don't build without the change" (a bite)
#     and "the pull request broke the old tree" (exit 2).
#
# Standing down (each is reported, never silent):
#   - The pull request changes nothing outside Tests/ — it claims nothing about
#     shipping behaviour.
#   - No test function was added, and none changed beyond comments/blank lines.
#   - Every selected test carries `bite-exempt: <reason>` in the comment block
#     directly above it (a characterisation test pinning CURRENT behaviour).
#   - EVERY commit in the range carries a `Bite-exempt: <reason>` git trailer
#     (a refactor that moves shipping source without changing behaviour).
#
# Env:
#   BASE_SHA   required — the commit the pull request would merge INTO
#   HEAD_SHA   required — the merge commit (github.sha), so the pre-change tree
#              is the base branch as it is now rather than the fork point
#   TEST_ARGS  optional — extra flags for the `swift test` run (default empty)
#   SWIFT_BITE_TIMEOUT  optional — seconds before the verdict run is killed and
#              read as a hang (default 600). The runner has no `timeout` binary,
#              so the watchdog is built in.
#
# Deliberately accepted limitations:
#   - Coverage is not judged; a fix with no test at all stands the gate down.
#   - Only `Tests/**`, `Package.swift` and `Package.resolved` are carried back.
#     A test needing a new Sources/ helper fails to build there — a bite, the
#     safe direction.
#   - XCTestCase subclassing is recognised one level deep (the fleet's only
#     shape); a method reaching XCTestCase through an intermediate base class in
#     an untouched file surfaces as `maybe` and is kept only if `swift test list`
#     knows it.
#   - swift-testing verdict lines are unqualified, so two SELECTED tests sharing
#     a bare name are judged collectively; the table says so.
#   - A test relocation combined with a shipping change goes red — a moved file
#     is wholly new, so every function in it is selected and none can bite.
#     Split the move, or waive it with the trailer.
#   - A deletion-only hunk is pinned to its anchor line, so deleting the last
#     declaration in a file can select the preceding, untouched function.
#   - Paths that git has to c-style-quote are refused rather than parsed.
set -uo pipefail

die() { printf '::error::swift-bite: %s\n' "$*" >&2; exit 2; }
note() { printf '::notice::swift-bite: %s\n' "$*"; }
warn() { printf '::warning::swift-bite: %s\n' "$*"; }

[ -n "${BASE_SHA:-}" ] || die "BASE_SHA is required"
[ -n "${HEAD_SHA:-}" ] || die "HEAD_SHA is required"
TEST_ARGS="${TEST_ARGS:-}"
SWIFT_BITE_TIMEOUT="${SWIFT_BITE_TIMEOUT:-600}"

here="$(cd "$(dirname "$0")" && pwd)"

command -v swift >/dev/null || die "swift is not on PATH"
command -v swiftc >/dev/null || die "swiftc is not on PATH"
repo="$(git rev-parse --show-toplevel)" || die "not inside a git repository"
cd "$repo" || die "cannot enter $repo"

for sha in "$BASE_SHA" "$HEAD_SHA"; do
  git cat-file -e "${sha}^{commit}" 2>/dev/null \
    || die "commit $sha is not in this checkout — the job needs actions/checkout with fetch-depth: 0"
done

# With HEAD_SHA the merge commit, this resolves to BASE_SHA itself: the
# pre-change tree is the base branch AS IT IS NOW. Judging against the fork
# point would credit a test pinning behaviour the base branch already ships.
before="$(git merge-base "$BASE_SHA" "$HEAD_SHA")" \
  || die "no merge base between $BASE_SHA and $HEAD_SHA"
short="$(git rev-parse --short "$before")"

git cat-file -e "$HEAD_SHA:Package.swift" 2>/dev/null \
  || die "no Package.swift at the repository root — swift-bite judges SwiftPM packages only"

work="$(mktemp -d)" || die "cannot create a work directory"
tree="$work/before"
# Invoked indirectly by the `trap cleanup EXIT` below. Both codes are needed:
# ubuntu-latest's linter reports SC2317 on the body, a newer one reports SC2329
# on the declaration.
# shellcheck disable=SC2329,SC2317
cleanup() {
  git worktree remove --force "$tree" >/dev/null 2>&1
  rm -rf "$work"
}
trap cleanup EXIT

summary() {
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
  printf '%s\n' "$*" >>"$GITHUB_STEP_SUMMARY"
}
summary "### swift-bite — do the new tests bite?"
summary ""

stand_down() {
  note "$1"
  summary "Stood down: $1"
  exit 0
}

# ---------------------------------------------------------------- change survey
# --no-renames turns a rename into delete+add, which is exactly what the overlay
# wants (drop the old path, treat the new one as wholly new).
git -c core.quotePath=false diff --name-status --no-renames "$before" "$HEAD_SHA" \
  >"$work/status.tsv" || die "cannot diff $before..$HEAD_SHA"

if cut -f2 "$work/status.tsv" | grep -q '^"'; then
  die "a changed path needs c-style quoting (a newline or quote in the filename); refusing to guess"
fi

: >"$work/overlay"   # paths to carry back from HEAD onto the old tree
: >"$work/remove"    # paths to delete from the old tree
: >"$work/added"     # added test source files — every test in them is new
: >"$work/modified"  # modified test source files — only touched functions are new
shipping=0           # did anything outside Tests/ change?

# The files the old tree gets from HEAD: the tests themselves, the fixtures they
# read (everything under Tests/ travels — SwiftPM test resources live there),
# and the manifest they resolve against.
carried() {
  case "$1" in
    Tests/* | Package.swift | Package.resolved) return 0 ;;
  esac
  return 1
}

# What the pull request claims to change. Tests assert about behaviour;
# everything else IS the behaviour (Package.swift included: a target reshape or
# dependency bump ships).
is_shipping() {
  case "$1" in
    Tests/*) return 1 ;;
  esac
  return 0
}

while IFS=$'\t' read -r status path; do
  [ -n "${path:-}" ] || continue
  is_shipping "$path" && shipping=1
  carried "$path" || continue
  case "$status" in
    D) printf '%s\n' "$path" >>"$work/remove" ;;
    A)
      printf '%s\n' "$path" >>"$work/overlay"
      case "$path" in Tests/*.swift) printf '%s\n' "$path" >>"$work/added" ;; esac
      ;;
    *) # M, T (typechange) — anything that still leaves a file at HEAD
      printf '%s\n' "$path" >>"$work/overlay"
      case "$path" in Tests/*.swift) printf '%s\n' "$path" >>"$work/modified" ;; esac
      ;;
  esac
done <"$work/status.tsv"

if [ "$shipping" -eq 0 ]; then
  stand_down "this pull request changes only tests and fixtures — it claims nothing about behaviour"
fi

# A pure refactor moves shipping source without changing behaviour, so no test
# can bite. Saying so in a git trailer is the honest way through: EVERY commit
# has to carry it, and it is parsed as a real trailer so a line in the middle of
# a paragraph cannot waive anything.
waiver=""
waived=0
commits="$(git rev-list --no-merges "$before..$HEAD_SHA")"
if [ -n "$commits" ]; then
  waived=1
  for commit in $commits; do
    line="$(git show -s --format=%B "$commit" | git interpret-trailers --parse | grep '^Bite-exempt:' | sed -n '1p')"
    if [ -z "$line" ]; then
      waived=0
      break
    fi
    waiver="$(printf '%s' "${line#Bite-exempt:}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -n "$waiver" ] || die "the \`Bite-exempt:\` trailer on $(git rev-parse --short "$commit") states no reason"
    case "$waiver" in
      '<'*'>') die "the \`Bite-exempt:\` trailer on $(git rev-parse --short "$commit") is still the placeholder — state the real reason" ;;
    esac
  done
fi
if [ "$waived" -eq 1 ]; then
  warn "waived by a Bite-exempt trailer on every commit — $waiver"
  summary "Waived by a \`Bite-exempt:\` trailer on every commit — $waiver"
  exit 0
fi

if [ ! -s "$work/added" ] && [ ! -s "$work/modified" ]; then
  stand_down "no Swift test file was added or changed"
fi

# --------------------------------------------------- test functions at HEAD
# bitescan parses with the toolchain's own parser (sourcekitdInProc): names,
# line spans, @Test attributes, XCTestCase inheritance and the bite-exempt
# comment block — the facts a regex over Swift source cannot get right.
(cd "$work" && swiftc -import-objc-header "$here/skdshim.h" "$here/bitescan.swift" -o bitescan) \
  || die "cannot build bitescan"

: >"$work/funcs.tsv"
mkdir -p "$work/head"

# extract <listfile> — copy the HEAD versions out of git rather than off the
# checkout, so line numbers line up with the diff hunks no matter which commit
# is checked out, and run bitescan over them ALL AT ONCE (one batch, so an
# `extension FooTests` resolves against `class FooTests: XCTestCase` in a
# sibling file).
extract() {
  [ -s "$1" ] || return 0
  while IFS= read -r path; do
    mkdir -p "$work/head/$(dirname "$path")"
    git show "$HEAD_SHA:$path" >"$work/head/$path" || die "cannot read $path at $HEAD_SHA"
  done <"$1"
  # NUL-delimited so a path with a space survives xargs' own word splitting.
  if ! (cd "$work/head" && tr '\n' '\0' <"$1" | xargs -0 "$work/bitescan") >>"$work/funcs.tsv"; then
    die "cannot read the test functions out of $HEAD_SHA"
  fi
}

# scan_target <Tests/Name> — read a target's WHOLE test suite out of HEAD.
# Needed when the trail leads outside the changed functions: an edit to a shared
# helper or fixture is something every test in the module can read.
: >"$work/scanned"
scan_target() {
  grep -qxF "$1" "$work/scanned" && return 0
  printf '%s\n' "$1" >>"$work/scanned"
  git ls-tree -r --name-only "$HEAD_SHA" "$1/" | grep '\.swift$' >"$work/targetfiles" || true
  # Rescan the whole batch together: funcs.tsv rows are keyed by (file, id), so
  # re-appending the changed files' rows is harmless duplication removed by the
  # sort below.
  extract "$work/targetfiles"
}

cat "$work/added" "$work/modified" >"$work/changed"
extract "$work/changed"

# ------------------------------------------------------------------ selection
# funcs.tsv: FILE KIND ID STARTLINE ENDLINE EXEMPT CONFIDENCE
: >"$work/selected.tsv"

# Every test function in an added file is new.
while IFS= read -r path; do
  awk -F'\t' -v f="$path" '$1 == f' "$work/funcs.tsv" >>"$work/selected.tsv"
done <"$work/added"

# In a modified file, select the functions whose span overlaps a substantively
# changed line range. `git diff -U0` hunk headers give the ranges in HEAD's
# numbering; a hunk whose new side is zero-length is a pure deletion, pinned to
# its anchor line. A hunk that only adds or removes blank lines and `//`
# comments is not substantive — a reworded comment must not put a test on trial.
: >"$work/expand"
while IFS= read -r path; do
  git diff -U0 "$before" "$HEAD_SHA" -- "$path" \
    | awk '
        function flush() {
          if (start != "" && substantive) {
            if (len == 0) print start "\t" start; else print start "\t" start + len - 1
          }
          start = ""; substantive = 0
        }
        /^@@/ {
          flush()
          split($3, a, ",")
          start = substr(a[1], 2) + 0
          len = (a[2] == "" ? 1 : a[2] + 0)
          next
        }
        /^[+-]/ {
          if (start == "") next            # +++/--- file headers precede the first hunk
          line = substr($0, 2)
          sub(/^[ \t]+/, "", line)
          if (line != "" && line !~ /^\/\//) substantive = 1
        }
        END { flush() }' >"$work/ranges"

  awk -F'\t' -v f="$path" '$1 == f { print $4 "\t" $5 }' "$work/funcs.tsv" >"$work/spans"
  awk -F'\t' -v f="$path" '
      NR == FNR { lo[FNR] = $1; hi[FNR] = $2; n = FNR; next }
      $1 == f {
        for (i = 1; i <= n; i++) if ($4 <= hi[i] && $5 >= lo[i]) { print; break }
      }' "$work/ranges" "$work/funcs.tsv" >>"$work/selected.tsv"

  # A changed line inside NO test function is a helper, an import, or a shared
  # fixture — things every test in the module reads (a Swift test target is one
  # module, so even another file's tests see it). Selecting nothing there is the
  # cheapest way to slip a vacuous pull request past the gate, so put the whole
  # target's suite on trial instead. Over-selection is harmless: the verdict is
  # "at least one bites", and the table still names the ones that did not.
  orphan=0
  if [ -s "$work/ranges" ]; then
    if [ ! -s "$work/spans" ]; then
      orphan=1
    else
      orphan="$(awk -F'\t' '
          FNR == NR { s[FNR] = $1; e[FNR] = $2; n = FNR; next }
          {
            hit = 0
            for (i = 1; i <= n; i++) if ($1 <= e[i] && $2 >= s[i]) hit = 1
            if (!hit) o = 1
          }
          END { print (o ? 1 : 0) }' "$work/spans" "$work/ranges")"
    fi
  fi
  if [ "$orphan" -eq 1 ]; then
    case "$path" in
      Tests/*/*) printf '%s\n' "$(printf '%s' "$path" | cut -d/ -f1-2)" >>"$work/expand" ;;
    esac
  fi
done <"$work/modified"

while IFS= read -r dir; do
  scan_target "$dir"
  awk -F'\t' -v d="$dir/" 'index($1, d) == 1' "$work/funcs.tsv" >>"$work/selected.tsv"
  note "a change outside every test function in $dir put its whole test suite on trial"
done < <(sort -u "$work/expand")

sort -u "$work/selected.tsv" -o "$work/selected.tsv"

awk -F'\t' '$6 != "-"' "$work/selected.tsv" >"$work/exempt.tsv"
awk -F'\t' '$6 == "-"' "$work/selected.tsv" >"$work/run.tsv"

while IFS=$'\t' read -r path _ id _ _ reason _; do
  note "$path:$id opted out — $reason"
  summary "- \`$id\` (\`$path\`) opted out — $reason"
done <"$work/exempt.tsv"

if [ ! -s "$work/run.tsv" ]; then
  if [ -s "$work/exempt.tsv" ]; then
    stand_down "every new or changed test opted out of the gate"
  fi
  stand_down "no test function was added, and none changed beyond comments or blank lines"
fi

# ------------------------------------------------------- the pre-change tree
git worktree add --detach --quiet "$tree" "$before" \
  || die "cannot materialise the pre-change tree at $before"

while IFS= read -r path; do
  git -C "$tree" checkout "$HEAD_SHA" -- "$path" \
    || die "cannot carry $path back onto the pre-change tree"
done <"$work/overlay"

while IFS= read -r path; do
  rm -f "$tree/$path"
done <"$work/remove"

# ------------------------------------------------------------------- verdict
record() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$work/rows.tsv"; }
: >"$work/rows.tsv"

finish() {
  summary "Ran the tests this pull request adds or changes against \`$short\`, the source before it."
  summary ""
  summary "| test | verdict |"
  summary "| --- | --- |"
  while IFS=$'\t' read -r _ id verdict; do
    printf 'swift-bite: %s — %s\n' "$id" "$verdict"
    summary "| \`$id\` | $verdict |"
    case "$verdict" in
      'passes'*) warn "$id passes against the pre-change tree — it pins nothing" ;;
    esac
  done <"$work/rows.tsv"

  if grep -q $'\tbites' "$work/rows.tsv"; then
    note "the new tests bite — they fail against the source before this pull request"
    exit 0
  fi

  # shellcheck disable=SC2016  # single-quoted on purpose: the backticks are
  # literal text in the message.
  printf '::error::swift-bite: every test this pull request adds or changes still passes against %s, the source before it. Those tests pin nothing, so the change they accompany is unproven. Make one of them fail without the change; or annotate a test that deliberately pins current behaviour with `bite-exempt: <reason>` in the comment above it; or, for a refactor that changes no behaviour at all, add a `Bite-exempt: <reason>` trailer to every commit.\n' \
    "$short" >&2
  exit 1
}

# The tests have to BUILD against the old source before they can be judged.
# `swift build` skips test targets (measured), so it is the discriminator: if
# the test build fails while the source build stands, the tests call an API this
# pull request introduces — evidence, exactly like a failing assertion.
printf '::group::swift build --build-tests against %s\n' "$short"
(cd "$tree" && swift build --build-tests) >"$work/build.log" 2>&1
buildrc=$?
cat "$work/build.log"
printf '::endgroup::\n'

if [ "$buildrc" -ne 0 ]; then
  if (cd "$tree" && swift build) >"$work/srcbuild.log" 2>&1; then
    while IFS=$'\t' read -r _ _ id _ _ _ _; do
      record "-" "$id" 'bites — does not build without the change'
    done <"$work/run.tsv"
    finish
  fi
  printf '::group::swift build against %s\n' "$short"
  cat "$work/srcbuild.log"
  printf '::endgroup::\n'
  die "the pre-change tree does not compile on its own, so its test failures say nothing about this pull request. If the change legitimately reshapes the package or its dependencies, waive it with a \`Bite-exempt: <reason>\` trailer on every commit."
fi

# `swift test list` binds each scanner id to the module-qualified id the runner
# actually uses (only Package.swift knows the target name), and is the reality
# check on the scanner itself: a `run` id the runner has never heard of is exit
# 2, never a silent drop.
(cd "$tree" && swift test list) >"$work/list.raw" 2>"$work/list.err"
listrc=$?
if [ "$listrc" -ne 0 ]; then
  cat "$work/list.err"
  die "swift test list failed on the pre-change tree — the gate cannot map tests to targets"
fi
# stdout carries build-progress noise on some toolchains; an id line is
# `Module.Something` with no spaces.
grep -E '^[A-Za-z_][A-Za-z0-9_]*\.' "$work/list.raw" | grep -v ' ' >"$work/list.ids" || true
[ -s "$work/list.ids" ] || die "swift test list reported no tests at all on the pre-change tree"

# Bind: list id `Mod.A/b()` → tail `A/b()` (first dot becomes a slash, module
# component dropped) must equal a scanner id. `maybe` rows (an extension of a
# class the batch could not vouch for) are dropped with a warning when the
# runner does not know them; `run` rows are exit 2.
awk -F'\t' 'NR==FNR {
      full = $0
      tail = $0
      sub(/\./, "/", tail)
      sub(/^[^\/]*\//, "", tail)
      ids[tail] = (tail in ids ? ids[tail] SUBSEP full : full)
      next
    }
    {
      if ($3 in ids) {
        n = split(ids[$3], hits, SUBSEP)
        for (i = 1; i <= n; i++) print $2 "\t" hits[i] "\t" $3 "\t" $8
      } else {
        print $2 "\tMISSING\t" $3 "\t" $7
      }
    }' "$work/list.ids" "$work/run.tsv" >"$work/bound.tsv"

: >"$work/judge.tsv"   # KIND \t FULLID \t SUFFIX \t DISPLAY
while IFS=$'\t' read -r kind full suffix extra; do
  if [ "$full" = "MISSING" ]; then
    if [ "$extra" = "maybe" ]; then
      warn "$suffix looks like a test but \`swift test list\` does not know it — not judged (a method in an extension of a class this diff does not show?)"
      continue
    fi
    die "$suffix was selected but \`swift test list\` on the pre-change tree does not know it — the gate cannot judge it (a #if condition excluding it here is the usual cause)"
  fi
  printf '%s\t%s\t%s\t%s\n' "$kind" "$full" "$suffix" "$extra" >>"$work/judge.tsv"
done <"$work/bound.tsv"

[ -s "$work/judge.tsv" ] || stand_down "no selected test survived binding — nothing to judge"

# One anchored, escaped branch per test. Measured shapes:
#   XCTest         ^Module\.Class/testFoo$
#   swift-testing  ^Module\.Suite/name\(\)/   (the ID goes on: /File.swift:4:2)
pattern="$(awk -F'\t' '{
    id = $2
    gsub(/[][\\.^$()|*+?{}]/, "\\\\&", id)
    if ($1 == "xctest") printf "%s%s$", (NR == 1 ? "" : "|"), id
    else printf "%s%s/", (NR == 1 ? "" : "|"), id
  }' "$work/judge.tsv")"
pattern="^($pattern)"

printf '::group::swift test --filter <%d selected> against %s\n' "$(wc -l <"$work/judge.tsv" | tr -d ' ')" "$short"
# The runner images ship no `timeout`; the watchdog below is the hang arm. A
# selected test that never finishes against the old source is a bite: the old
# code did not survive it. `set -m` gives the run its own process GROUP so the
# kill reaches the actual test runner, not just the subshell wrapping the `cd`
# (a plain `kill $!` leaves `swift test` alive and burning the runner).
set -m
# shellcheck disable=SC2086  # TEST_ARGS is a deliberate flag list
(cd "$tree" && exec swift test $TEST_ARGS --filter "$pattern") >"$work/out.txt" 2>&1 &
runpid=$!
(
  sleep "$SWIFT_BITE_TIMEOUT"
  kill -9 -- "-$runpid" 2>/dev/null
) &
wdpid=$!
set +m
wait "$runpid"
rc=$?
kill -9 -- "-$wdpid" 2>/dev/null
wait "$wdpid" 2>/dev/null
timedout=0
[ "$rc" -eq 137 ] && timedout=1
cat "$work/out.txt"
printf '::endgroup::\n'

# ----------------------------------------------------------- judge by name
# esc <s> — escape for a grep -E pattern.
# shellcheck disable=SC2016  # single-quoted on purpose: nothing should expand
esc() { printf '%s' "$1" | sed 's/[][\\.^$()|*+?{}]/\\&/g'; }

# A crash or a kill loses whatever the harness had buffered, so a per-test
# `started` line cannot be relied on. What survives in the FILE is what finished
# BEFORE the death; a selected test with no terminal line is `pending`, and the
# run-started markers below tell environment failure apart from a death inside
# the selected-only run.
run_started=0
grep -qE "^Test Suite 'Selected tests' started|^◇ Test run started\." "$work/out.txt" && run_started=1

bit=0
ran=0
: >"$work/pending.tsv"
while IFS=$'\t' read -r kind full suffix display; do
  if [ "$kind" = "xctest" ]; then
    # `Mod.Class/testFoo` prints as `-[Mod.Class testFoo]`.
    obj="-[$(printf '%s' "$full" | sed 's|/| |')]"
    e="$(esc "$obj")"
    if grep -qE "^Test Case '${e}' failed" "$work/out.txt"; then
      record "$kind" "$full" 'bites — fails without the change'; bit=1; ran=1
    elif grep -qE "^Test Case '${e}' passed" "$work/out.txt"; then
      record "$kind" "$full" 'passes without the change — pins nothing'; ran=1
    elif grep -qE "^Test Case '${e}' skipped" "$work/out.txt"; then
      record "$kind" "$full" 'skipped itself against the pre-change tree'
    else
      printf '%s\t%s\n' "$kind" "$full" >>"$work/pending.tsv"
    fi
  else
    # swift-testing prints the BARE name — or, for a `@Test("…")`, the DISPLAY
    # name in quotes (measured; the list and the filter still speak the function
    # id). Two selected tests sharing a printed name are judged collectively
    # (documented limitation). A parameterized test says "with N test cases"
    # between the name and the verdict.
    bare="${suffix##*/}"
    e="$(esc "$bare")"
    if [ "$display" != "-" ] && [ -n "$display" ]; then
      e="(${e}|\"$(esc "$display")\")"
    fi
    caseclause=' (with [0-9]+ test cases? )?'
    if grep -qE "^✘ Test ${e}${caseclause}failed after " "$work/out.txt"; then
      record "$kind" "$full" 'bites — fails without the change'; bit=1; ran=1
    elif grep -qE "^✔ Test ${e}${caseclause}passed after " "$work/out.txt"; then
      record "$kind" "$full" 'passes without the change — pins nothing'; ran=1
    elif grep -qE "^➜ Test ${e} skipped" "$work/out.txt"; then
      record "$kind" "$full" 'skipped itself against the pre-change tree'
    else
      printf '%s\t%s\n' "$kind" "$full" >>"$work/pending.tsv"
    fi
  fi
done <"$work/judge.tsv"

# Selected tests with no terminal line. The filter restricted execution to the
# selected tests alone, so once the run demonstrably started, a hang or a death
# happened inside that selection — evidence, judged collectively because the
# dead harness cannot say which one. A run that never started is an environment
# failure; a clean exit with a missing test is the filter missing, the exact
# false green this gate exists to stop. Neither is ever a verdict.
if [ -s "$work/pending.tsv" ]; then
  if [ "$timedout" -eq 1 ]; then
    # No run_started requirement here: SIGKILL loses the harness's buffered
    # output, sometimes ALL of it — but the watchdog firing at all IS the
    # evidence. The build was green and the filter confined the run to the
    # selected tests, so something in that selection failed to finish.
    while IFS=$'\t' read -r kind full; do
      record "$kind" "$full" "bites — hangs without the change (killed after ${SWIFT_BITE_TIMEOUT}s)"
    done <"$work/pending.tsv"
    bit=1; ran=1
  elif [ "$rc" -ne 0 ] && [ "$run_started" -eq 1 ]; then
    while IFS=$'\t' read -r kind full; do
      record "$kind" "$full" 'bites — the run died without the change (judged collectively)'
    done <"$work/pending.tsv"
    bit=1; ran=1
  elif [ "$run_started" -eq 0 ]; then
    die "the run against the pre-change tree never started (exit $rc) — an environment failure, not evidence"
  else
    id="$(head -1 "$work/pending.tsv" | cut -f2)"
    die "$id never ran against the pre-change tree, so the gate cannot judge it — the filter matched nothing for it and \`swift test\` exits 0 on an empty match (a #if condition excluding it here is the usual cause)"
  fi
fi

if [ "$rc" -ne 0 ] && [ "$bit" -eq 0 ]; then
  die "swift test failed against the pre-change tree without any selected test failing — a crash outside the selected tests, or a harness error. swift-bite cannot read that as evidence."
fi
[ "$ran" -eq 1 ] || die "every selected test skipped itself against the pre-change tree — nothing was judged"

finish
