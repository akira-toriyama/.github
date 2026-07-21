#!/usr/bin/env bash
# Table-test actions/go-bite/go-bite.sh. Every case builds a throwaway Go repo with
# `git init`, commits a "before" state, commits a "after" state on a branch, and
# asserts the verdict the gate reaches. Runs the REAL script (drift-free);
# self-test.yml invokes this. Needs git and go; portable to macOS and ubuntu.
#
# The exit-code contract under test: 0 the tests bite (or the gate stood down),
# 1 the tests pin nothing, 2 usage/environment error.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
script="$root/actions/go-bite/go-bite.sh"
fails=0

[ -x "$script" ] || [ -f "$script" ] || { echo "FAIL - $script is missing"; exit 1; }

# Tests run without -race: the fixtures are trivial and a race build needs a C
# toolchain that this table has no reason to require.
export TEST_ARGS="-count=1"

# --------------------------------------------------------------------- harness

# repo_new creates a git repo whose "before" commit holds a package with one
# always-passing test, and leaves $REPO/$BEFORE set.
repo_new() {
  REPO="$(mktemp -d)"
  git -C "$REPO" init --quiet -b main
  git -C "$REPO" config user.email bite@example.invalid
  git -C "$REPO" config user.name bite
  git -C "$REPO" config commit.gpgsign false
  mkdir -p "$REPO/pkg"
  cat >"$REPO/go.mod" <<'EOF'
module example.invalid/bite

go 1.21
EOF
  cat >"$REPO/pkg/pkg.go" <<'EOF'
package pkg

// Greet is the shipping behaviour under test.
func Greet(name string) string {
	return "hi " + name
}
EOF
  cat >"$REPO/pkg/pkg_test.go" <<'EOF'
package pkg

import "testing"

func TestGreetExisting(t *testing.T) {
	if Greet("a") == "" {
		t.Fatal("empty")
	}
}
EOF
  commit "before"
  BEFORE="$(git -C "$REPO" rev-parse HEAD)"
}

commit() {
  git -C "$REPO" add -A
  git -C "$REPO" commit --quiet --allow-empty -m "$1" >/dev/null
}

# run_gate commits the working tree as the head state and runs the gate over it.
# Sets OUT (stdout+stderr) and RC.
run_gate() {
  commit "${1:-after}"
  HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"
  OUT="$(cd "$REPO" && BASE_SHA="$BEFORE" HEAD_SHA="$HEAD_SHA" bash "$script" 2>&1)"
  RC=$?
}

# expect <rc> <name> [<grep-pattern> ...]
expect() {
  want="$1"; name="$2"; shift 2
  ok=1
  [ "$RC" -eq "$want" ] || ok=0
  for pat in "$@"; do
    printf '%s' "$OUT" | grep -q -- "$pat" || ok=0
  done
  if [ "$ok" -eq 1 ]; then
    echo "ok   - $name"
  else
    echo "FAIL - $name (rc=$RC, want $want)"
    printf '%s\n' "$OUT" | sed 's/^/       /'
    fails=$((fails + 1))
  fi
  rm -rf "$REPO"
}

# ----------------------------------------------------------------------- cases

# A new test that passes against the old source pins nothing. This is the whole
# point of the gate: the fix is real, but the test would have been green without it.
repo_new
cat >>"$REPO/pkg/pkg.go" <<'EOF'

// Shout is the fix.
func Shout(name string) string { return "HI " + name }
EOF
cat >>"$REPO/pkg/pkg_test.go" <<'EOF'

func TestGreetVacuous(t *testing.T) {
	if Greet("a") != "hi a" {
		t.Fatal("changed")
	}
}
EOF
run_gate
expect 1 "a new test that passes on the old source fails the gate" \
  'passes against' 'TestGreetVacuous'

# The same shape, but the test asserts the fixed behaviour: it fails on the old
# source, so the pull request has shown what it claims.
repo_new
cat >"$REPO/pkg/pkg.go" <<'EOF'
package pkg

// Greet is the shipping behaviour under test.
func Greet(name string) string {
	return "hello " + name
}
EOF
cat >>"$REPO/pkg/pkg_test.go" <<'EOF'

func TestGreetFixed(t *testing.T) {
	if Greet("a") != "hello a" {
		t.Fatalf("got %q", Greet("a"))
	}
}
EOF
run_gate
expect 0 "a new test that fails on the old source passes the gate" \
  'bites' 'fails without the change'

# A test for a brand-new API cannot compile against the old source. That is the
# same evidence a failing assertion gives, so it counts as a bite.
repo_new
cat >>"$REPO/pkg/pkg.go" <<'EOF'

// Farewell is new.
func Farewell(name string) string { return "bye " + name }
EOF
cat >>"$REPO/pkg/pkg_test.go" <<'EOF'

func TestFarewell(t *testing.T) {
	if Farewell("a") != "bye a" {
		t.Fatal("wrong")
	}
}
EOF
run_gate
expect 0 "a test for a new API counts as a bite (it cannot build without it)" \
  'does not build without the change'

# A test that deliberately pins current behaviour opts out — with a reason.
repo_new
cat >>"$REPO/pkg/pkg.go" <<'EOF'

// Unrelated is the shipping change.
func Unrelated() int { return 1 }
EOF
cat >>"$REPO/pkg/pkg_test.go" <<'EOF'

// TestGreetKnownLimitation records what Greet does today.
//
// bite-exempt: pins current behaviour, not a fix
func TestGreetKnownLimitation(t *testing.T) {
	if Greet("a") != "hi a" {
		t.Fatal("changed")
	}
}
EOF
run_gate
expect 0 "a bite-exempt test is skipped" \
  'opted out' 'pins current behaviour'

# The opt-out costs an explanation, or it becomes a reflex.
repo_new
cat >>"$REPO/pkg/pkg.go" <<'EOF'

// Unrelated is the shipping change.
func Unrelated() int { return 1 }
EOF
cat >>"$REPO/pkg/pkg_test.go" <<'EOF'

// bite-exempt:
func TestGreetUnexplained(t *testing.T) {
	if Greet("a") != "hi a" {
		t.Fatal("changed")
	}
}
EOF
run_gate
expect 2 "bite-exempt without a reason is an error" \
  'no reason'

# A case added to an existing table-driven test is a changed function, and the gate
# must notice: this is how most fixes in this fleet are pinned.
repo_new
cat >"$REPO/pkg/pkg_test.go" <<'EOF'
package pkg

import "testing"

func TestGreetTable(t *testing.T) {
	for _, c := range []struct{ in, want string }{
		{"a", "hi a"},
	} {
		if got := Greet(c.in); got != c.want {
			t.Fatalf("Greet(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}
EOF
commit "table before"
BEFORE="$(git -C "$REPO" rev-parse HEAD)"
cat >"$REPO/pkg/pkg.go" <<'EOF'
package pkg

import "strings"

// Greet is the shipping behaviour under test.
func Greet(name string) string {
	return "hi " + strings.TrimSpace(name)
}
EOF
cat >"$REPO/pkg/pkg_test.go" <<'EOF'
package pkg

import "testing"

func TestGreetTable(t *testing.T) {
	for _, c := range []struct{ in, want string }{
		{"a", "hi a"},
		{" a ", "hi a"},
	} {
		if got := Greet(c.in); got != c.want {
			t.Fatalf("Greet(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}
EOF
run_gate
expect 0 "a case added to an existing table-driven test is selected and bites" \
  'TestGreetTable' 'fails without the change'

# Rewording a comment inside a test must not put that test on trial — otherwise
# every typo fix in a test file needs an opt-out.
repo_new
cat >>"$REPO/pkg/pkg.go" <<'EOF'

// Unrelated is the shipping change.
func Unrelated() int { return 1 }
EOF
cat >"$REPO/pkg/pkg_test.go" <<'EOF'
package pkg

import "testing"

func TestGreetExisting(t *testing.T) {
	// Greet must never return the empty string. (reworded)
	if Greet("a") == "" {
		t.Fatal("empty")
	}
}
EOF
run_gate
expect 0 "a comment-only edit inside a test does not select it" \
  'beyond comments'

# A pull request that touches no shipping source claims nothing about behaviour,
# so there is nothing for the gate to prove.
repo_new
cat >>"$REPO/pkg/pkg_test.go" <<'EOF'

func TestGreetCoverage(t *testing.T) {
	if Greet("") != "hi " {
		t.Fatal("wrong")
	}
}
EOF
run_gate
expect 0 "a test-only pull request stands the gate down" \
  'claims nothing about behaviour'

# A pure refactor moves shipping source without changing behaviour, so no test can
# bite. The commit footer is the honest way through.
repo_new
cat >"$REPO/pkg/pkg.go" <<'EOF'
package pkg

func prefix() string { return "hi " }

// Greet is the shipping behaviour under test.
func Greet(name string) string {
	return prefix() + name
}
EOF
cat >>"$REPO/pkg/pkg_test.go" <<'EOF'

func TestPrefix(t *testing.T) {
	if prefix() != "hi " {
		t.Fatal("wrong")
	}
}
EOF
git -C "$REPO" add -A
git -C "$REPO" commit --quiet -m "refactor

Bite-exempt: extracts a helper, behaviour unchanged"
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"
OUT="$(cd "$REPO" && BASE_SHA="$BEFORE" HEAD_SHA="$HEAD_SHA" bash "$script" 2>&1)"
RC=$?
expect 0 "a Bite-exempt commit footer waives the gate" \
  'waived by a commit footer' 'behaviour unchanged'

# A golden file updated to the fixed output is half the assertion, so testdata has
# to travel back onto the old tree with the test. Without the fixture travelling,
# the old source and the OLD golden agree and the gate would call this vacuous.
repo_new
mkdir -p "$REPO/pkg/testdata"
printf 'hi a\n' >"$REPO/pkg/testdata/golden.txt"
commit "golden before"
BEFORE="$(git -C "$REPO" rev-parse HEAD)"
cat >"$REPO/pkg/pkg.go" <<'EOF'
package pkg

// Greet is the shipping behaviour under test.
func Greet(name string) string {
	return "hello " + name
}
EOF
printf 'hello a\n' >"$REPO/pkg/testdata/golden.txt"
cat >"$REPO/pkg/golden_test.go" <<'EOF'
package pkg

import (
	"os"
	"strings"
	"testing"
)

func TestGreetGolden(t *testing.T) {
	want, err := os.ReadFile("testdata/golden.txt")
	if err != nil {
		t.Fatal(err)
	}
	if Greet("a") != strings.TrimSpace(string(want)) {
		t.Fatalf("got %q, want %q", Greet("a"), string(want))
	}
}
EOF
run_gate
expect 0 "an updated golden file travels back with the test and bites" \
  'TestGreetGolden' 'fails without the change'

# An example WITH an output comment runs, so it can pin a fix like any test.
repo_new
cat >"$REPO/pkg/pkg.go" <<'EOF'
package pkg

// Greet is the shipping behaviour under test.
func Greet(name string) string {
	return "hello " + name
}
EOF
cat >>"$REPO/pkg/pkg_test.go" <<'EOF'

func ExampleGreet() {
	fmt.Println(Greet("a"))
	// Output: hello a
}
EOF
sed 's/^import "testing"$/import (\n\t"fmt"\n\t"testing"\n)/' "$REPO/pkg/pkg_test.go" >"$REPO/pkg/pkg_test.go.new"
mv "$REPO/pkg/pkg_test.go.new" "$REPO/pkg/pkg_test.go"
run_gate
expect 0 "an example with an output comment bites" \
  'ExampleGreet' 'fails without the change'

# An example WITHOUT an output comment is compiled but never run, so `go test`
# reports a vacuous PASS for it. Selecting it would read that PASS as "pins
# nothing" and fail an honest pull request.
repo_new
cat >>"$REPO/pkg/pkg.go" <<'EOF'

// Unrelated is the shipping change.
func Unrelated() int { return 1 }
EOF
cat >>"$REPO/pkg/pkg_test.go" <<'EOF'

func ExampleGreet_undocumented() {
	_ = Greet("a")
}
EOF
run_gate
expect 0 "an example with no output comment is not selected" \
  'no test function was added'

# The gate needs the base commit in the checkout; a shallow clone must say so
# rather than guess.
repo_new
run_gate "noop"
OUT="$(cd "$REPO" && BASE_SHA=0000000000000000000000000000000000000000 HEAD_SHA="$HEAD_SHA" bash "$script" 2>&1)"
RC=$?
expect 2 "an unreachable base commit is an environment error" \
  'fetch-depth'

# ---------------------------------------------------------------------- result
if [ "$fails" -ne 0 ]; then
  echo "$fails case(s) failed"
  exit 1
fi
echo "all go-bite cases passed"
