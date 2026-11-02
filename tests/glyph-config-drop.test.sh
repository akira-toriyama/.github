#!/usr/bin/env bash
# Table-test scripts/glyph-config-drop.sh — the writer that opens one pull
# request dropping one exact line from a repository's glyph.toml. Runs the REAL
# script (drift-free) against a stubbed `gh` on PATH and a stubbed GLYPH, the
# glyph-pin-land.test.sh pattern. Needs bash + jq; no network, no glyph.
#
# What a live run cannot show and these cases pin: the line is matched as
# written (zero or two matches, a regex-alike, a backslash or a numeric-looking
# line, is no guess); a rewrite that would touch a second line is refused; the
# message AND its first line are linted under the old and the new file, and a
# refusal under either — an unlandable warning at exit 0 included — writes
# nothing; --dry and an existing branch write nothing; every API failure exits
# 1, never 3, and writes nothing after it; and the happy path is exactly three
# writes, in order, on the tip the file was read from.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
script="$root/scripts/glyph-config-drop.sh"
fails=0

[ -f "$script" ] || { echo "FAIL - $script is missing"; exit 1; }

stub_dir="$(mktemp -d)"
trap 'rm -rf "$stub_dir"' EXIT

# A `gh` that answers repo o/r from files under $STUB_HOME and appends every
# call to $STUB_HOME/calls.log (`api <verb> <path> <field names>` or
# `pr create <repo> base=<b> head=<h>`); each -f value lands in
# $STUB_HOME/field-<verb>-<name>:
#   glyph.toml     the default branch's file; absent = the contents read 404s
#   branch-exists  present = the pull branch's ref answers 200
#   repo-fail, contents-error, ref-error, put-fail, pr-fail
#                  present = that call fails with an error other than a 404
#                  (the repository read, the glyph.toml read, the branch
#                  probe, the PUT, `pr create`)
# The tip is tip0123456789, the blob blob-old, the new commit commit-new.
cat >"$stub_dir/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
cmd="${1:-}"; shift
case "$cmd" in
  api)
    verb=GET; path=""; jqexpr=""; names=""; n=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -X) verb="$2"; shift 2 ;;
        -f|-F) n=$((n + 1)); printf '%s' "$2" > "$STUB_HOME/arg-$n"; shift 2 ;;
        --jq) jqexpr="$2"; shift 2 ;;
        -*) shift ;;
        *) [ -n "$path" ] || path="$1"; shift ;;
      esac
    done
    i=1
    while [ "$i" -le "$n" ]; do
      kv="$(cat "$STUB_HOME/arg-$i")"
      names="$names ${kv%%=*}"
      printf '%s' "${kv#*=}" > "$STUB_HOME/field-$verb-${kv%%=*}"
      i=$((i + 1))
    done
    printf 'api %s %s%s\n' "$verb" "$path" "$names" >> "$STUB_HOME/calls.log"
    emit() { if [ -n "$jqexpr" ]; then printf '%s' "$1" | jq -r "$jqexpr"; else printf '%s\n' "$1"; fi; }
    case "$verb $path" in
      "GET repos/o/r")
        [ ! -e "$STUB_HOME/repo-fail" ] || { echo "gh: Server Error (HTTP 500)" >&2; exit 1; }
        emit '{"default_branch":"main"}' ;;
      "GET repos/o/r/git/ref/heads/main") emit '{"object":{"sha":"tip0123456789"}}' ;;
      "GET repos/o/r/contents/glyph.toml?ref=tip0123456789")
        [ ! -e "$STUB_HOME/contents-error" ] || { echo "gh: Bad Gateway (HTTP 502)" >&2; exit 1; }
        [ -e "$STUB_HOME/glyph.toml" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
        # wrapped at 60 columns, as the Contents API sends it
        emit "$(jq -n --arg c "$(base64 < "$STUB_HOME/glyph.toml" | tr -d '\n' | fold -w 60)" '{sha: "blob-old", content: $c}')" ;;
      "GET repos/o/r/git/ref/heads/config/drop-style")
        [ ! -e "$STUB_HOME/ref-error" ] || { echo "gh: Bad credentials (HTTP 401)" >&2; exit 1; }
        if [ -e "$STUB_HOME/branch-exists" ]; then emit '{"object":{"sha":"someone-else"}}'
        else echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi ;;
      "POST repos/o/r/git/refs") emit '{"ref":"refs/heads/config/drop-style"}' ;;
      "PUT repos/o/r/contents/glyph.toml")
        [ ! -e "$STUB_HOME/put-fail" ] || { echo "gh: glyph.toml does not match blob-old (HTTP 409)" >&2; exit 1; }
        emit '{"commit":{"sha":"commit-new"}}' ;;
      *) echo "stub gh: unhandled api $verb $path" >&2; exit 64 ;;
    esac ;;
  pr)
    sub="${1:-}"; shift
    [ "$sub" = "create" ] || { echo "stub gh: unhandled pr $sub" >&2; exit 64; }
    repo=""; base=""; head=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --repo) repo="$2"; shift 2 ;;
        --base) base="$2"; shift 2 ;;
        --head) head="$2"; shift 2 ;;
        --title) printf '%s' "$2" > "$STUB_HOME/pr-title"; shift 2 ;;
        --body-file) cp "$2" "$STUB_HOME/pr-body"; shift 2 ;;
        *) echo "stub gh: unhandled pr create flag $1" >&2; exit 64 ;;
      esac
    done
    printf 'pr create %s base=%s head=%s\n' "$repo" "$base" "$head" >> "$STUB_HOME/calls.log"
    [ ! -e "$STUB_HOME/pr-fail" ] || { echo "pull request create failed: GraphQL: Something went wrong (createPullRequest)" >&2; exit 1; }
    echo "https://github.com/$repo/pull/7" ;;
  *) echo "stub gh: unhandled command $cmd" >&2; exit 64 ;;
esac
STUB
chmod +x "$stub_dir/gh"

# A glyph that answers `lint --stdin` only — inside a git repository with a
# glyph.toml, with no global or system git config visible — and appends
# `<old|new> <stdin line count>` to $STUB_HOME/glyph.log — old being the file
# that still holds the dropped line. Exit 3 when $STUB_HOME/refuse-<old|new>
# exists, or for a one-line message when $STUB_HOME/refuse-title does. Exit 0
# with glyph's unlandable warning on stderr (its shape measured on glyph
# 46909b3) when $STUB_HOME/unlandable-<old|new> exists, or for a one-line
# message when $STUB_HOME/unlandable-title does.
cat >"$stub_dir/glyph" <<'STUB'
#!/usr/bin/env bash
[ "${1:-} ${2:-}" = "lint --stdin" ] || { echo "stub glyph: unhandled $*" >&2; exit 64; }
[ -d .git ] || { echo "stub glyph: not inside a git repository" >&2; exit 2; }
[ "${GIT_CONFIG_GLOBAL:-}" = /dev/null ] && [ "${GIT_CONFIG_SYSTEM:-}" = /dev/null ] \
  || { echo "stub glyph: the operator's git config is visible" >&2; exit 2; }
[ -f glyph.toml ] || { echo "stub glyph: no glyph.toml" >&2; exit 2; }
if grep -qxF -- "$(cat "$STUB_HOME/dropped")" glyph.toml; then kind=old; else kind=new; fi
lines="$(wc -l | tr -d ' ')"
echo "$kind $lines" >> "$STUB_HOME/glyph.log"
[ -e "$STUB_HOME/refuse-$kind" ] && { echo "stub glyph: refused under $kind" >&2; exit 3; }
[ "$lines" -eq 1 ] && [ -e "$STUB_HOME/refuse-title" ] && { echo "stub glyph: title refused" >&2; exit 3; }
if [ -e "$STUB_HOME/unlandable-$kind" ] || { [ "$lines" -eq 1 ] && [ -e "$STUB_HOME/unlandable-title" ]; }; then
  echo "::warning::glyph: patterns[3] marks this message unlandable: fold it first — the commit-msg hook lets it through, but every gate that judges an existing commit refuses it (lint --range, a push to the default branch, --pr, the release walk)" >&2
fi
exit 0
STUB
chmod +x "$stub_dir/glyph"

style='style = "gemoji"'
msg_file="$stub_dir/commit.txt"
body_file="$stub_dir/pr-body.md"
printf ':wrench:(config)= drop [commit] style from glyph.toml\n\nglyph never read the key.\n' > "$msg_file"
printf 'Drops one line.\n' > "$body_file"

# fresh [dropped-line] — reset the stub world: glyph.toml holds the line once.
fresh() {
  export STUB_HOME="$stub_dir/home"
  rm -rf "$STUB_HOME"; mkdir -p "$STUB_HOME"
  : > "$STUB_HOME/calls.log"; : > "$STUB_HOME/glyph.log"
  printf '%s\n' "${1:-$style}" > "$STUB_HOME/dropped"
  printf 'schema = 1\n\n[commit]\n%s\ntemplate = "x"\n' "${1:-$style}" > "$STUB_HOME/glyph.toml"
}

run_script() { GLYPH="$stub_dir/glyph" PATH="$stub_dir:$PATH" bash "$script" "$@" >"$stub_dir/out" 2>"$stub_dir/err"; }
drop() { run_script o/r "${1:-$style}" config/drop-style "$msg_file" "$body_file" ${2:+"$2"}; }

out_is() { [ "$(cat "$stub_dir/out")" = "$1" ]; }
err_has() { grep -qF -- "$1" "$stub_dir/err"; }
writes() { grep -cE '^(api (POST|PUT|PATCH|DELETE)|pr create)' "$STUB_HOME/calls.log"; }
glyph_log_is() { [ "$(tr '\n' ',' < "$STUB_HOME/glyph.log")" = "$1" ]; }
put_content_is() { [ "$(base64 -d < "$STUB_HOME/field-PUT-content")" = "$1" ]; }

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
    sed 's/^/         glyph:  /' "$STUB_HOME/glyph.log" 2>/dev/null
    fails=$((fails + 1))
  fi
}

# usage
fresh
run_script; rc=$?
check "no arguments is usage (exit 2)" [ "$rc" -eq 2 ]
run_script o/r "$style" config/drop-style "$msg_file"; rc=$?
check "four arguments is usage (exit 2)" [ "$rc" -eq 2 ]
drop "$style" --apply; rc=$?
check "a sixth argument other than --dry is usage (exit 2)" [ "$rc" -eq 2 ]
PATH="$stub_dir:$PATH" GLYPH='' bash "$script" o/r "$style" config/drop-style "$msg_file" "$body_file" >"$stub_dir/out" 2>"$stub_dir/err"; rc=$?
check "an unset GLYPH is usage (exit 2) and calls nothing" \
  [ "$rc" -eq 2 ] --and [ ! -s "$STUB_HOME/calls.log" ]

# the happy path: three writes, in order, on the tip the file was read from
fresh
drop; rc=$?
check "the pull is opened: exit 0 and the line merge-when-green reads" \
  [ "$rc" -eq 0 ] --and out_is "o/r https://github.com/o/r/pull/7 commit=commit-new"
check "glyph.toml is read at the tip sha, not the branch name" \
  grep -qx 'api GET repos/o/r/contents/glyph.toml?ref=tip0123456789' "$STUB_HOME/calls.log"
check "exactly three writes, in order: ref, file, pull request" \
  [ "$(grep -E '^(api (POST|PUT|PATCH|DELETE)|pr create)' "$STUB_HOME/calls.log" | tr '\n' ',')" = \
    "api POST repos/o/r/git/refs ref sha,api PUT repos/o/r/contents/glyph.toml message content sha branch,pr create o/r base=main head=config/drop-style," ]
check "the branch is created on the tip" \
  [ "$(cat "$STUB_HOME/field-POST-ref")" = "refs/heads/config/drop-style" ] --and [ "$(cat "$STUB_HOME/field-POST-sha")" = "tip0123456789" ]
printf 'schema = 1\n\n[commit]\ntemplate = "x"\n' > "$stub_dir/want.toml"
check "the PUT carries the file minus that one line, on the read blob and the new branch" \
  put_content_is "$(cat "$stub_dir/want.toml")" --and [ "$(cat "$STUB_HOME/field-PUT-sha")" = "blob-old" ] --and [ "$(cat "$STUB_HOME/field-PUT-branch")" = "config/drop-style" ]
check "the commit message is the message file" \
  [ "$(cat "$STUB_HOME/field-PUT-message")" = "$(cat "$msg_file")" ]
check "the pull request's title is the message's first line, its body the body file" \
  [ "$(cat "$STUB_HOME/pr-title")" = ":wrench:(config)= drop [commit] style from glyph.toml" ] --and cmp -s "$STUB_HOME/pr-body" "$body_file"
check "the message and the title are linted under the old file, then the new" \
  glyph_log_is "old 3,old 1,new 3,new 1,"

# --dry: every check runs, nothing is written
fresh
drop "$style" --dry; rc=$?
check "--dry answers dry ok with the branch and the tip it would start on" \
  [ "$rc" -eq 0 ] --and out_is "o/r dry ok config/drop-style@tip0123"
check "…and writes nothing (no POST, PUT or pull request), having linted both files" \
  [ "$(writes)" -eq 0 ] --and glyph_log_is "old 3,old 1,new 3,new 1,"

# the line count: zero, two, near misses — skipped (3) before any lint or write
fresh
printf 'schema = 1\n[commit]\n  %s\n%s \n' "$style" "$style" > "$STUB_HOME/glyph.toml"
drop; rc=$?
check "an indented or trailing-space copy is not the line: 0 matches, exit 3" \
  [ "$rc" -eq 3 ] --and err_has "holds the line 0 time(s)"
check "…and nothing is linted or written" \
  [ "$(writes)" -eq 0 ] --and [ ! -s "$STUB_HOME/glyph.log" ]
fresh
printf 'schema = 1\n[commit]\n%s\n[note]\n%s\n' "$style" "$style" > "$STUB_HOME/glyph.toml"
drop; rc=$?
check "two copies of the line are ambiguous: exit 3, the count named, nothing written" \
  [ "$rc" -eq 3 ] --and err_has "holds the line 2 time(s)" --and [ "$(writes)" -eq 0 ]

# the line is matched as written, not as a pattern
fresh 'a.b = 1'
printf 'axb = 1\na.b = 1\n' > "$STUB_HOME/glyph.toml"
drop 'a.b = 1'; rc=$?
check "a regex-alike line matches only itself (axb = 1 stays)" \
  [ "$rc" -eq 0 ] --and put_content_is "axb = 1"
backslash='p = '"'"'a\tb'"'"
fresh "$backslash"
printf '%s\n' "$backslash" 'q = 2' > "$STUB_HOME/glyph.toml"
drop "$backslash"; rc=$?
check "a backslash in the line is matched as written" \
  [ "$rc" -eq 0 ] --and put_content_is "q = 2"

# a numeric-looking line is compared as a string, not as a number
fresh 2
printf 'schema = 1\n  2\n2.0\n+2\n' > "$STUB_HOME/glyph.toml"
drop 2; rc=$?
check "2 matches none of '  2', '2.0', '+2': 0 matches, exit 3, nothing written" \
  [ "$rc" -eq 3 ] --and err_has "holds the line 0 time(s)" --and [ "$(writes)" -eq 0 ]
fresh 2
printf 'schema = 1\n  2\n2\n' > "$STUB_HOME/glyph.toml"
drop 2; rc=$?
check "…and beside '  2' it drops only the line written 2" \
  [ "$rc" -eq 0 ] --and put_content_is "$(printf 'schema = 1\n  2')"

# a rewrite that would touch a second line is refused
fresh
printf 'schema = 1\n%s\ntemplate = "x"' "$style" > "$STUB_HOME/glyph.toml"
drop; rc=$?
check "a last line without a newline would change too: exit 3, nothing written" \
  [ "$rc" -eq 3 ] --and err_has "changes 3 line(s), not one" --and [ "$(writes)" -eq 0 ]

# no glyph.toml at all
fresh
rm "$STUB_HOME/glyph.toml"
drop; rc=$?
check "a default branch with no glyph.toml is skipped (exit 3)" \
  [ "$rc" -eq 3 ] --and err_has "no glyph.toml" --and [ "$(writes)" -eq 0 ]

# the lint refusals: each config, and the title on its own
fresh
touch "$STUB_HOME/refuse-old"
drop; rc=$?
check "a message the OLD file refuses: exit 4, the old file named, nothing written" \
  [ "$rc" -eq 4 ] --and err_has "message fails lint under the old glyph.toml (exit 3)" --and [ "$(writes)" -eq 0 ]
check "…and nothing is linted after the first refusal" glyph_log_is "old 3,"
fresh
touch "$STUB_HOME/refuse-new"
drop; rc=$?
check "a message only the NEW file refuses: exit 4, the new file named, nothing written" \
  [ "$rc" -eq 4 ] --and err_has "message fails lint under the new glyph.toml (exit 3)" --and [ "$(writes)" -eq 0 ]
check "…after the old file passed both lints" glyph_log_is "old 3,old 1,new 3,"
fresh
touch "$STUB_HOME/refuse-title"
drop; rc=$?
check "a title the file refuses on its own: exit 4, nothing written" \
  [ "$rc" -eq 4 ] --and err_has "title fails lint under the old glyph.toml" --and [ "$(writes)" -eq 0 ]

# lint --stdin passes an unlandable message at exit 0 with a warning; every
# gate that judges a commit refuses it, so the warning is a refusal here
fresh
touch "$STUB_HOME/unlandable-new"
drop; rc=$?
check "a message the NEW file lints only as unlandable (exit 0 + warning): exit 4, named, nothing written" \
  [ "$rc" -eq 4 ] --and err_has "message lints only as unlandable under the new glyph.toml" --and [ "$(writes)" -eq 0 ]
fresh
touch "$STUB_HOME/unlandable-title"
drop; rc=$?
check "a title the OLD file lints only as unlandable: exit 4, named, nothing written" \
  [ "$rc" -eq 4 ] --and err_has "title lints only as unlandable under the old glyph.toml" --and [ "$(writes)" -eq 0 ]

# an existing branch is reported, never forced — in --dry too
fresh
touch "$STUB_HOME/branch-exists"
drop; rc=$?
check "an existing branch exits 1 and says so" \
  [ "$rc" -eq 1 ] --and err_has "already exists"
check "…and nothing is written (no ref move, no PUT, no pull request)" [ "$(writes)" -eq 0 ]
fresh
touch "$STUB_HOME/branch-exists"
drop "$style" --dry; rc=$?
check "--dry reports the existing branch as well (exit 1)" \
  [ "$rc" -eq 1 ] --and [ "$(writes)" -eq 0 ]

# every API failure exits 1 — never 3, which would read as nothing to drop —
# and writes nothing after it
fresh
touch "$STUB_HOME/repo-fail"
drop; rc=$?
check "a repository read that fails exits 1, before any other call" \
  [ "$rc" -eq 1 ] --and err_has "cannot read the default branch" --and [ "$(grep -c . "$STUB_HOME/calls.log")" -eq 1 ]
fresh
touch "$STUB_HOME/contents-error"
drop; rc=$?
check "a glyph.toml read that fails other than 404 exits 1, not 3, with gh's words" \
  [ "$rc" -eq 1 ] --and err_has "cannot read glyph.toml" --and err_has "HTTP 502" --and [ "$(writes)" -eq 0 ] --and [ ! -s "$STUB_HOME/glyph.log" ]
fresh
touch "$STUB_HOME/ref-error"
drop; rc=$?
check "a branch probe that fails other than 404 exits 1 — it is not a free branch" \
  [ "$rc" -eq 1 ] --and err_has "cannot tell whether config/drop-style exists" --and [ "$(writes)" -eq 0 ]
fresh
touch "$STUB_HOME/put-fail"
drop; rc=$?
check "a refused PUT exits 1, names the branch it leaves behind, opens no pull" \
  [ "$rc" -eq 1 ] --and err_has "cannot commit glyph.toml on config/drop-style" --and [ "$(grep -c '^pr create' "$STUB_HOME/calls.log")" -eq 0 ] --and [ ! -s "$stub_dir/out" ]
fresh
touch "$STUB_HOME/pr-fail"
drop; rc=$?
check "a refused pull request exits 1 and names the branch and its commit" \
  [ "$rc" -eq 1 ] --and err_has "config/drop-style carries commit-new" --and [ ! -s "$stub_dir/out" ]

echo
if [ "$fails" -gt 0 ]; then
  echo "$fails glyph-config-drop case(s) failed"
  exit 1
fi
echo "all glyph-config-drop cases passed"
