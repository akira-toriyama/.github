# swift-bite — the go-bite claim, held against the Swift half of the fleet

[go-bite](go-bite.md) states the claim once: **a test added beside a fix is only
evidence if it would have failed without the fix**, and a machine has to check
that because nobody re-checks it by hand. Until this gate, the machine checked
it for eleven Go repos and zero of the eight Swift ones — this file exists so
that sentence stops being true. Read go-bite.md first; everything below is only
what Swift changes.

## What is identical

The verdict, the exit codes (`0` bites or stood down, `1` pins nothing, `2`
cannot judge), the merge-commit framing, the "at least one bites" rule, the
per-test table in the job summary, and both opt-outs — `bite-exempt: <reason>`
above a test, `Bite-exempt: <reason>` as a git trailer on every commit — carry
over unchanged, including the rule that an opt-out with no reason is exit 2.

## What Swift changes, and the measurements that decided it

All measured on the gate's real runner (macos-15 / Xcode 26.3 / Swift 6.2.4,
2026-07-28), not inferred from documentation:

- **`swift test --filter` that matches nothing exits 0** with a one-line
  warning. That is the exact false green the gate exists to stop, so every
  selected test must be found in the output BY NAME, or the gate is exit 2.
- **The filter is an unanchored regex**: `stPasses` also selects `testPasses`
  (substring), and `()` are metacharacters. Patterns are therefore anchored and
  escaped, and their shapes differ by framework because the underlying IDs do:
  an XCTest is `^Module\.Class/testFoo$`, but a swift-testing ID carries a
  trailing `/File.swift:line:col` segment, so its exact form is
  `^Module\.Suite/name\(\)/` — a `$` there matches nothing, ever.
- **`--xunit-output` writes the swift-testing half only** (`*-swift-testing.xml`);
  no XCTest XML appears in a serial run. Verdicts are read from the console
  stream instead: `Test Case '-[Mod.Class testFoo]' passed/failed/skipped` for
  XCTest, `✔/✘/➜ Test name() passed/failed/skipped` for swift-testing.
- **`swift build` does not compile test targets**, which makes it the
  discriminator go-bite gets from `go build ./...`: test build fails + source
  build stands → the tests call an API the pull request introduces → a bite;
  both fail → the pull request broke the old tree → exit 2, waive with the
  trailer if the reshape is the point.
- **The runner images ship no `timeout` binary**, so the hang watchdog is built
  into the script (`SWIFT_BITE_TIMEOUT`, default 600 s). A run that was killed
  or crashed loses whatever output the harness had buffered, so the gate never
  relies on per-test `started` lines: a selected test with no terminal line, in
  a run that demonstrably started and then died, is a bite judged collectively —
  the filter had restricted execution to the selected tests alone.
- **Both frameworks are first-class.** The fleet is XCTest in five repos,
  swift-testing in three (one mixed), and one `swift test` run judges both.

## How the test functions are read

`actions/swift-bite/bitescan.swift` — the go/ast of this gate. It parses with
the toolchain's own parser by dlopen-ing **sourcekitdInProc** straight out of
the active toolchain: declaration tree with byte spans, `@Test` attributes,
`XCTestCase` inheritance by name, and the comment map the `bite-exempt:` scan
reads. Zero third-party dependencies, compiled by `swiftc` in about a second at
gate time, and the grammar can never lag the compiler the fleet builds with.

The alternatives lost on measurement: SwiftSyntax needs a multi-minute package
build per run; `swiftc -frontend -dump-parse` leaves inherited-type names
empty, so an XCTestCase subclass is invisible there; sourcekitten is the same
sourcekitd underneath plus a brew dependency.

Scanner IDs are bound to runnable, module-qualified IDs through
`swift test list` on the overlaid tree — the scanner cannot know the target
name (only Package.swift does), and the list doubles as the reality check: a
definite test the runner has never heard of is exit 2, never a silent drop.

## What the gate selects

Same table as go-bite, with Swift units: a changed test function selects
itself; a substantive change outside every test function in a test file — a
shared helper, a fixture table — puts the **whole test target** on trial,
because a Swift test target is one module and every test in it can read that
helper. Comment-only and blank-line-only edits select nothing.

What travels back onto the pre-change tree: `Tests/**`, `Package.swift`,
`Package.resolved`. A test needing a new `Sources/` helper fails to build
there, which is a bite — the safe direction.

## Accepted limitations

- `XCTestCase` subclassing is recognised by name, one level (the fleet's only
  shape — measured zero intermediate base classes). A method added via
  `extension SomeTests` whose class declaration is outside the diff is carried
  as `maybe` and kept only if `swift test list` knows it.
- swift-testing verdict lines are unqualified (`✘ Test name() failed…`), so two
  SELECTED tests sharing a bare name are judged collectively.
- A test behind a `#if` that excludes it on the runner is exit 2 with a hint,
  the same direction as go-bite's build-constraint case.
- No fuzz-corpus analog: SwiftPM has no committed-crasher convention for
  swift-testing today.

## Adopting it

```yaml
# .github/workflows/build.yml, beside the build: job
bite:
  uses: akira-toriyama/.github/.github/workflows/swift-bite.yml@v2
```

The runner input defaults to `macos-26` (the app family's floor — `swift test`
executes the built binaries, and a macos-15 host cannot load minos-26 images);
a package with a lower floor may pass `runner: macos-15`. Like go-bite, it only
runs on `pull_request`, stands down with an explanation when there is nothing
to prove, and is safe as a required check — and not blocking until it is one.

## Where it lives

| | |
|---|---|
| [`actions/swift-bite/swift-bite.sh`](../actions/swift-bite/swift-bite.sh) | the gate |
| [`actions/swift-bite/bitescan.swift`](../actions/swift-bite/bitescan.swift) | the scanner (sourcekitd, zero dependencies) |
| [`actions/swift-bite/skdshim.h`](../actions/swift-bite/skdshim.h) | the two C typedefs Swift cannot declare itself |
| [`actions/swift-bite/action.yml`](../actions/swift-bite/action.yml) | the composite |
| [`.github/workflows/swift-bite.yml`](../.github/workflows/swift-bite.yml) | the reusable callers pin |
| [`tests/swift-bite.test.sh`](../tests/swift-bite.test.sh) | the case table, each case a throwaway `git init` package |

`self-test.yml`'s **`swift-bite-test`** job runs the table on a macOS runner
(the one place XCTest and swift-testing can actually run — the table refuses a
lesser toolchain rather than skipping silently), and **`swift-bite-self`**
holds the gate to its own standard: the post-change table, run against the
pre-change script, must fail.
