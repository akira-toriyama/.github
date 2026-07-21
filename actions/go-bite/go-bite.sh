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
#   0  at least one selected test failed against the pre-change tree — the tests bite.
#      Also 0 when there is nothing to check (see "when the gate stands down").
#   1  every selected test passed against the pre-change tree. The gate's failure.
#   2  usage/environment error, or an opt-out with no stated reason.
#
# A package that FAILS TO BUILD against the pre-change tree counts as a bite: a test
# calling an API the pull request introduces could not have passed before it, which
# is the same evidence a failing assertion gives.
#
# "At least one", not "all", is deliberate. A change that touches twenty test
# functions must not demand nineteen opt-out annotations; one test that genuinely
# bites makes the pull request's claim checkable. The per-package table in the job
# summary shows a reader which ones actually bit.
#
# When the gate stands down (each is reported, never silent):
#   - The pull request changes no shipping source — only tests and testdata. Nothing
#     is being claimed about behaviour, so there is nothing to prove.
#   - No test function was added, and no existing one changed in a way that is more
#     than a comment or blank line.
#   - Every selected test carries `bite-exempt: <reason>` in its doc comment. For a
#     test that deliberately pins CURRENT behaviour (a known-limitation pin, a
#     characterisation test) rather than a fix.
#   - A commit in the range carries a `Bite-exempt: <reason>` footer. For a change
#     that touches shipping source without changing behaviour — a pure refactor whose
#     test churn is mechanical. Both opt-outs demand a reason (bitescan.go enforces
#     the doc-comment one) and both are echoed into the job summary.
#
# Env:
#   BASE_SHA   required — the pull request's base commit
#   HEAD_SHA   required — the pull request's head commit
#   TEST_ARGS  optional — flags for `go test` (default `-race -count=1`)
#
# Deliberately accepted limitations:
#   - Only `*_test.go`, `testdata/**` and `go.mod`/`go.sum` are carried back onto the
#     old tree. A test needing a new NON-test helper file therefore fails to build,
#     which counts as a bite. That is the safe direction.
#   - A test that only bites under a flag absent from TEST_ARGS (a data-race fix
#     without `-race`) reads as non-biting. Hence `-race` in the default.
#   - Paths that git has to c-style-quote (a newline or quote in the filename) are
#     refused rather than parsed.
set -uo pipefail

die() { printf '::error::go-bite: %s\n' "$*" >&2; exit 2; }
note() { printf '::notice::go-bite: %s\n' "$*"; }

: "${BASE_SHA:?BASE_SHA is required}"
: "${HEAD_SHA:?HEAD_SHA is required}"
TEST_ARGS="${TEST_ARGS:--race -count=1}"

# The old tree must be judged by its own tests, not by the environment around it.
#   GOWORK=off       a go.work above the worktree would capture it and resolve its
#                    packages under the OUTER module — `[setup failed]`, not a verdict.
#   GOFLAGS=         an inherited -mod/-tags from the caller's job would silently
#                    change what is compiled.
#   GOTOOLCHAIN=local  setup-go already installed the toolchain HEAD's go.mod asks
#                    for, which by definition satisfies the older tree; `auto` would
#                    reach for the network mid-run and fail on something unrelated.
export GOWORK=off GOFLAGS= GOTOOLCHAIN=local

here="$(cd "$(dirname "$0")" && pwd)"

command -v go >/dev/null || die "go is not on PATH"
repo="$(git rev-parse --show-toplevel)" || die "not inside a git repository"
cd "$repo" || die "cannot enter $repo"

for sha in "$BASE_SHA" "$HEAD_SHA"; do
  git cat-file -e "${sha}^{commit}" 2>/dev/null \
    || die "commit $sha is not in this checkout — the job needs actions/checkout with fetch-depth: 0"
done

# The "before" tree is the merge base, not the base branch tip: the question is what
# this pull request changed, not what main did meanwhile.
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
shipping=0           # did anything outside tests and testdata change?

# The files the old tree gets from HEAD: the tests themselves, the fixtures they
# read (a golden file updated to the fixed output is half the assertion), and the
# module graph they resolve against.
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

while IFS=$'\t' read -r status path; do
  [ -n "${path:-}" ] || continue
  is_shipping "$path" && shipping=1
  carried "$path" || continue
  case "$status" in
    D) printf '%s\n' "$path" >>"$work/remove" ;;
    A)
      printf '%s\n' "$path" >>"$work/overlay"
      case "$path" in *_test.go) printf '%s\n' "$path" >>"$work/added" ;; esac
      ;;
    *) # M, T (typechange) — anything that still leaves a file at HEAD
      printf '%s\n' "$path" >>"$work/overlay"
      case "$path" in *_test.go) printf '%s\n' "$path" >>"$work/modified" ;; esac
      ;;
  esac
done <"$work/status.tsv"

if [ ! -s "$work/added" ] && [ ! -s "$work/modified" ]; then
  stand_down "no Go test file was added or changed"
fi

if [ "$shipping" -eq 0 ]; then
  stand_down "this pull request changes only tests and fixtures — it claims nothing about behaviour"
fi

# A pure refactor moves shipping source without changing behaviour, so no test can
# bite. Saying so in a commit footer is the honest way through; the reason lands in
# the permanent history and in the summary below.
waiver="$(git log --format='%B' "$before..$HEAD_SHA" \
  | sed -n 's/^Bite-exempt:[[:space:]]*//p' | sed -n '1p')"
if [ -n "$waiver" ]; then
  summary "Waived by a \`Bite-exempt:\` commit footer — $waiver"
  stand_down "waived by a commit footer — $waiver"
fi

# --------------------------------------------------- test functions at HEAD
# Read the test files out of HEAD rather than off the checkout: their line numbers
# have to line up with the diff hunks no matter which commit is checked out.
cat "$work/added" "$work/modified" >"$work/changed"
mkdir -p "$work/head"
while IFS= read -r path; do
  mkdir -p "$work/head/$(dirname "$path")"
  git show "$HEAD_SHA:$path" >"$work/head/$path" || die "cannot read $path at $HEAD_SHA"
done <"$work/changed"

(cd "$work" && go build -o bitescan "$here/bitescan.go") || die "cannot build bitescan"

# NUL-delimited so a path with a space survives xargs' own word splitting.
if ! (cd "$work/head" && tr '\n' '\0' <"$work/changed" | xargs -0 "$work/bitescan") >"$work/funcs.tsv"; then
  die "cannot read the test functions out of $HEAD_SHA"
fi

# ------------------------------------------------------------------ selection
: >"$work/selected.tsv"

# Every test function in an added file is new.
while IFS= read -r path; do
  awk -F'\t' -v f="$path" '$1 == f' "$work/funcs.tsv" >>"$work/selected.tsv"
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
  awk -F'\t' -v f="$path" '
      NR == FNR { lo[FNR] = $1; hi[FNR] = $2; n = FNR; next }
      $1 == f {
        for (i = 1; i <= n; i++) if ($3 <= hi[i] && $4 >= lo[i]) { print; break }
      }' "$work/ranges" "$work/funcs.tsv" >>"$work/selected.tsv"
done <"$work/modified"

sort -u "$work/selected.tsv" -o "$work/selected.tsv"

awk -F'\t' '$5 != "-"' "$work/selected.tsv" >"$work/exempt.tsv"

# Regroup the survivors by package directory — the unit `go test` takes.
: >"$work/run.tsv"
while IFS=$'\t' read -r path name _ _ _; do
  printf '%s\t%s\n' "$(dirname "$path")" "$name" >>"$work/run.tsv"
done < <(awk -F'\t' '$5 == "-"' "$work/selected.tsv")
sort -u "$work/run.tsv" -o "$work/run.tsv"

while IFS=$'\t' read -r path name _ _ reason; do
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

bit=0
: >"$work/report.md"
while IFS= read -r dir; do
  names="$(awk -F'\t' -v d="$dir" '$1 == d { print $2 }' "$work/run.tsv" | paste -sd'|' -)"
  [ -n "$names" ] || continue

  root="$(module_root "$dir")" || die "no go.mod above $dir — go-bite needs a Go module"
  rel="${dir#"$root"}"
  rel="${rel#/}"
  [ -n "$rel" ] || rel="."

  printf '::group::go test ./%s -run ^(%s)$ against %s\n' "$dir" "$names" "$short"
  # -vet=off: vet's checks grow with the toolchain, so old source can fail a NEW
  # vet — a build failure that says nothing about the tests. -v so the run can be
  # checked for the tests actually executing.
  # shellcheck disable=SC2086  # TEST_ARGS is a deliberate flag list
  out="$(cd "$tree/$root" && go test $TEST_ARGS -vet=off -v -run "^($names)\$" "./$rel" 2>&1)"
  rc=$?
  printf '%s\n::endgroup::\n' "$out"

  built=1
  case "$out" in
    *'[build failed]'*) built=0 ;;
    *'[setup failed]'*)
      die "the pre-change tree does not resolve (\`$dir\` reports [setup failed]) — go-bite cannot judge this pull request. If the change legitimately reshapes the module graph, waive it with a \`Bite-exempt: <reason>\` commit footer." ;;
  esac

  # A `go test` that exits non-zero without ever reaching a verdict — a toolchain
  # download, an inconsistent vendor directory — prints no FAIL line at all. Counting
  # that as a bite would pass the gate on an infrastructure hiccup.
  if [ "$rc" -ne 0 ] && ! printf '%s' "$out" | grep -q '^FAIL'; then
    die "go test could not run against the pre-change tree (exit $rc, no verdict printed) — see the group above"
  fi

  # `-run` that matches nothing exits 0 with a PASS, and so does an example with no
  # output comment. Either would read as "this test pins nothing" when the truth is
  # "this test never ran".
  if [ "$built" -eq 1 ]; then
    missing=""
    for name in $(printf '%s' "$names" | tr '|' ' '); do
      printf '%s' "$out" | grep -q "^=== RUN  *${name}\$" || missing="$missing $name"
    done
    [ -z "$missing" ] \
      || die "these tests never ran against the pre-change tree, so the gate cannot judge them:$missing (a build constraint excluding them on $(go env GOOS) is the usual cause)"
  fi

  if [ "$rc" -ne 0 ]; then
    bit=1
    if [ "$built" -eq 0 ]; then
      verdict='bites — does not build without the change'
    else
      verdict='bites — fails without the change'
    fi
  else
    verdict='passes without the change — pins nothing'
  fi
  printf 'go-bite: %s [%s] %s\n' "$dir" "$(printf '%s' "$names" | tr '|' ' ')" "$verdict"
  printf '| `%s` | `%s` | %s |\n' "$dir" "$(printf '%s' "$names" | tr '|' ' ')" "$verdict" >>"$work/report.md"
done < <(cut -f1 "$work/run.tsv" | sort -u)

summary "Ran the tests this pull request adds or changes against \`$short\`, the source before it."
summary ""
summary "| package | tests | verdict |"
summary "| --- | --- | --- |"
[ -n "${GITHUB_STEP_SUMMARY:-}" ] && cat "$work/report.md" >>"$GITHUB_STEP_SUMMARY"

if [ "$bit" -eq 1 ]; then
  note "the new tests bite — they fail against the source before this pull request"
  exit 0
fi

printf '::error::go-bite: every test this pull request adds or changes still passes against %s, the source before it. Those tests pin nothing, so the change they accompany is unproven. Make one of them fail without the change; or annotate a test that deliberately pins current behaviour with `bite-exempt: <reason>` in its doc comment; or, for a refactor that changes no behaviour at all, add a `Bite-exempt: <reason>` footer to a commit.\n' \
  "$short" >&2
exit 1
