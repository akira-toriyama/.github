#!/usr/bin/env bash
# Table-test scripts/repo-policy-check.sh — the whole check the repo-policy
# reusable runs against every fleet repo's PR. Both checks fail SILENTLY when
# they regress (a pattern that stops matching reads exactly like a clean repo),
# so the table pins both directions: the violation that must fire, and the
# look-alike that must not (the policy doc naming README.ja.md in prose, a
# gate ABOVE the floor, a script outside the package tree).
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
script="$root/scripts/repo-policy-check.sh"
fails=0

[ -f "$script" ] || { echo "FAIL - $script is missing"; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# repo <name>  — fresh git repo to stage a case in; TRACKED files only count,
# so every fixture file must be `git add`ed (add_file does).
repo() {
  casedir="$work/$1"
  mkdir -p "$casedir"
  git -C "$casedir" init -q
}

add_file() { # $1 = relative path, stdin = content
  mkdir -p "$casedir/$(dirname "$1")"
  cat > "$casedir/$1"
  git -C "$casedir" add "$1"
}

# run_case <name> <want-rc> <want-grep|-> — runs the script on $casedir;
# checks exit code, and (unless "-") that stdout matches the grep -E pattern.
run_case() {
  local name="$1" want_rc="$2" want="$3" got rc=0
  got="$(bash "$script" "$casedir" 2>&1)" || rc=$?
  if [ "$rc" != "$want_rc" ]; then
    echo "FAIL - $name (want rc=$want_rc, got rc=$rc)"
    echo "       out: $(printf '%s' "$got" | tr '\n' '|')"
    fails=$((fails + 1))
    return
  fi
  if [ "$want" != "-" ] && ! printf '%s' "$got" | grep -qE "$want"; then
    echo "FAIL - $name (missing /$want/)"
    echo "       out: $(printf '%s' "$got" | tr '\n' '|')"
    fails=$((fails + 1))
    return
  fi
  echo "ok   - $name"
}

# --- an empty repo is clean, not an error ------------------------------------
repo empty
run_case "empty repo is clean" 0 "repo-policy: clean"

# --- check 1: translation files ----------------------------------------------
repo ja-root
add_file "README.ja.md" <<'EOF'
# 日本語版
EOF
run_case "README.ja.md at the root is a violation" 1 'README\.ja\.md: translation file'

repo ja-nested
add_file "docs/guide.ja.txt" <<'EOF'
ガイド
EOF
run_case "a nested *.ja.* file is a violation" 1 'docs/guide\.ja\.txt: translation file'

# The infix must be a real `.ja.` — a file merely named ja.md, ending in .ja,
# or living in a -jp directory (the policy's own escape hatch for a future
# Japanese-canonical file) is NOT a translation file.
repo ja-lookalikes
add_file "ja.md" <<'EOF'
not a translation
EOF
add_file "notes.ja" <<'EOF'
not a translation
EOF
add_file "docs/design-jp/plan.md" <<'EOF'
canonical Japanese, escape-hatch naming
EOF
run_case "ja look-alikes and the -jp escape hatch are clean" 0 "repo-policy: clean"

# An UNTRACKED translation file is invisible: the check reads git ls-files,
# never the working tree (scratch files must not fail CI).
repo ja-untracked
cat > "$casedir/README.ja.md" <<'EOF'
untracked scratch
EOF
run_case "an untracked *.ja.* file is not a violation" 0 "repo-policy: clean"

# --- check 2: availability gates vs the declared floor -----------------------
floor_pkg() { # writes a Package.swift with the family's string-form floor
  add_file "Package.swift" <<'EOF'
let package = Package(
    platforms: [.macOS("26.0")],
)
EOF
}

repo gate-below
floor_pkg
add_file "Sources/App/Panel.swift" <<'EOF'
if #available(macOS 14, *) {
    view.addSymbolEffect()
} else {
    legacyFallback()
}
EOF
run_case "a gate below the floor is dead code" 1 \
  'Sources/App/Panel\.swift:1: available\(macOS 14\) gate is dead code'

repo gate-equal
floor_pkg
add_file "Sources/App/Equal.swift" <<'EOF'
@available(macOS 26.0, *)
func f() {}
EOF
run_case "a gate equal to the floor is dead code too" 1 \
  'Equal\.swift:1: available\(macOS 26\.0\) gate is dead code'

repo gate-above
floor_pkg
add_file "Sources/App/New.swift" <<'EOF'
if #available(macOS 27, *) {
    adoptNewAPI()
}
EOF
run_case "a gate above the floor is legitimate adoption" 0 "repo-policy: clean"

# Major-only floor vs major.minor gate must compare numerically (the cmp that
# platform-floor-scan table-tests), and a multi-platform gate must read the
# macOS clause, not the first version it sees.
repo gate-multiplatform
add_file "Package.swift" <<'EOF'
    platforms: [.macOS(.v15)],
EOF
add_file "Sources/App/Multi.swift" <<'EOF'
if #available(iOS 26, macOS 14.0, *) { modern() }
EOF
run_case "the macOS clause of a multi-platform gate is compared" 1 \
  'Multi\.swift:1: available\(macOS 14\.0\) gate is dead code'

# A gate inside a comment is documentation, not code — the same hazard that
# made platform-floor-scan strip comments before matching.
repo gate-comments
floor_pkg
add_file "Sources/App/Doc.swift" <<'EOF'
// previously: if #available(macOS 14, *) { … }
/*
if #available(macOS 13, *) { legacy() }
*/
let url = "https://example.com" // #available(macOS 12, *)
EOF
run_case "commented-out gates are not violations" 0 "repo-policy: clean"

# One-off scripts OUTSIDE the package tree (packaging/icon/*.swift) build
# standalone and inherit no floor — deliberately out of scope.
repo gate-outside
floor_pkg
add_file "packaging/icon/generate-icon.swift" <<'EOF'
if #available(macOS 13.0, *) { render() }
EOF
run_case "a script outside Sources/Tests is out of scope" 0 "repo-policy: clean"

# No Package.swift, or one without a macOS floor: the check skips — floor
# PRESENCE for sill consumers is platform-floor-audit's job, not this gate's.
repo no-floor
add_file "Package.swift" <<'EOF'
let package = Package(name: "tool")
EOF
add_file "Sources/App/Gate.swift" <<'EOF'
if #available(macOS 10, *) { f() }
EOF
run_case "no declared floor means the check skips" 0 "repo-policy: clean"

# An unparsable gate version must fail LOUD (exit 2), never read as compliant.
repo gate-unparsable
add_file "Package.swift" <<'EOF'
    platforms: [.macOS("26.0.1.9")],
EOF
add_file "Sources/App/Weird.swift" <<'EOF'
if #available(macOS 14, *) { f() }
EOF
run_case "an unparsable floor is exit 2, not a verdict" 2 "unparsable"

# Both checks can fire in one repo, and the count is the sum.
repo both
floor_pkg
add_file "README.ja.md" <<'EOF'
訳
EOF
add_file "Sources/App/Old.swift" <<'EOF'
if #available(macOS 14, *) { f() }
EOF
run_case "both checks report together" 1 'repo-policy: 2 violation'

[ "$fails" -eq 0 ] || { echo "$fails repo-policy-check case(s) failed"; exit 1; }
echo "all repo-policy-check cases passed"
