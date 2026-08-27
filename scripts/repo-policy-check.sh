#!/usr/bin/env bash
# House-policy checks that need no external tool, run per-repo by the
# repo-policy reusable (.github/workflows/repo-policy.yml) against the CALLER
# repo's checkout. Extracted here so the logic is table-tested
# (tests/repo-policy-check.test.sh) instead of living untested in workflow YAML
# — the same split as platform-floor-scan.sh / glyph-pin-scan.sh.
#
#   usage:  repo-policy-check.sh [<repo-dir>]     (default: .)
#   stdout: one "<path>[:<line>]: <message>" per violation, then a summary
#   exit:   0 clean (including "nothing applies"), 1 violations, 2 broken input
#           (an unparsable floor must not read as compliant — fail loud)
#
# Check 1 — translation files are banned (docs/doc-consistency-policy.md: the
# fleet stores no translations; English is the single source). The judgment
# starts BY PATH — a tracked file whose basename contains `.ja.` (README.ja.md,
# docs/guide.ja.txt). Deliberately not a content grep over the tree: the policy
# document itself names `README.ja.md` as its example, so any content match
# would flag the rule's own text forever. A future file whose CANONICAL
# language is Japanese takes a non-`.ja.` name (e.g. docs/design-jp/) — the
# policy doc records that escape hatch.
#
# One carve-out (the policy's declared-review-copy exception, ruled
# 2026-08-25): a `.ja.` file whose FIRST TEN LINES carry the non-canonical
# declaration header passes. The header's load-bearing words — 和訳 (this is a
# translation), 正本 (the original is canonical), 基準 (pinned to a base
# commit of the original) — must all appear; an equal-looking parallel
# translation carries none of them. Reference shape: the header on the
# *.ja.md files in akira-toriyama/projects. Only the flagged file's own head
# is read, so the no-content-grep rationale above still holds.
#
# Check 2 — a #available/@available(macOS …) gate at or below the repo's own
# declared floor is dead code: the floor already guarantees the API, so the
# gate is always-true and its else-branch (the workaround for older macOS) can
# never run. The floor is read from the repo's root Package.swift via
# platform-floor-scan.sh — never hardcoded to "the latest macOS", so raising
# the floor tightens this check automatically and a gate ABOVE the floor (a
# new-API adoption gate) passes as legitimate. Scope is the PACKAGE'S OWN
# TREE: tracked *.swift under Sources/ and Tests/. One-off scripts outside it
# (packaging/icon/*.swift) build standalone, inherit no floor from
# Package.swift, and are deliberately NOT checked. A repo without a root
# Package.swift, or whose Package.swift declares no macOS floor, skips this
# check entirely (floor presence for sill consumers is platform-floor-audit's
# job, not this gate's).
set -uo pipefail

dir="${1:-.}"
here="$(cd "$(dirname "$0")" && pwd)"
floorscan="$here/platform-floor-scan.sh"
violations=0
broken=0

[ -d "$dir" ] || { echo "repo-policy: no such directory: $dir" >&2; exit 2; }
[ -f "$floorscan" ] || { echo "repo-policy: missing $floorscan" >&2; exit 2; }

# --- check 1: translation files, by tracked path -----------------------------
while IFS= read -r f; do
  # Declared review copy: all three header words within the first ten lines.
  # A missing file (tracked but absent from this tree) reads as undeclared —
  # fail closed, never silently pass.
  head10="$(head -n 10 -- "$dir/$f" 2>/dev/null || true)"
  if printf '%s' "$head10" | grep -q '和訳' \
    && printf '%s' "$head10" | grep -q '正本' \
    && printf '%s' "$head10" | grep -q '基準'; then
    continue
  fi
  echo "$f: translation file — the fleet stores no translations; fold the content into the English original, or open it with the declared-review-copy header (docs/doc-consistency-policy.md)"
  violations=$((violations + 1))
done < <(git -C "$dir" ls-files | grep -E '(^|/)[^/]+\.ja\.[^/]+$' || true)

# --- check 2: availability gates at or below the declared macOS floor --------
floor=""
if [ -f "$dir/Package.swift" ]; then
  floor="$(bash "$floorscan" < "$dir/Package.swift" \
    | awk -F'\t' '$1 == "macos-floor" { print $2; exit }')"
fi

if [ -n "$floor" ]; then
  while IFS= read -r src; do
    # Comment-stripped scan for `…available(… macOS <ver> …)`, one record per
    # gate as "<line>\t<ver>". The stripper mirrors platform-floor-scan.sh's
    # (same hazards: a gate quoted in a // comment or a /* block is
    # documentation, not code, and `://` inside a string must not open a
    # false comment).
    while IFS=$'\t' read -r lineno ver; do
      rc=0
      bash "$floorscan" cmp "$floor" "$ver" 2>/dev/null || rc=$?
      case "$rc" in
        0)
          echo "$src:$lineno: available(macOS $ver) gate is dead code — the declared floor $floor already guarantees it; drop the gate and its fallback branch"
          violations=$((violations + 1))
          ;;
        1) ;; # gate above the floor: a legitimate new-API adoption gate
        *)
          echo "$src:$lineno: unparsable availability version '$ver' (floor '$floor') — fix it; unreadable must not pass as compliant"
          broken=$((broken + 1))
          ;;
      esac
    done < <(awk '
      BEGIN {
        hide = sprintf("%c", 1)
        inblock = 0
      }
      {
        line = $0
        while (inblock) {
          if (match(line, /\*\//)) { line = substr(line, RSTART + 2); inblock = 0 }
          else next
        }
        while (match(line, /\/\*/)) {
          head = substr(line, 1, RSTART - 1)
          tail = substr(line, RSTART + 2)
          if (match(tail, /\*\//)) line = head substr(tail, RSTART + 2)
          else { line = head; inblock = 1 }
        }
        gsub(/:\/\//, hide, line)
        sub(/\/\/.*$/, "", line)
        gsub(hide, "://", line)

        rest = line
        while (match(rest, /[#@]available\([^)]*\)/)) {
          seg = substr(rest, RSTART, RLENGTH)
          rest = substr(rest, RSTART + RLENGTH)
          if (match(seg, /macOS[ \t]+[0-9][0-9.]*/)) {
            ver = substr(seg, RSTART, RLENGTH)
            sub(/^macOS[ \t]+/, "", ver)
            print NR "\t" ver
          }
        }
      }
    ' "$dir/$src")
  done < <(git -C "$dir" ls-files -- Sources Tests | grep '\.swift$' || true)
fi

# --- verdict -----------------------------------------------------------------
if [ "$broken" -gt 0 ]; then
  echo "repo-policy: $broken unreadable record(s) — failing loud" >&2
  exit 2
fi
if [ "$violations" -gt 0 ]; then
  echo "repo-policy: $violations violation(s)"
  exit 1
fi
echo "repo-policy: clean"
exit 0
