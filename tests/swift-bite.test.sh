#!/usr/bin/env bash
# Table-test actions/swift-bite/swift-bite.sh. Every case builds a throwaway
# SwiftPM package with `git init`, commits a "before" state, commits an "after"
# state, and asserts the verdict the gate reaches. Runs the REAL script
# (drift-free); self-test.yml invokes this on a macOS runner.
#
# The exit-code contract under test: 0 the tests bite (or the gate stood down),
# 1 the tests pin nothing, 2 usage/environment error.
#
# Needs git, swiftc and a `swift test` that can actually run XCTest and
# swift-testing — i.e. a full Xcode toolchain. A CommandLineTools-only machine
# (no XCTest, broken swift-testing runtime) fails the capability probe below;
# SWIFT_BITE_TEST_SCAN_ONLY=1 then runs just the cases that stop before the
# verdict stage and REPORTS the skipped count, so a green line can never mean
# "the verdict cases passed" where they never ran.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
script="$root/actions/swift-bite/swift-bite.sh"
fails=0
skipped=0

[ -f "$script" ] || { echo "FAIL - $script is missing"; exit 1; }

# The composite executes the script DIRECTLY (`run: …/swift-bite.sh`), so a
# missing exec bit is a fleet-visible "Permission denied" — which the cases
# below cannot catch, because the harness invokes via `bash "$script"`.
# (Measured: the first live-ammunition caller died exactly this way.)
if [ -x "$script" ]; then
  echo "ok   - the gate script is executable (the composite runs it directly)"
else
  echo "FAIL - the gate script is not executable, and the composite runs it directly"
  fails=$((fails + 1))
fi

scan_only=0
if [ "${SWIFT_BITE_TEST_SCAN_ONLY:-}" = "1" ]; then
  scan_only=1
fi

# ---------------------------------------------------------- capability probe
probe() {
  local dir
  dir="$(mktemp -d)"
  mkdir -p "$dir/Sources/Mini" "$dir/Tests/MiniTests"
  cat >"$dir/Package.swift" <<'EOF'
// swift-tools-version:6.0
import PackageDescription
let package = Package(
    name: "mini",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "Mini"),
        .testTarget(name: "MiniTests", dependencies: ["Mini"]),
    ]
)
EOF
  echo 'public func greet(_ n: String) -> String { "hi " + n }' >"$dir/Sources/Mini/Mini.swift"
  cat >"$dir/Tests/MiniTests/ProbeTests.swift" <<'EOF'
import Testing
import XCTest
@testable import Mini

@Test func probeSwiftTesting() { #expect(greet("a") == "hi a") }

final class ProbeXCTests: XCTestCase {
    func testProbe() { XCTAssertEqual(Mini.greet("a"), "hi a") }
}
EOF
  (cd "$dir" && swift test) >"$dir/probe.log" 2>&1
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "capability probe: this toolchain cannot run XCTest + swift-testing (swift test exited $rc)"
    sed 's/^/       /' "$dir/probe.log" | tail -15
  fi
  rm -rf "$dir"
  return "$rc"
}

if [ "$scan_only" -eq 0 ]; then
  if ! probe; then
    echo "FAIL - the verdict cases need a full Xcode toolchain; set SWIFT_BITE_TEST_SCAN_ONLY=1 to run only the pre-verdict cases (loudly)"
    exit 1
  fi
fi

# --------------------------------------------------------------------- harness

# repo_new creates a git repo whose "before" commit holds a package with one
# always-passing swift-testing test, and leaves $REPO/$BEFORE set.
repo_new() {
  REPO="$(mktemp -d)"
  git -C "$REPO" init --quiet -b main
  git -C "$REPO" config user.email bite@example.invalid
  git -C "$REPO" config user.name bite
  git -C "$REPO" config commit.gpgsign false
  mkdir -p "$REPO/Sources/Mini" "$REPO/Tests/MiniTests"
  cat >"$REPO/Package.swift" <<'EOF'
// swift-tools-version:6.0
import PackageDescription
let package = Package(
    name: "mini",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "Mini"),
        .testTarget(name: "MiniTests", dependencies: ["Mini"]),
    ]
)
EOF
  cat >"$REPO/Sources/Mini/Mini.swift" <<'EOF'
// Greet is the shipping behaviour under test.
public func greet(_ name: String) -> String {
    return "hi " + name
}
EOF
  cat >"$REPO/Tests/MiniTests/GreetTests.swift" <<'EOF'
import Testing
@testable import Mini

@Test func greetExisting() {
    #expect(!greet("a").isEmpty)
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
  commit "after"
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

# skip_verdict <name> — scan-only mode's loud placeholder.
skip_verdict() {
  echo "SKIP - $1 (scan-only mode: this toolchain cannot run the verdict stage)"
  skipped=$((skipped + 1))
  rm -rf "${REPO:-}" 2>/dev/null
}

# fix_greet swaps the shipping behaviour, the change the biting tests pin.
fix_greet() {
  cat >"$REPO/Sources/Mini/Mini.swift" <<'EOF'
// Greet is the shipping behaviour under test.
public func greet(_ name: String) -> String {
    return "hello " + name
}
EOF
}

# ------------------------------------------------- cases: before the verdict
# These stop before any swift build, so they run even scan-only.

# A test-only pull request claims nothing about behaviour.
repo_new
cat >>"$REPO/Tests/MiniTests/GreetTests.swift" <<'EOF'

@Test func anotherPin() {
    #expect(greet("b") == "hi b")
}
EOF
run_gate
expect 0 "a test-only pull request stands the gate down" \
  'claims nothing about behaviour'

# No test changed at all: fix without evidence is not judged (coverage is not
# the question), and saying so is the stand-down message.
repo_new
fix_greet
run_gate
expect 0 "a fix with no test change stands the gate down" \
  'no Swift test file was added or changed'

# A comment-only edit must not put a test on trial.
repo_new
fix_greet
cat >"$REPO/Tests/MiniTests/GreetTests.swift" <<'EOF'
import Testing
@testable import Mini

// A reworded comment is not a new assertion.
@Test func greetExisting() {
    #expect(!greet("a").isEmpty)
}
EOF
run_gate
expect 0 "a comment-only edit inside a test does not select it" \
  'none changed beyond comments'

# A Bite-exempt trailer on every commit waives the gate.
repo_new
fix_greet
git -C "$REPO" add -A
git -C "$REPO" commit --quiet -m "$(printf 'refactor\n\nBite-exempt: pure rename, no behaviour change')" >/dev/null
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"
OUT="$(cd "$REPO" && BASE_SHA="$BEFORE" HEAD_SHA="$HEAD_SHA" bash "$script" 2>&1)"
RC=$?
expect 0 "a Bite-exempt trailer on every commit waives the gate" \
  'waived' 'pure rename'

# The trailer must be on EVERY commit: the claim is about the whole pull request.
# (Needs a changed test so the gate does not stand down for lack of one; the
# added test is vacuous, so the verdict stage decides — scan-only skips it.)
if [ "$scan_only" -eq 0 ]; then
  repo_new
  fix_greet
  cat >>"$REPO/Tests/MiniTests/GreetTests.swift" <<'EOF'

@Test func vacuousBesideTrailer() {
    #expect(greet("a").hasPrefix("h"))
}
EOF
  git -C "$REPO" add -A
  git -C "$REPO" commit --quiet -m "$(printf 'half one\n\nBite-exempt: only this commit says so')" >/dev/null
  echo "// nudge" >>"$REPO/Sources/Mini/Mini.swift"
  git -C "$REPO" add -A
  git -C "$REPO" commit --quiet -m "half two, no trailer" >/dev/null
  HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"
  OUT="$(cd "$REPO" && BASE_SHA="$BEFORE" HEAD_SHA="$HEAD_SHA" bash "$script" 2>&1)"
  RC=$?
  expect 1 "a trailer on only one commit does not waive the pull request" \
    'pins nothing'
else
  skip_verdict "a trailer on only one commit does not waive the pull request"
fi

# A Bite-exempt line inside a body paragraph is not a trailer.
if [ "$scan_only" -eq 0 ]; then
  repo_new
  fix_greet
  cat >>"$REPO/Tests/MiniTests/GreetTests.swift" <<'EOF'

@Test func vacuousBesideFakeTrailer() {
    #expect(greet("a").hasPrefix("h"))
}
EOF
  git -C "$REPO" add -A
  git -C "$REPO" commit --quiet -m "$(printf 'sneaky\n\nBite-exempt: buried mid-paragraph\nand the paragraph goes on, so it is body text, not a trailer.')" >/dev/null
  HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"
  OUT="$(cd "$REPO" && BASE_SHA="$BEFORE" HEAD_SHA="$HEAD_SHA" bash "$script" 2>&1)"
  RC=$?
  expect 1 "a Bite-exempt line inside a paragraph is not a trailer" \
    'pins nothing'
else
  skip_verdict "a Bite-exempt line inside a paragraph is not a trailer"
fi

# bite-exempt without a reason is an error, before anything is built.
repo_new
fix_greet
cat >>"$REPO/Tests/MiniTests/GreetTests.swift" <<'EOF'

// bite-exempt:
@Test func lazyExempt() {
    #expect(greet("a").hasPrefix("h"))
}
EOF
run_gate
expect 2 "bite-exempt without a reason is an error" \
  'no reason'

# Every selected test exempt → stood down, with the reason quoted.
repo_new
fix_greet
cat >>"$REPO/Tests/MiniTests/GreetTests.swift" <<'EOF'

// bite-exempt: pins current behaviour, not a fix
@Test func characterisation() {
    #expect(greet("a").hasPrefix("h"))
}
EOF
run_gate
expect 0 "a bite-exempt test is skipped, quoting its reason" \
  'pins current behaviour, not a fix' 'opted out'

# An unreachable base commit is an environment error, not a verdict.
repo_new
fix_greet
commit "after"
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"
OUT="$(cd "$REPO" && BASE_SHA=0000000000000000000000000000000000000000 HEAD_SHA="$HEAD_SHA" bash "$script" 2>&1)"
RC=$?
expect 2 "an unreachable base commit is an environment error" \
  'not in this checkout'

# ----------------------------------------------------- cases: the verdict
if [ "$scan_only" -eq 1 ]; then
  # Name every verdict case being skipped, so the tally below cannot read as
  # coverage that never happened.
  for name in \
    "a new swift-testing test that passes on the old source fails the gate" \
    "a new swift-testing test that fails on the old source passes the gate" \
    "a new XCTest that passes on the old source fails the gate" \
    "a new XCTest that fails on the old source passes the gate" \
    "a test for a new API counts as a bite (it cannot build without it)" \
    "a pre-change tree that does not compile on its own is not a bite" \
    "a vacuous test beside a biting one is reported, not hidden" \
    "a sloppy filter cannot leak a trap test into the verdict" \
    "a parameterized swift-testing test is judged, parens and all" \
    "a display-named swift-testing test is judged by its display line" \
    "a fixture-table edit outside every test puts the target suite on trial" \
    "an XCTest method added via an extension is still judged" \
    "a selected test that skips itself is not judged as evidence" \
    "a disabled swift-testing test alone cannot green the gate" \
    "a test that hangs without the change is a bite" \
    "a test that crashes without the change is a bite" \
    ; do skip_verdict "$name"; done
else

# The whole point of the gate: a new test that passes against the old source
# pins nothing — swift-testing flavour.
repo_new
fix_greet
cat >>"$REPO/Tests/MiniTests/GreetTests.swift" <<'EOF'

@Test func greetVacuous() {
    #expect(greet("a").hasPrefix("h"))
}
EOF
run_gate
expect 1 "a new swift-testing test that passes on the old source fails the gate" \
  'pins nothing' 'greetVacuous'

# The same shape, but the test asserts the fixed behaviour.
repo_new
fix_greet
cat >>"$REPO/Tests/MiniTests/GreetTests.swift" <<'EOF'

@Test func greetFixed() {
    #expect(greet("a") == "hello a")
}
EOF
run_gate
expect 0 "a new swift-testing test that fails on the old source passes the gate" \
  'bites' 'fails without the change'

# XCTest flavour of both.
repo_new
fix_greet
cat >"$REPO/Tests/MiniTests/GreetXCTests.swift" <<'EOF'
import XCTest
@testable import Mini

final class GreetXCTests: XCTestCase {
    func testGreetVacuous() { XCTAssertTrue(Mini.greet("a").hasPrefix("h")) }
}
EOF
run_gate
expect 1 "a new XCTest that passes on the old source fails the gate" \
  'pins nothing' 'testGreetVacuous'

repo_new
fix_greet
cat >"$REPO/Tests/MiniTests/GreetXCTests.swift" <<'EOF'
import XCTest
@testable import Mini

final class GreetXCTests: XCTestCase {
    func testGreetFixed() { XCTAssertEqual(Mini.greet("a"), "hello a") }
}
EOF
run_gate
expect 0 "a new XCTest that fails on the old source passes the gate" \
  'bites' 'fails without the change'

# A test calling an API the pull request introduces cannot compile against the
# old source — the same evidence a failing assertion gives.
repo_new
cat >>"$REPO/Sources/Mini/Mini.swift" <<'EOF'

// Shout is the fix.
public func shout(_ name: String) -> String { return "HI " + name }
EOF
cat >>"$REPO/Tests/MiniTests/GreetTests.swift" <<'EOF'

@Test func shoutWorks() {
    #expect(shout("a") == "HI a")
}
EOF
run_gate
expect 0 "a test for a new API counts as a bite (it cannot build without it)" \
  'does not build without the change'

# But when the old tree cannot compile even without the tests — the pull
# request reshaped the package — the failure says nothing about the tests.
# (A second target is what breaks it: with a single target SwiftPM's flat
# layout quietly adopts whatever lives under Sources/, as the first version of
# this case found out.)
repo_new
mkdir -p "$REPO/Sources/Extra"
cat >"$REPO/Sources/Extra/Extra.swift" <<'EOF'
public func extra() -> Int { 42 }
EOF
python3 - "$REPO/Package.swift" <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace('.target(name: "Mini"),', '.target(name: "Mini"),\n        .target(name: "Extra"),')
s = s.replace('dependencies: ["Mini"]', 'dependencies: ["Mini", "Extra"]')
open(p, 'w').write(s)
EOF
cat >>"$REPO/Tests/MiniTests/GreetTests.swift" <<'EOF'

import Extra

@Test func usesExtra() {
    #expect(extra() == 42)
}
EOF
run_gate
expect 2 "a pre-change tree that does not compile on its own is not a bite" \
  'does not compile on its own'

# One biting test carries the pull request; the vacuous one beside it is named
# and warned about, never hidden.
repo_new
fix_greet
cat >>"$REPO/Tests/MiniTests/GreetTests.swift" <<'EOF'

@Test func greetFixed() {
    #expect(greet("a") == "hello a")
}

@Test func greetVacuous() {
    #expect(greet("a").hasPrefix("h"))
}
EOF
run_gate
expect 0 "a vacuous test beside a biting one is reported, not hidden" \
  'bites' 'greetVacuous.*pins nothing'

# The filter is an unanchored regex underneath (measured): `foo` also selects
# `fooBar`, and an unescaped `foo()` is the regex `foo` — parens are
# metacharacters. Both traps below are failing tests that only a sloppy pattern
# would run; their failure would be credited as a bite (exit 0), so exit 1
# proves the selected, vacuous tests ran alone.
repo_new
cat >"$REPO/Tests/MiniTests/TrapTests.swift" <<'EOF'
import XCTest
import Testing
@testable import Mini

final class PinTests: XCTestCase {
    // An UNANCHORED pattern for testGreet also matches this name.
    func testGreetMore() { XCTFail("only an unanchored filter runs me") }
}

// An UNESCAPED pattern for greetPins() — the regex `greetPins` — matches this.
@Test func greetPinsX() {
    #expect(Bool(false), "only an unescaped filter runs me")
}
EOF
commit "plant the traps in the before tree"
BEFORE="$(git -C "$REPO" rev-parse HEAD)"
fix_greet
python3 - "$REPO/Tests/MiniTests/TrapTests.swift" <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace(
    '    func testGreetMore() { XCTFail("only an unanchored filter runs me") }',
    '    func testGreetMore() { XCTFail("only an unanchored filter runs me") }\n'
    '    func testGreet() { XCTAssertTrue(Mini.greet("a").hasPrefix("h")) }')
s += '''
@Test func greetPins() {
    #expect(greet("a").hasPrefix("h"))
}
'''
open(p, 'w').write(s)
EOF
run_gate
expect 1 "a sloppy filter cannot leak a trap test into the verdict" \
  'testGreet.*pins nothing' 'greetPins().*pins nothing'

# Parameterized swift-testing: the id carries labelled parens — the shape that
# breaks a naively escaped or naively anchored filter.
repo_new
fix_greet
cat >>"$REPO/Tests/MiniTests/GreetTests.swift" <<'EOF'

@Test(arguments: ["a", "b"]) func greetMany(_ n: String) {
    #expect(greet(n).hasPrefix("h"))
}
EOF
run_gate
expect 1 "a parameterized swift-testing test is judged, parens and all" \
  'pins nothing' 'greetMany'

# A @Test("display name") is selected and filtered by its FUNCTION id, but the
# runtime's verdict lines print the display name in quotes (measured) — a judge
# reading only function names would call the passing one "never ran" and credit
# the biting one to a collective crash. Both parse paths are pinned here: the
# biting display test must be a named bite, the vacuous one a named warning.
repo_new
fix_greet
cat >>"$REPO/Tests/MiniTests/GreetTests.swift" <<'EOF'

@Test("greets with the new word") func displayFixed() {
    #expect(greet("a") == "hello a")
}

@Test("still greets somehow") func displayVacuous() {
    #expect(greet("a").hasPrefix("h"))
}
EOF
run_gate
expect 0 "a display-named swift-testing test is judged by its display line" \
  'bites — fails without the change' 'displayVacuous().*pins nothing'

# A change outside every test function — a shared fixture table — is something
# every test in the module reads, so the whole target goes on trial, where the
# existing table-driven test bites.
repo_new
cat >"$REPO/Tests/MiniTests/GreetTests.swift" <<'EOF'
import Testing
@testable import Mini

let expectations: [(String, String)] = [
    ("a", "hi a"),
]

@Test func greetTable() {
    for (input, want) in expectations {
        #expect(greet(input) == want)
    }
}
EOF
commit "table-driven before"
BEFORE="$(git -C "$REPO" rev-parse HEAD)"
fix_greet
python3 - "$REPO/Tests/MiniTests/GreetTests.swift" <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read().replace('("a", "hi a"),', '("a", "hello a"),\n    ("b", "hello b"),')
open(p, 'w').write(s)
EOF
run_gate
expect 0 "a fixture-table edit outside every test puts the target suite on trial" \
  'on trial' 'bites'

# An XCTest method added via an extension of a class whose declaration is not
# in the diff: the scanner cannot vouch for the class, `swift test list` can.
repo_new
cat >"$REPO/Tests/MiniTests/ExtTests.swift" <<'EOF'
import XCTest
@testable import Mini

final class ExtTests: XCTestCase {
    func testAlwaysHere() { XCTAssertTrue(true) }
}
EOF
commit "class exists before"
BEFORE="$(git -C "$REPO" rev-parse HEAD)"
fix_greet
cat >"$REPO/Tests/MiniTests/ExtMoreTests.swift" <<'EOF'
import XCTest
@testable import Mini

extension ExtTests {
    func testGreetFixedViaExtension() { XCTAssertEqual(Mini.greet("a"), "hello a") }
}
EOF
run_gate
expect 0 "an XCTest method added via an extension is still judged" \
  'bites' 'testGreetFixedViaExtension'

# A selected test that skips itself said nothing about the old tree.
repo_new
fix_greet
cat >"$REPO/Tests/MiniTests/SkipTests.swift" <<'EOF'
import XCTest
@testable import Mini

final class SkipTests: XCTestCase {
    func testSkipsItself() throws { throw XCTSkip("not on this host") }
}
EOF
run_gate
expect 2 "a selected test that skips itself is not judged as evidence" \
  'nothing was judged'

# Same for a disabled swift-testing test: skipped is not evidence.
repo_new
fix_greet
cat >>"$REPO/Tests/MiniTests/GreetTests.swift" <<'EOF'

@Test(.disabled("someday")) func greetSomeday() {
    #expect(greet("a") == "hello a")
}
EOF
run_gate
expect 2 "a disabled swift-testing test alone cannot green the gate" \
  'nothing was judged'

# A hang IS evidence: the old source never finished the new test.
repo_new
cat >"$REPO/Sources/Mini/Mini.swift" <<'EOF'
// Greet is the shipping behaviour under test.
public func greet(_ name: String) -> String {
    return "hi " + name
}

// ready is the fix: the old implementation never becomes ready.
public func ready() -> Bool {
    return false
}
EOF
commit "before with a never-ready ready()"
BEFORE="$(git -C "$REPO" rev-parse HEAD)"
python3 - "$REPO/Sources/Mini/Mini.swift" <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read().replace('return false', 'return true')
open(p, 'w').write(s)
EOF
cat >>"$REPO/Tests/MiniTests/GreetTests.swift" <<'EOF'

@Test func becomesReady() {
    while !ready() {}
    #expect(ready())
}
EOF
commit "after"
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"
OUT="$(cd "$REPO" && BASE_SHA="$BEFORE" HEAD_SHA="$HEAD_SHA" SWIFT_BITE_TIMEOUT=25 bash "$script" 2>&1)"
RC=$?
expect 0 "a test that hangs without the change is a bite" \
  'hangs without the change'

# A crash is evidence too: the old source did not survive the new test.
repo_new
cat >"$REPO/Sources/Mini/Mini.swift" <<'EOF'
// Greet is the shipping behaviour under test. The old version cannot take an
// empty name; the fix is to allow it.
public func greet(_ name: String) -> String {
    precondition(!name.isEmpty, "boom")
    return "hi " + name
}
EOF
commit "before that traps on empty"
BEFORE="$(git -C "$REPO" rev-parse HEAD)"
cat >"$REPO/Sources/Mini/Mini.swift" <<'EOF'
// Greet is the shipping behaviour under test.
public func greet(_ name: String) -> String {
    if name.isEmpty { return "hello" }
    return "hi " + name
}
EOF
cat >>"$REPO/Tests/MiniTests/GreetTests.swift" <<'EOF'

@Test func emptyNameAllowed() {
    #expect(greet("") == "hello")
}
EOF
run_gate
expect 0 "a test that crashes without the change is a bite" \
  'without the change'

fi  # scan_only

# ----------------------------------------------------------------------- tally
echo
if [ "$fails" -gt 0 ]; then
  echo "$fails case(s) FAILED"
  exit 1
fi
if [ "$skipped" -gt 0 ]; then
  echo "all executed cases passed — but $skipped verdict case(s) were NOT run (scan-only mode)"
  exit 0
fi
echo "all cases passed"
