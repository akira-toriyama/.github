#!/usr/bin/env bash
# Table-test scripts/fleet-commit-bundle.sh — the writer that lands a repo's
# whole manifest diff as ONE push. Runs the REAL script (drift-free) against a
# stubbed `gh` on PATH, the apply-repo-settings.test.sh pattern. Needs bash +
# jq only.
#
# The property under test is the one t-z7c1 exists for: however many files
# changed, the default branch receives exactly ONE ref update — because every
# extra push is an extra release run, and stacked release runs across the
# fleet's fan-out window are what collided in bare 403s. The stub therefore
# RECORDS every mutating call, and the cases assert on the recording, not just
# the exit code.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
script="$root/scripts/fleet-commit-bundle.sh"
fails=0

[ -f "$script" ] || { echo "FAIL - $script is missing"; exit 1; }

stub_dir="$(mktemp -d)"
trap 'rm -rf "$stub_dir"' EXIT

# A `gh` that answers the Git Data API from files under $STUB_HOME and appends
# every call to $STUB_HOME/calls.log:
#   $STUB_HOME/tip              sha returned for GET git/ref (one line; a second
#                               line, if present, is returned on the NEXT read —
#                               simulating a branch that moved mid-bundle)
#   $STUB_HOME/refuse-patch     present = PATCH git/refs fails
#   $STUB_HOME/refuse-patch-once  present = only the FIRST PATCH fails
#   $STUB_HOME/fail-blobs       present = POST git/blobs fails
cat >"$stub_dir/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
[ "${1:-}" = "api" ] || { echo "stub gh: unhandled command: $*" >&2; exit 64; }
shift
verb=GET; path=""; jqexpr=""; input=""; declare -a fields=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -X) verb="$2"; shift 2 ;;
    -f) fields+=("$2"); shift 2 ;;
    --jq) jqexpr="$2"; shift 2 ;;
    --input) input="$2"; shift 2 ;;
    -*) shift ;;
    *) [ -n "$path" ] || path="$1"; shift ;;
  esac
done
printf '%s %s\n' "$verb" "$path" >> "$STUB_HOME/calls.log"
emit() { if [ -n "$jqexpr" ]; then printf '%s' "$1" | jq -r "$jqexpr"; else printf '%s\n' "$1"; fi; }
case "$verb $path" in
  "GET "*/git/ref/heads/*)
    reads="$STUB_HOME/ref-reads"
    n="$(cat "$reads" 2>/dev/null || echo 0)"; n=$((n + 1)); printf '%s' "$n" > "$reads"
    sha="$(sed -n "${n}p" "$STUB_HOME/tip")"
    [ -n "$sha" ] || sha="$(tail -1 "$STUB_HOME/tip")"
    emit "{\"object\":{\"sha\":\"$sha\"}}" ;;
  "GET "*/git/commits/*)
    emit '{"tree":{"sha":"tree-of-base"}}' ;;
  "POST "*/git/blobs)
    [ -e "$STUB_HOME/fail-blobs" ] && { echo "HTTP 500" >&2; exit 1; }
    n="$(grep -c 'POST .*git/blobs' "$STUB_HOME/calls.log")"
    emit "{\"sha\":\"blob-$n\"}" ;;
  "POST "*/git/trees)
    cp "$input" "$STUB_HOME/tree-payload.json"
    emit '{"sha":"tree-new"}' ;;
  "POST "*/git/commits)
    cp "$input" "$STUB_HOME/commit-payload.json"
    n="$(grep -c 'POST .*git/commits' "$STUB_HOME/calls.log")"
    emit "{\"sha\":\"commit-$n\"}" ;;
  "PATCH "*/git/refs/heads/*)
    if [ -e "$STUB_HOME/refuse-patch" ]; then echo "HTTP 422" >&2; exit 1; fi
    if [ -e "$STUB_HOME/refuse-patch-once" ]; then rm -f "$STUB_HOME/refuse-patch-once"; echo "HTTP 422" >&2; exit 1; fi
    exit 0 ;;
  *) echo "stub gh: unhandled $verb $path" >&2; exit 64 ;;
esac
STUB
chmod +x "$stub_dir/gh"

# fresh <tip-lines...> — reset the stub world and the two source files.
fresh() {
  export STUB_HOME="$stub_dir/home"
  rm -rf "$STUB_HOME"; mkdir -p "$STUB_HOME"
  printf '%s\n' "$@" > "$STUB_HOME/tip"
  : > "$STUB_HOME/calls.log"
  printf 'canonical one\n' > "$stub_dir/one.yml"
  printf 'canonical two\n' > "$stub_dir/two.md"
}

run_script() { PATH="$stub_dir:$PATH" bash "$script" "$@" 2>"$stub_dir/err"; }

jqe() { jq -e "$1" "$2" >/dev/null; }

check() { # check <name> <condition...>
  local name="$1"; shift
  if "$@"; then echo "ok   - $name"; else
    echo "FAIL - $name"
    sed 's/^/         stderr: /' "$stub_dir/err"
    sed 's/^/         calls:  /' "$STUB_HOME/calls.log" 2>/dev/null
    fails=$((fails + 1))
  fi
}

# ---- two files, one push — the property this file exists for ---------------
fresh base-1
out="$(run_script o/r main "$stub_dir/one.yml:.github/workflows/one.yml" "$stub_dir/two.md:docs/two.md")"; rc=$?
check "two files exit 0 and report the bundle" \
  [ "$rc" -eq 0 -a "$out" = "bundled 2 commit-1" ]
check "exactly ONE ref update for two files" \
  [ "$(grep -c '^PATCH .*git/refs' "$STUB_HOME/calls.log")" -eq 1 ]
check "exactly ONE commit for two files" \
  [ "$(grep -c '^POST .*git/commits$' "$STUB_HOME/calls.log")" -eq 1 ]
check "the tree carries both paths on the base tree" \
  jqe '.base_tree == "tree-of-base"
         and (.tree | map(.path) == [".github/workflows/one.yml", "docs/two.md"])
         and (.tree | all(.mode == "100644"))' "$STUB_HOME/tree-payload.json"
check "the commit is authored by fleet-sync[bot] on the read base" \
  jqe '.author.name == "fleet-sync[bot]"
         and .author.email == "fleet-sync[bot]@users.noreply.github.com"
         and .parents == ["base-1"]' "$STUB_HOME/commit-payload.json"
# NB: the script builds the message in a $( ) substitution, which strips the
# trailing newline — harmless in a commit message, pinned here so it is a
# choice and not an accident.
check "the multi-file message says how many and lists them" \
  jqe '.message == ":robot: chore(fleet): sync 2 standard files in one push\n\n.github/workflows/one.yml\ndocs/two.md"' \
  "$STUB_HOME/commit-payload.json"

# ---- one file keeps the historical message, byte for byte ------------------
fresh base-1
out="$(run_script o/r main "$stub_dir/one.yml:.github/workflows/one.yml")"; rc=$?
check "single file exits 0" [ "$rc" -eq 0 ]
check "single-file message is the Contents-API form exactly" \
  jqe '.message == ":robot: chore(fleet): sync .github/workflows/one.yml"' \
  "$STUB_HOME/commit-payload.json"

# ---- a refused update with an unmoved tip is the PR-fallback verdict -------
fresh base-1
touch "$STUB_HOME/refuse-patch"
out="$(run_script o/r main "$stub_dir/one.yml:.github/workflows/one.yml")"; rc=$?
check "protected branch exits 3, not 1" [ "$rc" -eq 3 ]
check "protection is not retried as if it were a race" \
  [ "$(grep -c '^PATCH .*git/refs' "$STUB_HOME/calls.log")" -eq 1 ]

# ---- a refused update with a MOVED tip is a race: rebuild once and land ----
fresh base-1 base-2
touch "$STUB_HOME/refuse-patch-once"
out="$(run_script o/r main "$stub_dir/one.yml:.github/workflows/one.yml")"; rc=$?
check "race rebuilds on the new tip and exits 0" [ "$rc" -eq 0 ]
check "the second commit's parent is the moved tip" \
  jqe '.parents == ["base-2"]' "$STUB_HOME/commit-payload.json"

# ---- API failures are exit 1 (counted failed), never a silent pass ---------
fresh base-1
touch "$STUB_HOME/fail-blobs"
out="$(run_script o/r main "$stub_dir/one.yml:.github/workflows/one.yml")"; rc=$?
check "a blob failure exits 1" [ "$rc" -eq 1 ]
check "nothing was committed after a blob failure" \
  [ "$(grep -c '^POST .*git/commits$' "$STUB_HOME/calls.log")" -eq 0 ]

# ---- a missing source file must not commit a partial bundle ----------------
fresh base-1
out="$(run_script o/r main "$stub_dir/one.yml:.github/workflows/one.yml" "$stub_dir/absent.yml:docs/two.md")"; rc=$?
check "a missing src exits 1 before any commit" \
  [ "$rc" -eq 1 -a "$(grep -c '^POST .*git/commits$' "$STUB_HOME/calls.log")" -eq 0 ]

# ---- usage guard -----------------------------------------------------------
if run_script o/r main >/dev/null; then
  echo "FAIL - no pairs must refuse with usage"; fails=$((fails + 1))
else
  echo "ok   - no pairs refuses with usage"
fi

if [ "$fails" -gt 0 ]; then
  echo "$fails case(s) failed"
  exit 1
fi
echo "all cases passed"
