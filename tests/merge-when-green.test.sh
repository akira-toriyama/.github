#!/usr/bin/env bash
# Table-test scripts/merge-when-green.sh — the hand-merge loop a rollout's
# person-owned pulls go through. Runs the REAL script (drift-free) against a
# stubbed `gh` on PATH, the glyph-pin-land.test.sh pattern. Needs bash + awk.
#
# What a live run cannot show and these cases pin: a pending pull is polled
# until it settles and merged only once it is green; a failed check never
# merges; a check gh prints as `fail` under exit 0 (a cancelled one) never
# merges either, so the verdict is the rows and not the exit code; skipping is
# green; a head with no checks at all merges; the deadline stops the wait
# without a merge, and is counted per pull; the poll interval is the env's;
# `08` is eight seconds; a refused merge is said so; a last line with no
# newline is still a pull; and a malformed list merges nothing.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
script="$root/scripts/merge-when-green.sh"
fails=0

[ -f "$script" ] || { echo "FAIL - $script is missing"; exit 1; }

stub_dir="$(mktemp -d)"
trap 'rm -rf "$stub_dir"' EXIT

# A `gh` that answers `pr checks` and `pr merge` from files under $STUB_HOME
# and appends every call to $STUB_HOME/calls.log (`pr <sub> <repo> <n> [flags]`):
#   checks-<r>-<n>/<k>   the k-th `pr checks` answer (the last one repeats):
#                        line 1 the exit code, `E <text>` lines to stderr, the
#                        rest to stdout — gh's non-tty rows; a 51st poll of
#                        one pull exits 64
#   merge-fail-<r>-<n>   present = `pr merge` is refused
cat >"$stub_dir/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
[ "${1:-}" = "pr" ] || { echo "stub gh: unhandled $*" >&2; exit 64; }
sub="${2:-}"; shift 2
num=""; repo=""; flags=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --*) flags="$flags $1"; shift ;;
    *) num="$1"; shift ;;
  esac
done
printf 'pr %s %s %s%s\n' "$sub" "$repo" "$num" "$flags" >> "$STUB_HOME/calls.log"
r="${repo##*/}"
case "$sub" in
  checks)
    dir="$STUB_HOME/checks-$r-$num"
    [ -d "$dir" ] || { echo "stub gh: no checks table for $repo#$num" >&2; exit 64; }
    k="$(grep -c "^pr checks $repo $num\$" "$STUB_HOME/calls.log")"
    # A loop that never stops polling ends here instead of hanging the job.
    [ "$k" -le 50 ] || { echo "stub gh: $repo#$num polled $k times" >&2; exit 64; }
    while [ "$k" -gt 1 ] && [ ! -e "$dir/$k" ]; do k=$((k - 1)); done
    f="$dir/$k"
    rc="$(head -n 1 "$f")"
    tail -n +2 "$f" | while IFS= read -r line; do
      case "$line" in "E "*) printf '%s\n' "${line#E }" >&2 ;; *) printf '%s\n' "$line" ;; esac
    done
    exit "$rc" ;;
  merge)
    if [ -e "$STUB_HOME/merge-fail-$r-$num" ]; then
      echo "GraphQL: Pull request is not mergeable (mergePullRequest)" >&2; exit 1
    fi
    echo "✓ Squashed and merged pull request $repo#$num" ;;
  *) echo "stub gh: unhandled pr $sub" >&2; exit 64 ;;
esac
STUB
chmod +x "$stub_dir/gh"

# A fake clock, so a deadline case neither waits nor races the wall clock:
# `date +%s` reads $STUB_HOME/clock, and `sleep N` appends N to
# $STUB_HOME/sleep.log and advances the clock by N.
cat >"$stub_dir/date" <<'STUB'
#!/usr/bin/env bash
[ "$*" = "+%s" ] || { echo "stub date: unhandled $*" >&2; exit 64; }
cat "$STUB_HOME/clock"
STUB
cat >"$stub_dir/sleep" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_HOME/sleep.log"
case "$*" in ''|*[!0-9]*) echo "stub sleep: not whole seconds: $*" >&2; exit 64 ;; esac
echo $(( $(cat "$STUB_HOME/clock") + 10#$1 )) > "$STUB_HOME/clock"
STUB
chmod +x "$stub_dir/date" "$stub_dir/sleep"

fresh() {
  export STUB_HOME="$stub_dir/home"
  rm -rf "$STUB_HOME"; mkdir -p "$STUB_HOME"
  : > "$STUB_HOME/calls.log"
  : > "$STUB_HOME/sleep.log"
  echo 1000 > "$STUB_HOME/clock"
  : > "$stub_dir/list"
}
# answer <repo-name> <n> <k> <rc> [<name>=<bucket> | E<text>]... — the k-th
# `pr checks` answer for o/<repo-name>#<n>, rows in gh's non-tty shape
answer() {
  local r="$1" n="$2" k="$3" rc="$4" a; shift 4
  mkdir -p "$STUB_HOME/checks-$r-$n"
  { printf '%s\n' "$rc"
    for a in "$@"; do
      case "$a" in
        E*) printf 'E %s\n' "${a#E}" ;;
        *) printf '%s\t%s\t%s\t%s\t\n' "${a%%=*}" "${a#*=}" 5s "https://github.com/o/$r/actions/runs/1/job/$k" ;;
      esac
    done; } > "$STUB_HOME/checks-$r-$n/$k"
}
list() { printf '%s\n' "$@" > "$stub_dir/list"; }

run_script() { MERGE_WHEN_GREEN_POLL_SECONDS="${POLL:-0}" PATH="$stub_dir:$PATH" bash "$script" "$@" >"$stub_dir/out" 2>"$stub_dir/err"; }

out_is() { [ "$(cat "$stub_dir/out")" = "$1" ]; }
err_has() { grep -qF -- "$1" "$stub_dir/err"; }
merges() { grep -c '^pr merge' "$STUB_HOME/calls.log"; }
polls() { grep -c "^pr checks $1 $2\$" "$STUB_HOME/calls.log"; }
sleeps_are() { [ "$(tr '\n' ',' < "$STUB_HOME/sleep.log")" = "$1" ]; }

check() { # check <name> <condition> [--and <condition>]...
  local name="$1" ok=1 cond=(); shift
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "--and" ]; then
      [ "${#cond[@]}" -eq 0 ] || "${cond[@]}" || ok=0
      cond=()
    else
      cond+=("$1")
    fi
    shift
  done
  [ "${#cond[@]}" -eq 0 ] || "${cond[@]}" || ok=0
  if [ "$ok" -eq 1 ]; then echo "ok   - $name"; else
    echo "FAIL - $name"
    sed 's/^/         stdout: /' "$stub_dir/out"
    sed 's/^/         stderr: /' "$stub_dir/err"
    sed 's/^/         calls:  /' "$STUB_HOME/calls.log" 2>/dev/null
    fails=$((fails + 1))
  fi
}

# usage — nothing is polled or merged
fresh
run_script; rc=$?
check "no list is usage (exit 2)" [ "$rc" -eq 2 ]
run_script "$stub_dir/missing"; rc=$?
check "an unreadable list is usage (exit 2)" [ "$rc" -eq 2 ]
list 'o/alpha 1'
run_script "$stub_dir/list" soon; rc=$?
check "a deadline that is not whole seconds is usage (exit 2)" [ "$rc" -eq 2 ]
POLL=x run_script "$stub_dir/list"; rc=$?
check "a poll interval that is not whole seconds is usage (exit 2)" [ "$rc" -eq 2 ]
list '' ''
run_script "$stub_dir/list"; rc=$?
check "a list with no pull in it is usage (exit 2)" [ "$rc" -eq 2 ]
list 'o/alpha 1' 'alpha 2'
run_script "$stub_dir/list"; rc=$?
check "a line with no owner/repo is usage, naming the line — and nothing is polled" \
  [ "$rc" -eq 2 ] --and err_has "list:2:" --and [ ! -s "$STUB_HOME/calls.log" ]
list 'o/alpha https://github.com/o/alpha/pull/x'
run_script "$stub_dir/list"; rc=$?
check "a line whose pull is not a number is usage (exit 2)" [ "$rc" -eq 2 ]

# pending, then pass: polled until it settles, then squash-merged
fresh
answer alpha 1 1 8 build=pending lint=pass
answer alpha 1 2 0 build=pass lint=pass
list 'o/alpha 1'
run_script "$stub_dir/list"; rc=$?
check "pending then pass merges: exit 0, the merged line with the tally" \
  [ "$rc" -eq 0 ] --and out_is "o/alpha #1 merged checks=[pass=2]"
check "…after two polls, with ONE squash merge" \
  [ "$(polls o/alpha 1)" -eq 2 ] --and [ "$(merges)" -eq 1 ] --and grep -qx "pr merge o/alpha 1 --squash" "$STUB_HOME/calls.log"

# a failed check never merges
fresh
answer alpha 2 1 1 build=fail lint=pass
list 'o/alpha 2'
run_script "$stub_dir/list"; rc=$?
check "a failed check is NOT merged: exit 1, the bad check named" \
  [ "$rc" -eq 1 ] --and out_is "o/alpha #2 NOT merged rc=1 bad=[build=fail]"
check "…and no merge is attempted" [ "$(merges)" -eq 0 ]

# a cancelled check: gh prints `fail` and exits 0
fresh
answer alpha 3 1 0 build=fail lint=pass
list 'o/alpha 3'
run_script "$stub_dir/list"; rc=$?
check "a fail row under exit 0 (cancelled) is NOT merged — the rows decide, not the exit" \
  [ "$rc" -eq 1 ] --and out_is "o/alpha #3 NOT merged rc=0 bad=[build=fail]" --and [ "$(merges)" -eq 0 ]

# skipping is green
fresh
answer alpha 4 1 0 build=pass docs=skipping
list 'o/alpha 4'
run_script "$stub_dir/list"; rc=$?
check "pass and skipping merge, both tallied" \
  [ "$rc" -eq 0 ] --and out_is "o/alpha #4 merged checks=[pass=1 skipping=1]" --and [ "$(merges)" -eq 1 ]

# no checks at all
fresh
answer alpha 5 1 1 "Eno checks reported on the 'config/drop-style' branch"
list 'o/alpha 5'
run_script "$stub_dir/list"; rc=$?
check "a head gh reports no checks on merges: checks=[none]" \
  [ "$rc" -eq 0 ] --and out_is "o/alpha #5 merged checks=[none]" --and [ "$(merges)" -eq 1 ]

# any other exit 1 without rows is not green
fresh
answer alpha 6 1 1 "EHTTP 502: Bad Gateway (https://api.github.com/graphql)"
list 'o/alpha 6'
run_script "$stub_dir/list"; rc=$?
check "an exit 1 with no rows and no no-checks answer is NOT merged, gh's words on stderr" \
  [ "$rc" -eq 1 ] --and out_is "o/alpha #6 NOT merged rc=1 bad=[]" --and err_has "HTTP 502" --and [ "$(merges)" -eq 0 ]

# the deadline
fresh
answer alpha 7 1 8 build=pending
list 'o/alpha 7'
run_script "$stub_dir/list" 0; rc=$?
check "a deadline passed while pending is NOT merged, rc=124, the pending check named" \
  [ "$rc" -eq 1 ] --and out_is "o/alpha #7 NOT merged rc=124 bad=[build=pending]" --and [ "$(merges)" -eq 0 ]
check "…after a single poll" [ "$(polls o/alpha 7)" -eq 1 ]

# the deadline is per pull: the first pull spending past it leaves the second
# its own (deadline 5 s, polls 3 s apart on the fake clock)
fresh
answer alpha 12 1 8 build=pending
answer beta 13 1 8 build=pending
answer beta 13 2 0 build=pass
list 'o/alpha 12' 'o/beta 13'
POLL=3 run_script "$stub_dir/list" 5; rc=$?
check "a pull past its deadline does not spend the next pull's: one held at rc=124, the next merged" \
  [ "$rc" -eq 1 ] --and out_is "o/alpha #12 NOT merged rc=124 bad=[build=pending]
o/beta #13 merged checks=[pass=1]" --and [ "$(polls o/alpha 12)" -eq 3 ] --and [ "$(polls o/beta 13)" -eq 2 ]

# the poll interval is MERGE_WHEN_GREEN_POLL_SECONDS
fresh
answer alpha 14 1 8 build=pending
answer alpha 14 2 0 build=pass
list 'o/alpha 14'
POLL=7 run_script "$stub_dir/list"; rc=$?
check "the poll env is honoured: one sleep of 7 s between the two polls" \
  [ "$rc" -eq 0 ] --and sleeps_are "7," --and [ "$(polls o/alpha 14)" -eq 2 ]
fresh
answer alpha 14 1 8 build=pending
answer alpha 14 2 0 build=pass
list 'o/alpha 14'
POLL=0 run_script "$stub_dir/list"; rc=$?
check "…and 0 is 0" [ "$rc" -eq 0 ] --and sleeps_are "0,"

# a leading zero is decimal, not octal
fresh
answer alpha 15 1 8 build=pending
answer alpha 15 2 0 build=pass
list 'o/alpha 15'
run_script "$stub_dir/list" 08; rc=$?
check "a deadline of 08 is 8 s: polled until green and merged" \
  [ "$rc" -eq 0 ] --and out_is "o/alpha #15 merged checks=[pass=1]" --and [ "$(polls o/alpha 15)" -eq 2 ]
fresh
answer alpha 15 1 8 build=pending
answer alpha 15 2 0 build=pass
list 'o/alpha 15'
POLL=08 run_script "$stub_dir/list"; rc=$?
check "a poll interval of 08 is 8 s" [ "$rc" -eq 0 ] --and sleeps_are "8,"

# a refused merge
fresh
answer alpha 8 1 0 build=pass
touch "$STUB_HOME/merge-fail-alpha-8"
list 'o/alpha 8'
run_script "$stub_dir/list"; rc=$?
check "a refused merge is MERGE-FAILED with the tally, exit 1, gh's words on stderr" \
  [ "$rc" -eq 1 ] --and out_is "o/alpha #8 MERGE-FAILED checks=[pass=1]" --and err_has "not mergeable"

# a list: URL and number forms, trailing fields ignored, blank lines skipped,
# one line per pull, and a pull that is not merged does not stop the rest
fresh
answer alpha 9 1 0 build=pass
answer beta 10 1 1 build=fail
answer gamma 11 1 0 build=pass lint=pass
list 'o/alpha https://github.com/o/alpha/pull/9 commit=abc1234' '' 'o/beta 10' 'o/gamma 11'
run_script "$stub_dir/list"; rc=$?
check "glyph-config-drop.sh's stdout is a list as it stands: one line per pull, in order" \
  out_is "o/alpha #9 merged checks=[pass=1]
o/beta #10 NOT merged rc=1 bad=[build=fail]
o/gamma #11 merged checks=[pass=2]"
check "…the rest still merge after one is held back, and the run exits 1" \
  [ "$rc" -eq 1 ] --and [ "$(merges)" -eq 2 ]

# a list whose last line has no newline
fresh
answer alpha 16 1 0 build=pass
answer beta 17 1 0 build=pass
printf 'o/alpha 16\no/beta 17' > "$stub_dir/list"
run_script "$stub_dir/list"; rc=$?
check "a last line with no newline is still polled, merged and reported" \
  [ "$rc" -eq 0 ] --and out_is "o/alpha #16 merged checks=[pass=1]
o/beta #17 merged checks=[pass=1]" --and [ "$(polls o/beta 17)" -eq 1 ]

echo
if [ "$fails" -gt 0 ]; then
  echo "$fails merge-when-green case(s) failed"
  exit 1
fi
echo "all merge-when-green cases passed"
