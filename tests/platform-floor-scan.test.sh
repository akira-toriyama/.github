#!/usr/bin/env bash
# Table-test scripts/platform-floor-scan.sh — the eyes of platform-floor-audit.yml.
# The audit reads every consumer's macOS floor and its sill dependency through
# this scanner; a parser regression does not fail loudly, it silently stops
# SEEING a floor or a dependency, which reads exactly like a repo with nothing
# to audit (the same failure shape glyph-pin-scan's table exists for). The
# comment cases are not hypothetical: sill's own Package.swift carries
# `.macOS("26.0")` inside a // comment, and matching it would hand the audit a
# floor that no build ever enforces.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
script="$root/scripts/platform-floor-scan.sh"
fails=0

[ -f "$script" ] || { echo "FAIL - $script is missing"; exit 1; }

# run_case <name> <expected-TSV> <<'SWIFT' … — feeds stdin, compares full output.
run_case() {
  local name="$1" want="$2" got
  got="$(bash "$script")"
  if [ "$got" = "$want" ]; then
    echo "ok   - $name"
  else
    echo "FAIL - $name"
    echo "       want: $(printf '%s' "$want" | tr '\n' '|')"
    echo "       got:  $(printf '%s' "$got" | tr '\n' '|')"
    fails=$((fails + 1))
  fi
}

# cmp_case <name> <a> <b> <expected-rc>
cmp_case() {
  local name="$1" a="$2" b="$3" want_rc="$4" rc=0
  bash "$script" cmp "$a" "$b" 2>/dev/null || rc=$?
  if [ "$rc" = "$want_rc" ]; then
    echo "ok   - $name"
  else
    echo "FAIL - $name (want rc=$want_rc, got rc=$rc)"
    fails=$((fails + 1))
  fi
}

# --- the current family shape: string floor + url dependency, with the real
# --- comment hazards on the same lines
run_case "string floor and url dep, trailing comments stripped" \
"$(printf 'macos-floor\t26.0\t2\nsill-dep\turl\t4')" <<'SWIFT'
let package = Package(
    platforms: [.macOS("26.0")], // raised for sill v2.0.0 (was .macOS(.v13))
    dependencies: [
        .package(url: "https://github.com/akira-toriyama/sill.git", // shared theming
                 .upToNextMinor(from: "5.0.0")),
    ]
)
SWIFT

# --- the drifted legacy form this audit exists to catch (t-tbar leftovers)
run_case "legacy .vN floor is read too" \
"$(printf 'macos-floor\t13\t1')" <<'SWIFT'
    platforms: [.macOS(.v13)],
SWIFT

# --- sill's own file shape: the floor inside a whole-line comment must NOT
# --- be a record; only the real declaration is
run_case "a floor inside a // comment is documentation, not a floor" \
"$(printf 'macos-floor\t26.0\t3')" <<'SWIFT'
// sill pin). Spelled ".macOS("26.0")" — the string form is the only one both
// toolchains accept; .macOS(.v26) does not exist.
    platforms: [.macOS("26.0")],
SWIFT

# --- a /* */ block hiding a dependency must not resurrect it
run_case "a block-commented dependency is not a dependency" \
"$(printf 'sill-dep\turl\t4')" <<'SWIFT'
    /*
    .package(url: "https://github.com/akira-toriyama/sill.git", from: "1.0.0"),
    */
    .package(url: "https://github.com/akira-toriyama/sill.git", from: "5.0.0"),
SWIFT

# --- the // strip must not eat :// — else the url line truncates at `https:`
# --- and the dependency silently vanishes from the audit
run_case "the URL scheme survives the comment strip" \
"$(printf 'sill-dep\turl\t1')" <<'SWIFT'
        .package(url: "https://github.com/akira-toriyama/sill", from: "5.0.0"),
SWIFT

# --- the local-dev path form counts as a dependency too
run_case "the path form is a dependency" \
"$(printf 'sill-dep\tpath\t1')" <<'SWIFT'
        .package(path: "../sill"),
SWIFT

# --- boundary: sill-themes / swift-toml-edit must never read as sill
run_case "a similarly-named package is not sill" \
"" <<'SWIFT'
        .package(url: "https://github.com/akira-toriyama/sill-themes.git", from: "1.0.0"),
        .package(url: "https://github.com/akira-toriyama/swift-toml-edit.git", from: "2.0.0"),
        .package(path: "../sill-fork"),
SWIFT

# --- a file with no platforms: yields no floor record at all (the audit turns
# --- that absence into a loud red for sill consumers — but only if the scanner
# --- is honest about it, not inventing one)
run_case "no platforms means no floor record" \
"$(printf 'sill-dep\turl\t1')" <<'SWIFT'
        .package(url: "https://github.com/akira-toriyama/sill.git", from: "5.0.0"),
SWIFT

# --- cmp: the comparison the audit makes, both directions plus the numeric trap
cmp_case "cmp: equal floors comply"            26.0 26.0 0
cmp_case "cmp: a higher consumer floor complies" 26.1 26.0 0
cmp_case "cmp: a lower consumer floor is drift"  13   26.0 1
cmp_case "cmp: numeric, not lexical (9 < 13)"    9    13   1
cmp_case "cmp: minor beats missing minor"        26.1 26   0
cmp_case "cmp: an unparsable floor is exit 2, not a verdict" junk 26.0 2

[ "$fails" -eq 0 ] || { echo "$fails platform-floor-scan case(s) failed"; exit 1; }
echo "all platform-floor-scan cases passed"
