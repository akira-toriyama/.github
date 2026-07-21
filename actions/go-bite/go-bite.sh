#!/usr/bin/env bash
# go-bite — run a pull request's NEW/CHANGED Go tests against the source as it was
# BEFORE the pull request, and fail when every one of them still passes.
#
# Why: a diff can be reviewed; the claim "I verified this fix" cannot. A test added
# beside a fix is only evidence if it would have FAILED without the fix. That is the
# one property nobody re-checks by hand every time — so check it by machine. If the
# new tests all pass against the pre-change tree they pin nothing, and the pull
# request is asserting something it has not shown.
#
# Verdict (the exit codes are the contract):
#   0  at least one selected test BIT — failed, or could not be built, without the
#      change. Also 0 when there is nothing to check (see "standing down").
#   1  every selected test passed against the pre-change tree. The gate's failure.
#   2  the gate could not judge: a usage or environment error, a pre-change tree
#      that is broken for reasons of its own, or an opt-out with no stated reason.
#      Never a verdict — silence would be a false verdict either way.
#
# Each selected test is judged BY NAME in the `-v` stream, never by the package's
# exit code: a package can exit non-zero while every selected test passes (a
# TestMain that exits after m.Run, a race report from a goroutine outliving a test,
# a flake), and crediting that as a bite is exactly the false green this exists to
# stop. A package that exits non-zero without any selected test failing is exit 2.
#
# A test that FAILS TO BUILD against the pre-change tree counts as a bite — a test
# calling an API the pull request introduces could not have passed before it — but
# only after `go build ./...` confirms the SOURCE still compiles there. Otherwise
# the pull request broke the old tree (a dependency bump, a moved package) and a
# vacuous test would ride that build failure to green.
#
# "At least one", not "all", is deliberate. A change that touches twenty test
# functions must not demand nineteen opt-out annotations; one test that genuinely
# bites makes the pull request's claim checkable. The per-test table names every
# selected test and warns about the ones that pinned nothing.
#
# Standing down (each is reported, never silent):
#   - The pull request changes no shipping source — only tests and testdata. Nothing
#     is being claimed about behaviour, so there is nothing to prove.
#   - No test function was added, and no existing one changed in a way that is more
#     than a comment or blank line.
#   - Every selected test carries `bite-exempt: <reason>` in its doc comment. For a
#     test that deliberately pins CURRENT behaviour (a known-limitation pin, a
#     characterisation test) rather than a fix.
#   - EVERY commit in the range carries a `Bite-exempt: <reason>` git trailer. For a
#     change that touches shipping source without changing behaviour — a pure
#     refactor whose test churn is mechanical. Both opt-outs demand a reason and
#     both are echoed into the job summary.
#
# Env:
#   BASE_SHA   required — the commit the pull request would merge INTO
#   HEAD_SHA   required — the merge commit (github.sha), so the pre-change tree is
#              the base branch as it is now rather than the fork point
#   TEST_ARGS  optional — flags for `go test` (default `-race -count=1 -timeout=3m`)
#
# Deliberately accepted limitations:
#   - Coverage is not judged. A fix with no test at all stands the gate down: the
#     question is whether the tests you wrote are evidence, not whether you wrote any.
#   - One biting test carries a pull request that also adds a vacuous one. The table
#     names the vacuous one and warns; it does not fail.
#   - Only `*_test.go`, `testdata/**` and `go.mod`/`go.sum` are carried back onto the
#     old tree. A test needing a new NON-test helper file therefore fails to build,
#     which counts as a bite. That is the safe direction.
#   - A test that only bites under a flag absent from TEST_ARGS (a data-race fix
#     without `-race`) reads as non-biting. Hence `-race` in the default.
#   - A non-fuzz fixture change selects nothing on its own. It travels back with the
#     test that reads it, but a regenerated golden laid over the old tree fails by
#     construction, which would manufacture a bite rather than verify one. A fuzz
#     seed corpus is the exception: a committed crasher IS the test.
#   - A test relocation combined with a shipping change goes red — a moved file is
#     wholly new, so every function in it is selected and none can bite. Split the
#     move into its own pull request, or waive it with the trailer.
#   - A deletion-only hunk is pinned to its anchor line, so deleting the last
#     declaration in a file can select the preceding, untouched function.
#   - Paths that git has to c-style-quote (a newline or quote in the filename) are
#     refused rather than parsed.
set -uo pipefail

die() { printf '::error::go-bite: %s\n' "$*" >&2; exit 2; }
note() { printf '::notice::go-bite: %s\n' "$*"; }
warn() { printf '::warning::go-bite: %s\n' "$*"; }

[ -n "${BASE_SHA:-}" ] || die "BASE_SHA is required"
[ -n "${HEAD_SHA:-}" ] || die "HEAD_SHA is required"
TEST_ARGS="${TEST_ARGS:--race -count=1 -timeout=3m}"

# The old tree must be judged by its own tests, not by the environment around it.
#   GOWORK=off       a go.work above the worktree would capture it and resolve its
#                    packages under the OUTER module — `[setup failed]`, not a verdict.
#   GOFLAGS=         an inherited -mod/-tags from the caller's job would silently
#                    change what is compiled.
#   GOTOOLCHAIN=local  setup-go already installed the toolchain HEAD's go.mod asks
#                    for, which by definition satisfies the older tree; `auto` would
#                    reach for the network mid-run and fail on something unrelated.
export GOWORK=off GOFLAGS='' GOTOOLCHAIN=local

here="$(cd "$(dirname "$0")" && pwd)"

command -v go >/dev/null || die "go is not on PATH"
repo="$(git rev-parse --show-toplevel)" || die "not inside a git repository"
cd "$repo" || die "cannot enter $repo"

for sha in "$BASE_SHA" "$HEAD_SHA"; do
  git cat-file -e "${sha}^{commit}" 2>/dev/null \
    || die "commit $sha is not in this checkout — the job needs actions/checkout with fetch-depth: 0"
done

# With HEAD_SHA the merge commit, this resolves to BASE_SHA itself: the pre-change
# tree is the base branch AS IT IS NOW. Judging against the fork point instead would
# credit a test that pins behaviour the base branch already ships.
before="$(git merge-base "$BASE_SHA" "$HEAD_SHA")" \
  || die "no merge base between $BASE_SHA and $HEAD_SHA"
short="$(git rev-parse --short "$before")"

work="$(mktemp -d)" || die "cannot create a work directory"
tree="$work/before"
cleanup() {
  git worktree remove --force "$tree" >/dev/null 2>&1
  rm -rf "$work"
}
trap cleanup EXIT

summary() {
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
  printf '%s\n' "$*" >>"$GITHUB_STEP_SUMMARY"
}
summary "### go-bite — do the new tests bite?"
summary ""

stand_down() {
  note "$1"
  summary "Stood down: $1"
  exit 0
}

# ---------------------------------------------------------------- change survey
# --no-renames turns a rename into delete+add, which is exactly what the overlay
# wants (drop the old path, treat the new one as wholly new) and keeps name-status
# to two fields.
git -c core.quotePath=false diff --name-status --no-renames "$before" "$HEAD_SHA" \
  >"$work/status.tsv" || die "cannot diff $before..$HEAD_SHA"

if cut -f2 "$work/status.tsv" | grep -q '^"'; then
  die "a changed path needs c-style quoting (a newline or quote in the filename); refusing to guess"
fi

: >"$work/overlay"   # paths to carry back from HEAD onto the old tree
: >"$work/remove"    # paths to delete from the old tree
: >"$work/added"     # added test files — every test function in them is new
: >"$work/modified"  # modified test files — only the touched functions are new
: >"$work/fuzz"      # "<pkgdir>\t<target>" for each added/changed fuzz seed
: >"$work/expand"    # package dirs whose whole test suite must be selected
: >"$work/scanned"   # package dirs already read out of HEAD
shipping=0           # did anything outside tests and testdata change?

# The files the old tree gets from HEAD: the tests themselves, the fixtures they
# read (a golden updated to the fixed output is half the assertion), and the module
# graph they resolve against.
carried() {
  case "$1" in
    *_test.go | testdata/* | */testdata/* | go.mod | */go.mod | go.sum | */go.sum) return 0 ;;
  esac
  return 1
}

# What the pull request claims to change. Tests and their fixtures assert about
# behaviour; everything else IS the behaviour.
is_shipping() {
  case "$1" in
    *_test.go | testdata/* | */testdata/*) return 1 ;;
  esac
  return 0
}

# A file under testdata/fuzz/<Target>/ is a seed for that fuzz target — a committed
# crasher is a regression test in its own right, with no `_test.go` change to notice.
record_fuzz_seed() {
  case "$1" in
    testdata/fuzz/*/*)
      rest="${1#testdata/fuzz/}"
      printf '.\t%s\n' "${rest%%/*}" >>"$work/fuzz"
      ;;
    */testdata/fuzz/*/*)
      rest="${1#*/testdata/fuzz/}"
      printf '%s\t%s\n' "${1%%/testdata/fuzz/*}" "${rest%%/*}" >>"$work/fuzz"
      ;;
  esac
}

while IFS=$'\t' read -r status path; do
  [ -n "${path:-}" ] || continue
  is_shipping "$path" && shipping=1
  carried "$path" || continue
  case "$status" in
    D) printf '%s\n' "$path" >>"$work/remove" ;;
    A)
      printf '%s\n' "$path" >>"$work/overlay"
      record_fuzz_seed "$path"
      case "$path" in *_test.go) printf '%s\n' "$path" >>"$work/added" ;; esac
      ;;
    *) # M, T (typechange) — anything that still leaves a file at HEAD
      printf '%s\n' "$path" >>"$work/overlay"
      record_fuzz_seed "$path"
      case "$path" in *_test.go) printf '%s\n' "$path" >>"$work/modified" ;; esac
      ;;
  esac
done <"$work/status.tsv"

if [ "$shipping" -eq 0 ]; then
  stand_down "this pull request changes only tests and fixtures — it claims nothing about behaviour"
fi

# A pure refactor moves shipping source without changing behaviour, so no test can
# bite. Saying so in a git trailer is the honest way through: EVERY commit has to
# carry it, because the claim is about the whole pull request, and it is parsed as a
# real trailer so a line in the middle of a paragraph cannot waive anything.
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

if [ ! -s "$work/added" ] && [ ! -s "$work/modified" ] && [ ! -s "$work/fuzz" ]; then
  stand_down "no Go test file or fuzz seed was added or changed"
fi

# --------------------------------------------------- test functions at HEAD
(cd "$work" && go build -o bitescan "$here/bitescan.go") || die "cannot build bitescan"

: >"$work/funcs.tsv"
mkdir -p "$work/head"

# extract <path>... — copy the HEAD versions out of git rather than off the
# checkout, so their line numbers line up with the diff hunks no matter which commit
# is checked out, and run bitescan over them.
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

# scan_package <dir> — read the WHOLE test suite of a package out of HEAD. Needed
# when the trail leads outside the changed functions: a fuzz target named only by a
# seed file, or an edit to a shared helper or fixture table.
scan_package() {
  grep -qxF "$1" "$work/scanned" && return 0
  printf '%s\n' "$1" >>"$work/scanned"
  if [ "$1" = "." ]; then
    git ls-tree --name-only "$HEAD_SHA" | grep '_test\.go$' >"$work/pkgfiles"
  else
    git ls-tree --name-only "$HEAD_SHA" "$1/" | grep '_test\.go$' >"$work/pkgfiles"
  fi
  extract "$work/pkgfiles"
}

cat "$work/added" "$work/modified" >"$work/changed"
extract "$work/changed"

# ------------------------------------------------------------------ selection
: >"$work/selected.tsv"

# Every test function in an added file is new.
while IFS= read -r path; do
  awk -F'\t' -v f="$path" '$1 == f && $6 == "run"' "$work/funcs.tsv" >>"$work/selected.tsv"
done <"$work/added"

# In a modified file, select the functions whose span overlaps a substantively
# changed line range. `git diff -U0` hunk headers give the ranges in HEAD's
# numbering; a hunk whose new side is zero-length is a pure deletion, pinned to its
# anchor line. A hunk that only adds or removes blank lines and `//` comments is not
# substantive — a reworded comment must not put a test on trial.
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

  awk -F'\t' -v f="$path" '$1 == f { print $3 "\t" $4 }' "$work/funcs.tsv" >"$work/spans"
  awk -F'\t' -v f="$path" '
      NR == FNR { lo[FNR] = $1; hi[FNR] = $2; n = FNR; next }
      $1 == f && $6 == "run" {
        for (i = 1; i <= n; i++) if ($3 <= hi[i] && $4 >= lo[i]) { print; break }
      }' "$work/ranges" "$work/funcs.tsv" >>"$work/selected.tsv"

  # A changed line inside NO test function is a helper, an import, or a package-level
  # fixture table — things every test in the package reads. Selecting nothing there
  # is the cheapest way to slip a vacuous pull request past the gate, so select the
  # whole package instead. Over-selection is harmless: the verdict is "at least one
  # bites", and the per-test table still names the ones that did not.
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
  [ "$orphan" -eq 1 ] && dirname "$path" >>"$work/expand"
done <"$work/modified"

while IFS= read -r dir; do
  scan_package "$dir"
  awk -F'\t' -v d="$dir" '$6 == "run" { p = $1; sub(/\/[^\/]*$/, "", p); if (p == $1) p = "."; if (p == d) print }' \
    "$work/funcs.tsv" >>"$work/selected.tsv"
  note "a change outside every test function in $dir put its whole test suite on trial"
done < <(sort -u "$work/expand")

# A fuzz seed names its target by directory. `go test -run` replays the seed corpus,
# so the crasher a fix commits is judged like any other test.
while IFS=$'\t' read -r dir target; do
  [ -n "${target:-}" ] || continue
  scan_package "$dir"
  found="$(awk -F'\t' -v d="$dir" -v t="$target" '
      $6 == "run" { p = $1; sub(/\/[^\/]*$/, "", p); if (p == $1) p = "."; if (p == d && $2 == t) print }' \
      "$work/funcs.tsv")"
  if [ -n "$found" ]; then
    printf '%s\n' "$found" >>"$work/selected.tsv"
  else
    note "a seed was added under $dir/testdata/fuzz/$target but HEAD has no such fuzz target"
  fi
done < <(sort -u "$work/fuzz")

sort -u "$work/selected.tsv" -o "$work/selected.tsv"

awk -F'\t' '$5 != "-"' "$work/selected.tsv" >"$work/exempt.tsv"

# Regroup the survivors by package directory — the unit `go test` takes.
: >"$work/run.tsv"
while IFS=$'\t' read -r path name _ _ _; do
  printf '%s\t%s\n' "$(dirname "$path")" "$name" >>"$work/run.tsv"
done < <(awk -F'\t' '$5 == "-"' "$work/selected.tsv")
sort -u "$work/run.tsv" -o "$work/run.tsv"

# Six fields, not five: `read` gives the last variable everything that is left, so
# one name short would tack the RUNNABLE column onto the reason it prints.
while IFS=$'\t' read -r path name _ _ reason _; do
  note "$path:$name opted out — $reason"
  summary "- \`$name\` (\`$path\`) opted out — $reason"
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
# The nearest go.mod above a package is its module root; run there, so a nested
# module is tested as itself rather than as a stray directory of the outer one.
module_root() {
  d="$1"
  while :; do
    [ -f "$tree/$d/go.mod" ] && { printf '%s\n' "$d"; return 0; }
    [ "$d" = "." ] && return 1
    d="$(dirname "$d")"
  done
}

record() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$work/rows.tsv"; }

: >"$work/rows.tsv"
while IFS= read -r dir; do
  names="$(awk -F'\t' -v d="$dir" '$1 == d { print $2 }' "$work/run.tsv")"
  [ -n "$names" ] || continue
  pattern="$(printf '%s' "$names" | paste -sd'|' -)"

  root="$(module_root "$dir")" || die "no go.mod above $dir — go-bite needs a Go module"
  rel="${dir#"$root"}"
  rel="${rel#/}"
  [ -n "$rel" ] || rel="."

  printf '::group::go test ./%s -run ^(%s)$ against %s\n' "$dir" "$pattern" "$short"
  # -vet=off: vet's checks grow with the toolchain, so old source can fail a NEW
  # vet — a build failure that says nothing about the tests. -v so each test can be
  # judged by name instead of by the package's overloaded exit code.
  # shellcheck disable=SC2086  # TEST_ARGS is a deliberate flag list
  out="$(cd "$tree/$root" && go test $TEST_ARGS -vet=off -v -run "^($pattern)\$" "./$rel" 2>&1)"
  rc=$?
  printf '%s\n::endgroup::\n' "$out"
  # Every search below reads this FILE, never `printf "$out" | grep`. Under
  # `set -o pipefail` that idiom reports the pipeline as FAILED whenever grep -q
  # finds its match early: grep exits at the first hit, printf takes SIGPIPE
  # (141), and pipefail hands the `if` the 141 — so a match reads as a miss. It
  # is not theoretical and not rare: it fires on a big `$out`, which is exactly
  # what a whole-package trial produces, and a whole-package trial is what this
  # gate itself chooses when a pull request touches a shared test helper. The
  # symptom was a test the gate's own log shows as `--- PASS:` being reported as
  # "never ran against the pre-change tree", with a stray "printf: write error:
  # Broken pipe" beside it (akira-toriyama/glyph#66).
  printf '%s\n' "$out" >"$work/out.txt"

  case "$out" in
    *'[setup failed]'*)
      die "the pre-change tree does not resolve (\`$dir\` reports [setup failed]) — go-bite cannot judge this pull request. If the change legitimately reshapes the module graph, waive it with a \`Bite-exempt: <reason>\` trailer on every commit." ;;
  esac

  # A test that cannot be compiled against the old source could not have passed
  # there — but only if the old SOURCE still compiles. `go build ./...` excludes
  # _test.go, which is exactly the discriminator: if it fails too, this pull request
  # broke the old tree (a dependency bump, a moved package) and the build failure is
  # an artefact of the gate rather than evidence about the tests.
  if grep -q '\[build failed\]' "$work/out.txt"; then
    if (cd "$tree/$root" && go build ./... >"$work/build.log" 2>&1); then
      while IFS= read -r name; do record "$dir" "$name" 'bites — does not build without the change'; done <<<"$names"
      continue
    fi
    printf '::group::go build ./... against %s\n' "$short"
    cat "$work/build.log"
    printf '::endgroup::\n'
    die "the pre-change tree does not compile on its own, so its test failures say nothing about this pull request. If the change legitimately reshapes the module graph or moves a package, waive it with a \`Bite-exempt: <reason>\` trailer on every commit."
  fi

  # A hang prints `panic: test timed out` and NO `--- FAIL:` line, so this arm has to
  # come before judging tests by name. It is a bite: the old source did not finish.
  if grep -q '^panic: test timed out' "$work/out.txt"; then
    while IFS= read -r name; do record "$dir" "$name" 'bites — hangs without the change'; done <<<"$names"
    continue
  fi

  # Top-level results sit in column 0; subtest results are indented, and a failing
  # subtest already marks its parent.
  bit_here=0
  ran=0
  while IFS= read -r name; do
    if grep -q "^--- FAIL: ${name} " "$work/out.txt"; then
      record "$dir" "$name" 'bites — fails without the change'
      bit_here=1
      ran=1
    elif grep -q "^--- PASS: ${name} " "$work/out.txt"; then
      record "$dir" "$name" 'passes without the change — pins nothing'
      ran=1
    elif grep -q "^--- SKIP: ${name} " "$work/out.txt"; then
      record "$dir" "$name" 'skipped itself against the pre-change tree'
    else
      die "$name never ran against the pre-change tree, so the gate cannot judge it (a build constraint excluding it on $(go env GOOS) is the usual cause)"
    fi
  done <<<"$names"

  if [ "$rc" -ne 0 ] && [ "$bit_here" -eq 0 ]; then
    die "\`$dir\` failed against the pre-change tree without any selected test failing — a TestMain that exits after m.Run, a panic or a race report from a goroutine outliving a test. go-bite cannot read that as evidence."
  fi
  [ "$ran" -eq 1 ] || die "every selected test in \`$dir\` skipped itself against the pre-change tree — nothing was judged"
done < <(cut -f1 "$work/run.tsv" | sort -u)

summary "Ran the tests this pull request adds or changes against \`$short\`, the source before it."
summary ""
summary "| package | test | verdict |"
summary "| --- | --- | --- |"
while IFS=$'\t' read -r dir name verdict; do
  printf 'go-bite: %s %s — %s\n' "$dir" "$name" "$verdict"
  summary "| \`$dir\` | \`$name\` | $verdict |"
  case "$verdict" in
    'passes'*) warn "$dir:$name passes against the pre-change tree — it pins nothing" ;;
  esac
done <"$work/rows.tsv"

if grep -q $'\tbites' "$work/rows.tsv"; then
  note "the new tests bite — they fail against the source before this pull request"
  exit 0
fi

printf '::error::go-bite: every test this pull request adds or changes still passes against %s, the source before it. Those tests pin nothing, so the change they accompany is unproven. Make one of them fail without the change; or annotate a test that deliberately pins current behaviour with `bite-exempt: <reason>` in its doc comment; or, for a refactor that changes no behaviour at all, add a `Bite-exempt: <reason>` trailer to every commit.\n' \
  "$short" >&2
exit 1
