# go-bite — a test that passes without its own fix is not evidence

A diff can be reviewed. The claim *"I verified this"* cannot.

Every convention in this fleet that matters is enforced by a machine, because the
ones left to habit are the ones that quietly stop happening. This is the last big
one that was still on habit: **a test added beside a fix is only evidence if it
would have failed without the fix.** Nothing checked that. A test that pins nothing
looks exactly like a test that pins everything — green, in the same commit as a
real fix, with a name that describes the bug.

That failure mode is not hypothetical here. It is the reason this gate exists: an
agent reported "fixed, test added, tests green" more than once for a test that was
green before the fix too, and no reviewer could have told the difference by reading.

## What the gate does

On every pull request that touches shipping source, `go-bite`:

1. materialises the **base branch as it is now** as a git worktree — judged against
   the merge commit, so a stale branch cannot be credited for pinning behaviour the
   base branch already ships;
2. carries the pull request's `*_test.go`, `testdata/**` and `go.mod`/`go.sum` back
   onto it (a golden file updated to the fixed output is half the assertion, so the
   fixture has to travel with the test);
3. runs **only the test functions the pull request adds or changes**;
4. **fails the pull request if every one of them still passes.**

The exit codes are the contract: `0` at least one test bit (or the gate stood
down), `1` the tests pin nothing, `2` the gate could not judge.

**Every test is judged by name**, in `go test -v`'s own stream — never by the
package's exit code. A package can exit non-zero while every selected test passes: a
`TestMain` that exits after `m.Run`, a race report from a goroutine outliving a
test, a flake. Crediting that as a bite is precisely the false green this exists to
stop, so it is exit 2 instead.

**What the gate selects** is wider than the test functions a diff literally touches,
because the cheapest way past a span-based gate is to put the assertion somewhere
else:

| Changed | Selected |
|---|---|
| A test function's body | that function |
| A test file's helper, import or package-level fixture table | **every** test in that package |
| A seed under `testdata/fuzz/<Target>/` | that fuzz target — a committed crasher *is* the regression test, and it arrives with no `_test.go` change at all |
| Only a comment or blank line | nothing |

## What counts as a bite

- **A failing assertion.** The obvious case.
- **A hang.** The old source did not finish; hence the `-timeout` in the defaults.
- **A test that does not build** — a test calling an API the pull request introduces
  could not have passed before it. But only after `go build ./...` confirms the old
  **source** still compiles: otherwise the pull request broke the old tree (a
  dependency bump, a moved package) and a vacuous test would ride that build failure
  to green. That case is exit 2, never a bite.

The verdict is **"at least one bites"**, not "all". A change that touches twenty
test functions must not need nineteen annotations; one test that genuinely bites
makes the pull request's claim checkable. The per-test table in the job summary
names every selected test and warns about the ones that pinned nothing.

## When the gate stands down

Each of these is reported in the log and the job summary — never silent.

| Situation | Why |
|---|---|
| No shipping source changed — only tests and fixtures | Nothing is being claimed about behaviour, so there is nothing to prove. |
| No test function added, and none changed beyond comments or blank lines | Rewording a comment in a test must not put that test on trial. |
| Every selected test carries `bite-exempt: <reason>` | See below. |
| Every commit carries a `Bite-exempt: <reason>` trailer | See below. |

## The two opt-outs, and when using one is honest

**`bite-exempt: <reason>` in a test's doc comment** — for a test that deliberately
pins **current** behaviour rather than a fix. A known-limitation pin, a
characterisation test written to make a later change visible. These are valuable and
they legitimately pass against the old source, because that is their entire purpose.

```go
// TestEscapeMentionsKnownLimitations records what the escaper does with a mention
// inside a phantom code span today, so the day it changes is visible.
//
// bite-exempt: pins current behaviour, not a fix
func TestEscapeMentionsKnownLimitations(t *testing.T) {
```

**`Bite-exempt: <reason>` as a git trailer on every commit** — for a change that
moves shipping source **without changing behaviour**. A pure refactor: no test can
bite, because nothing observable changed, and the mechanical test churn would
otherwise demand an annotation per function.

It has to be a real trailer — parsed with `git interpret-trailers`, so a line that
merely starts a paragraph waives nothing — and **every** non-merge commit in the
range has to carry it, because the claim is about the whole pull request.

Both demand a reason, and both are echoed into the job summary and (for the trailer)
into the permanent history. That is the whole enforcement mechanism: the opt-out is
cheap but never invisible, so using one is a statement someone can disagree with.

**Using one to get a red gate green is the failure this tool exists to catch.** If
the honest sentence is "this test does not pin the fix", the answer is a better
test, not an annotation.

## What it does not judge

- **Coverage.** A pull request with a fix and no test at all stands the gate down.
  go-bite asks whether the tests you wrote are evidence, not whether you wrote any.
- **Whether the fix is correct.** Only whether the test can tell.
- **Anything but Go.** The Swift half of the fleet has no equivalent yet.

## Accepted limitations

- Only `*_test.go`, `testdata/**` and `go.mod`/`go.sum` travel back onto the old
  tree. A test needing a new *non*-test helper file therefore fails to build, which
  counts as a bite — the safe direction.
- A test that only bites under a flag absent from `test-args` (a data-race fix
  without `-race`) reads as non-biting. Hence `-race` in the default.
- One biting test carries a pull request that also adds a vacuous one. The per-test
  table names the vacuous one and warns; it does not fail.
- A test relocation combined with a shipping change goes red: a moved file is wholly
  new, so every function in it is selected and none can bite. Split the move into its
  own pull request, or waive it with the trailer.
- The old tree is judged by its own tests, not by the environment around it:
  `GOWORK=off`, empty `GOFLAGS`, `GOTOOLCHAIN=local`, `-vet=off`. A `go test` that
  exits non-zero *without printing a verdict* — a toolchain download, an
  inconsistent vendor directory — is reported as an environment failure (exit 2)
  rather than counted as evidence.
- Examples with no output comment are skipped: `go test` compiles them without ever
  running them, so they report a vacuous PASS.

## Adopting it

```yaml
# .github/workflows/build.yml, beside the ci: job
bite:
  uses: akira-toriyama/.github/.github/workflows/go-bite.yml@v2
  with:
    go-version-file: go.mod
```

It is safe as a required check: it only runs on `pull_request`, and it stands down
with an explanation rather than failing when there is nothing to prove. Note that
until it *is* a required check on a repo, a red verdict is visible but not blocking
— the gate reports; branch protection is what refuses.

## Where it lives

| | |
|---|---|
| [`actions/go-bite/go-bite.sh`](../actions/go-bite/go-bite.sh) | the gate |
| [`actions/go-bite/bitescan.go`](../actions/go-bite/bitescan.go) | reads test functions, spans and opt-outs with `go/ast`, because a regex gets `}` inside a raw string, generics and un-gofmt'd files wrong |
| [`actions/go-bite/action.yml`](../actions/go-bite/action.yml) | the composite |
| [`.github/workflows/go-bite.yml`](../.github/workflows/go-bite.yml) | the reusable callers pin |
| [`tests/go-bite.test.sh`](../tests/go-bite.test.sh) | the case table, each case a throwaway `git init` repo |

`self-test.yml`'s **`go-bite-self`** job holds the gate to its own standard: the
post-change case table, run against the **pre-change** script, must fail. A change
to go-bite that no case pins cannot merge.
