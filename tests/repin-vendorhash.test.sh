#!/usr/bin/env bash
# Table-test fleet/repin-vendorhash.sh — the canonical vendorHash re-pin ritual
# fleet-sync distributes to every repo with a root flake.nix, and the step
# fleet-repin runs on each dependabot gomod branch. Runs the REAL canonical
# (copied to scripts/ in a throwaway repo, the path it is synced to) against a
# stubbed `nix` on PATH. Needs bash only.
#
# What a live run cannot show and these cases pin: a matching stamp is a no-op
# with no nix call; a stale or absent stamp derives the hash and refreshes the
# stamp exactly where one exists; every failure (nix absent, no `got:`, the
# verifying build red, an ambiguous flake) leaves flake.nix BYTE-IDENTICAL — a
# fakeHash is never left behind.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
canonical="$root/fleet/repin-vendorhash.sh"
fails=0

[ -f "$canonical" ] || { echo "FAIL - $canonical is missing"; exit 1; }

stub_dir="$(mktemp -d)"
trap 'rm -rf "$stub_dir"' EXIT

# A `nix` that reads flake.nix in the cwd and appends every call to
# $STUB_HOME/calls.log:
#   got          the hash the fakeHash probe "got" (the real-hash report)
#   no-got       present = the probe fails WITHOUT a got: line (eval error)
#   final-fail   present = a build against a real hash fails
cat >"$stub_dir/nix" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
echo "nix $*" >> "$STUB_HOME/calls.log"
if grep -q 'pkgs\.lib\.fakeHash' flake.nix; then
  [ -e "$STUB_HOME/no-got" ] && { echo "error: evaluation aborted with: no such package" >&2; exit 1; }
  printf 'error: hash mismatch in fixed-output derivation\n         specified: sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n            got:    %s\n' "$(cat "$STUB_HOME/got")" >&2
  exit 1
fi
[ -e "$STUB_HOME/final-fail" ] && { echo "error: builder for '/nix/store/x.drv' failed" >&2; exit 1; }
exit 0
STUB
chmod +x "$stub_dir/nix"

OLD='sha256-OLDOLDOLDOLDOLDOLDOLDOLDOLDOLDOLDOLDOLDOLDOLD='
NEW='sha256-NEWNEWNEWNEWNEWNEWNEWNEWNEWNEWNEWNEWNEWNEWNEW='
sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1; else sha256sum "$1" | cut -d' ' -f1; fi; }
printf 'golang.org/x/term v0.46.0 h1:abc=\n' > "$stub_dir/go.sum"
GOSUM_SHA="$(sha "$stub_dir/go.sum")"   # of the go.sum every fresh() writes

fresh() { # fresh [stamp] — a throwaway repo at $repo with the canonical under scripts/
  export STUB_HOME="$stub_dir/home"
  rm -rf "$STUB_HOME"; mkdir -p "$STUB_HOME"
  : > "$STUB_HOME/calls.log"; printf '%s' "$NEW" > "$STUB_HOME/got"
  repo="$stub_dir/repo"; rm -rf "$repo"; mkdir -p "$repo/scripts"
  cp "$canonical" "$repo/scripts/repin-vendorhash.sh"
  printf 'golang.org/x/term v0.46.0 h1:abc=\n' > "$repo/go.sum"
  flake "${1:-}"
}
flake() { # flake [stamp] [vendorHash-line] — write flake.nix; an empty stamp means no stamp line
  local stamp="${1:-}" vh="${2:-  vendorHash = \"$OLD\";}"
  {
    echo '{'
    echo '  # furrow — nix run'
    [ -z "$stamp" ] || echo "  # go.sum sha256: $stamp"
    echo '  outputs = { self, nixpkgs }: {'
    echo "$vh"
    echo '  };'
    echo '}'
  } > "$repo/flake.nix"
}
run_script() { (cd "$repo" && PATH="$stub_dir:$PATH" sh scripts/repin-vendorhash.sh "$@" >"$stub_dir/out" 2>"$stub_dir/err"); }
nix_calls() { grep -c '^nix' "$STUB_HOME/calls.log"; }
line() { grep -F -- "$1" "$stub_dir/out" >/dev/null; }
errline() { grep -F -- "$1" "$stub_dir/err" >/dev/null; }
hash_is() { grep -q "^  vendorHash = \"$1\";\$" "$repo/flake.nix"; }
stamp_is() { grep -q "^  # go\.sum sha256: $1\$" "$repo/flake.nix"; }
snapshot() { cp "$repo/flake.nix" "$stub_dir/before"; }
unchanged() { cmp -s "$stub_dir/before" "$repo/flake.nix"; }

check() { # check <name> <condition...>
  local name="$1"; shift
  if "$@"; then echo "ok   - $name"; else
    echo "FAIL - $name"
    sed 's/^/         stdout: /' "$stub_dir/out"
    sed 's/^/         stderr: /' "$stub_dir/err"
    sed 's/^/         calls:  /' "$STUB_HOME/calls.log" 2>/dev/null
    sed 's/^/         flake:  /' "$repo/flake.nix" 2>/dev/null
    fails=$((fails + 1))
  fi
}

# usage
fresh
run_script --bogus; rc=$?
check "an unknown flag is usage (exit 2)" [ "$rc" -eq 2 ]

# nothing to re-pin
fresh; rm "$repo/flake.nix"
run_script; rc=$?
check "no flake.nix is exit 1" [ "$rc" -eq 1 ]
check "…and says so" errline "no flake.nix at the repo root"
fresh; rm "$repo/go.sum"
run_script; rc=$?
check "no go.sum is exit 1" [ "$rc" -eq 1 ]

# ── the stamp shape (furrow): a matching stamp is a no-op ───────────────────
fresh "$GOSUM_SHA"
snapshot
run_script; rc=$?
check "a matching stamp exits 0" [ "$rc" -eq 0 ]
check "…without calling nix" [ "$(nix_calls)" -eq 0 ]
check "…and leaves flake.nix untouched" unchanged
check "…reporting the current pin" line "ok — flake.nix vendorHash stamp already matches go.sum ($OLD)"

# a stale stamp derives the hash and refreshes the stamp
fresh 0000000000000000000000000000000000000000000000000000000000000000
run_script; rc=$?
check "a stale stamp exits 0" [ "$rc" -eq 0 ]
check "…probes with fakeHash and verifies with the derived hash (two builds)" [ "$(nix_calls)" -eq 2 ]
check "…pins the got: hash" hash_is "$NEW"
check "…refreshes the stamp to go.sum's sha256" stamp_is "$(sha "$repo/go.sum")"
check "…and reports the move" line "re-pinned — vendorHash $OLD -> $NEW; stamp refreshed to go.sum $(sha "$repo/go.sum")"
check "…with no fakeHash left behind" [ "$(grep -c fakeHash "$repo/flake.nix")" -eq 0 ]

# --force re-derives even when the stamp matches
fresh "$GOSUM_SHA"
printf '%s' "$OLD" > "$STUB_HOME/got"
run_script --force; rc=$?
check "--force on a matching stamp exits 0" [ "$rc" -eq 0 ]
check "…and probes" [ "$(nix_calls)" -eq 2 ]
check "…reporting an unchanged hash" line "re-pinned — vendorHash unchanged ($OLD); stamp refreshed"

# a fakeHash left behind by an interrupted hand ritual is recovered
fresh 0000000000000000000000000000000000000000000000000000000000000000
flake 0000000000000000000000000000000000000000000000000000000000000000 '  vendorHash = pkgs.lib.fakeHash;'
run_script; rc=$?
check "a leftover fakeHash is re-pinned" [ "$rc" -eq 0 ]
check "…to the got: hash" hash_is "$NEW"
check "…reported from <none>" line "re-pinned — vendorHash <none> -> $NEW"

# ── the stamp-less shape (glyph, cifail, pare): always derive ───────────────
fresh
run_script; rc=$?
check "no stamp exits 0" [ "$rc" -eq 0 ]
check "…always probes" [ "$(nix_calls)" -eq 2 ]
check "…pins the got: hash" hash_is "$NEW"
check "…adds no stamp line" [ "$(grep -c 'go.sum sha256' "$repo/flake.nix")" -eq 0 ]
check "…and says there was none to refresh" line "re-pinned — vendorHash $OLD -> $NEW; no stamp line to refresh"

# ── every failure leaves flake.nix byte-identical ───────────────────────────
fresh
snapshot
( cd "$repo" && PATH="/usr/bin:/bin" sh scripts/repin-vendorhash.sh >"$stub_dir/out" 2>"$stub_dir/err" ); rc=$?
check "nix absent is exit 1" [ "$rc" -eq 1 ]
check "…named" errline "nix is not on PATH"
check "…flake.nix untouched" unchanged

fresh
: > "$STUB_HOME/no-got"
snapshot
run_script; rc=$?
check "a probe without a got: line is exit 1" [ "$rc" -eq 1 ]
check "…with nix's own words relayed" errline "evaluation aborted"
check "…named as untouched" errline "printed no 'got: sha256-…' — flake.nix left untouched"
check "…flake.nix byte-identical (no fakeHash left)" unchanged

fresh
: > "$STUB_HOME/final-fail"
snapshot
run_script; rc=$?
check "a red verifying build is exit 1" [ "$rc" -eq 1 ]
check "…named with the derived hash" errline "nix build failed with the derived vendorHash $NEW — flake.nix left untouched"
check "…flake.nix byte-identical (the old pin stays)" unchanged

fresh
printf '  vendorHash = "%s";\n' "$OLD" >> "$repo/flake.nix"
snapshot
run_script; rc=$?
check "two vendorHash lines is exit 1" [ "$rc" -eq 1 ]
check "…named" errline "exactly one 'vendorHash = ' line (found 2)"
check "…without a nix call" [ "$(nix_calls)" -eq 0 ]
check "…flake.nix untouched" unchanged

[ "$fails" -eq 0 ] || { echo "$fails repin-vendorhash case(s) failed"; exit 1; }
echo "all repin-vendorhash cases passed"
