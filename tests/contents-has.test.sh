#!/usr/bin/env bash
# Table-test scripts/contents-has.sh — the answer fleet-sync's prune, its tap
# secret gate and fleet-repin act on. On 2026-11-24 the inline form of this
# question deleted glyph's pr-verdict.yml reusable from main (the script's
# header has the mechanism). Runs the REAL script; self-test.yml invokes this.
# Needs bash + base64 + grep only.
#
# The last two sections are the point of the file:
#   - a CONTROL that runs the old inline shape on an input built so the writer
#     cannot finish before grep exits, and requires it to misread — if the
#     control ever passes, the input stopped exercising the hazard and every
#     "ok" above it proves nothing;
#   - a scan that no hub workflow or script pipes a base64 decode into
#     `grep -q` again, with its own canary line.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
script="$root/scripts/contents-has.sh"
fails=0

ok() { echo "ok   - $1"; }
bad() {
  echo "FAIL - $1"
  shift
  for line in "$@"; do echo "       $line"; done
  fails=$((fails + 1))
}

[ -f "$script" ] || { echo "FAIL - $script is missing"; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# expect <name> <want-rc> <stdin-file> <args...>
expect() {
  local name="$1" want="$2" in="$3" rc=0
  shift 3
  bash "$script" "$@" < "$in" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq "$want" ]; then ok "$name"; else bad "$name" "exit $rc, want $want"; fi
}

printf 'name: verdict\non:\n  workflow_call:\n    inputs: {}\njobs: {}\n' | base64 > "$tmp/reusable.b64"
printf 'name: caller\non:\n  pull_request:\njobs:\n  v:\n    uses: o/r/.github/workflows/x.yml@v1\n' | base64 > "$tmp/caller.b64"
printf '  vendorHash = "sha256-AAAA";\n' | base64 > "$tmp/flake.b64"
: > "$tmp/empty"
printf '%s' '*** not base64 ***' > "$tmp/garbage"

# 1. The three answers, both match modes.
expect "a reusable holds workflow_call (0)" 0 "$tmp/reusable.b64" workflow_call
expect "a caller does not (1)" 1 "$tmp/caller.b64" workflow_call
expect "nothing on stdin is unknown (2)" 2 "$tmp/empty" workflow_call
expect "undecodable input is unknown (2)" 2 "$tmp/garbage" workflow_call
expect "-E matches a line by regex (0)" 0 "$tmp/flake.b64" -E '^[[:space:]]*vendorHash = '
expect "-E does not match elsewhere (1)" 1 "$tmp/caller.b64" -E '^[[:space:]]*vendorHash = '
expect "without -E the pattern is a fixed string (1)" 1 "$tmp/reusable.b64" 'workflow_c.ll'

# 2. The Contents API wraps base64 at 60 columns with newlines; a wrapped
#    reusable still decodes.
printf 'on:\n  workflow_call:\n%s\n' "$(printf '# %.0s' $(seq 400))" | base64 | fold -w 60 > "$tmp/wrapped.b64"
expect "newline-wrapped base64 decodes (0)" 0 "$tmp/wrapped.b64" workflow_call

# 3. The hazard input: the match in the first line, then 2 MB the writer still
#    has to push through a pipe (64 KiB on Linux, 16 KiB on macOS) when grep -q
#    has already left.
{
  printf 'on:\n  workflow_call:\n'
  head -c 2000000 /dev/zero | tr '\0' '#'
  printf '\n'
} > "$tmp/big.yml"
base64 < "$tmp/big.yml" > "$tmp/big.b64"

big_rc=0
(
  set -o pipefail
  for _ in 1 2 3 4 5; do
    base64 < "$tmp/big.yml" | bash "$script" workflow_call || exit 1
  done
) || big_rc=$?
if [ "$big_rc" -eq 0 ]; then
  ok "a 2 MB reusable read through a pipeline under pipefail is a reusable, 5 of 5"
else
  bad "a 2 MB reusable read through a pipeline under pipefail is a reusable, 5 of 5" \
    "the script answered non-zero at least once — the prune would delete a reusable"
fi

# 4. CONTROL: the shape the script replaced misreads that same input.
old_rc=0
(
  set -o pipefail
  base64 -d < "$tmp/big.b64" 2>/dev/null | grep -q "workflow_call"
) || old_rc=$?
if [ "$old_rc" -ne 0 ]; then
  ok "control: the old inline shape misreads the same input (pipeline exit $old_rc)"
else
  bad "control: the old inline shape misreads the same input" \
    "\`base64 -d | grep -q\` under pipefail exited 0 on the 2 MB reusable" \
    "the input no longer exercises the SIGPIPE hazard, so section 3 proves nothing — make it larger"
fi

# 5. No hub workflow, action or script pipes a decode into `grep -q` again.
#    A logical line may be continued with a backslash; join those first.
decode_into_grep_q() { # prints file:line for each offending logical line
  awk '
    FNR == 1 { buf = ""; start = 0 }
    {
      line = $0
      if (buf == "") start = FNR
      if (line ~ /\\$/) { sub(/\\$/, "", line); buf = buf line; next }
      buf = buf line
      if (buf !~ /^[[:space:]]*#/ && buf ~ /base64[[:space:]]+(-d|-D|--decode)[^|]*\|[^|]*grep[[:space:]]+(-[A-Za-z]*q|--quiet)/) print FILENAME ":" start
      buf = ""
    }' "$@"
}

# shellcheck disable=SC2016,SC1003  # literal shell text: the scan's input, not code
{
  printf '%s\n' '  if printf "%s" "$c" | base64 -d 2>/dev/null | grep -q "workflow_call"; then' > "$tmp/canary.sh"
  printf '%s\n' '  if printf "%s" "$c" | base64 -d 2>/dev/null \' '      | grep -qE "x"; then' > "$tmp/canary-continued.sh"
}
if [ -n "$(decode_into_grep_q "$tmp/canary.sh")" ] && [ -n "$(decode_into_grep_q "$tmp/canary-continued.sh")" ]; then
  ok "canary: the scan sees the old shape, on one line and continued"
else
  bad "canary: the scan sees the old shape, on one line and continued" \
    "the pattern below no longer matches a real instance — a clean scan would mean nothing"
fi

targets=()
while IFS= read -r f; do targets+=("$f"); done < <(
  find "$root/.github/workflows" "$root/fleet" "$root/scripts" "$root/actions" \
    -type f \( -name '*.yml' -o -name '*.yaml' -o -name '*.sh' \) | sort
)
if [ "${#targets[@]}" -lt 10 ]; then
  bad "the scan found the hub's workflows and scripts" "only ${#targets[@]} file(s) under .github/workflows, fleet, scripts, actions"
else
  hits="$(decode_into_grep_q "${targets[@]}")"
  if [ -z "$hits" ]; then
    ok "no workflow, action or script pipes a base64 decode into grep -q (${#targets[@]} files)"
  else
    # shellcheck disable=SC2086  # one finding per argument
    bad "no workflow, action or script pipes a base64 decode into grep -q" $hits \
      "under pipefail a match there reads as a miss — ask scripts/contents-has.sh instead"
  fi
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "contents-has: all checks passed"
else
  echo "contents-has: $fails check(s) failed"
  exit 1
fi
