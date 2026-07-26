#!/usr/bin/env bash
# Pure Homebrew-formula mutation extracted from update-tap.yml's Bump step so
# self-test can table-test it (the git commit/push half needs a fake tap and
# stays in the reusable). Extracted byte-equivalent to the old inline logic; the
# formula path is $1 (was tap/Formula/$FORMULA.rb) and git is gone. See t-kve5.
# It has since gained two deliberate differences from that inline original, both
# noted at the code below: the rewrite is a single awk pass rather than three
# seds, and a refusal is atomic (the formula is left untouched).
#
# POSIX tools only — no GNU extensions. This runs on ubuntu in Actions, but it
# has to stay runnable on the macOS dev machine too, because tests/bump-formula.
# test.sh is the ONLY way to see this logic execute before it reaches a tap: the
# git-push half is never smoke-tested. It previously used GNU `sed -i` with the
# `0,/re/` first-match address, so the table failed 5/8 on BSD sed and the one
# check that could catch a mutation bug locally could not be run at all.
#
# Contract:
#   $1                  = path to the Formula .rb to mutate in place
#   env TAG             = target tag, e.g. v1.4.0
#   env NEW_SHA         = source-tarball sha256 (64 hex)
#   env REPO            = owner/repo whose archive/refs/tags tarball url is THE one
#   env FORMULA         = formula basename (messages only)
#   env ALLOW_DOWNGRADE = "true" permits a backward move; else refused
#   exit 0 = ok (mutated, or already-at-tag no-op — file may be unchanged)
#   exit 1 = refused (backward move) or assert failed (a sed matched nothing)
set -euo pipefail

f="$1"
# Match ONLY this repo's source tarball. A `resource` block vendoring a
# third-party tarball carries the same bare archive/refs/tags/vX.Y.Z.tar.gz
# shape, so an unqualified sed rewrites ITS url to this repo's tag — poisoning
# the formula (that resource tag doesn't exist) while both asserts below still
# pass, because they only check that the NEW values are present, never that
# nothing else moved. Repo-qualified + first-match scoped makes the collateral
# hit impossible rather than merely detected.
#
# `[.]` rather than `\.` throughout: identical as an ERE, but it also survives
# being handed to awk via -v, which interprets backslash escapes inside the
# value (`\.` is an undefined escape there). One spelling for both tools.
url_re="github[.]com/${REPO}/archive/refs/tags/v[0-9]+[.][0-9]+[.][0-9]+[.]tar[.]gz"
# The same url pinned to TAG — the post-condition the bump has to reach, and the
# pre-condition of the no-op below. Written once, asserted twice.
tag_url_re="github[.]com/${REPO}/archive/refs/tags/${TAG//./[.]}[.]tar[.]gz"
new_url="github.com/${REPO}/archive/refs/tags/${TAG}.tar.gz"

# No-op when the formula already matches (repo tarball url at TAG and the new sha
# both present). Leaves the file untouched.
if grep -qE "$tag_url_re" "$f" \
   && grep -q "sha256 \"${NEW_SHA}\"" "$f"; then
  echo "::notice::Formula already at ${TAG} — nothing to do."
  exit 0
fi

# Refuse to move the formula BACKWARD. Nothing upstream guarantees the resolved
# tag is newer than what the tap already ships: the release path trusts the event
# payload (publishing an older release moves it back), and the latest-fetch
# fallback resolves the newest PUBLISHED release, which lags the tap whenever a
# shipped release gets re-drafted. Either way the bump below would rewrite
# url+sha, pass both asserts and push a silent `brew upgrade` DOWNGRADE, green.
# Rolling a bad release back is a real need, so it stays possible — but only when
# asked for explicitly (allow-downgrade=true).
cur="$(grep -oE "$url_re" "$f" | head -1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' || true)"
if [ -n "$cur" ] && [ "$cur" != "${TAG}" ]; then
  newest="$(printf '%s\n%s\n' "$cur" "${TAG}" | sort -V | tail -1)"
  if [ "$newest" != "${TAG}" ]; then
    if [ "${ALLOW_DOWNGRADE}" = "true" ]; then
      echo "::warning::${FORMULA}: ${cur} → ${TAG} moves the tap BACKWARD; proceeding (allow-downgrade=true)."
    else
      echo "::error::Refusing to move ${FORMULA} BACKWARD (${cur} → ${TAG}). Re-run with allow-downgrade=true if this rollback is intended."
      exit 1
    fi
  fi
fi

# All three mutations in ONE awk pass. Each `!done && match(...)` guard fires on
# the first matching line in the FILE, which is what GNU sed's `0,/re/` address
# bought and POSIX sed cannot express at all:
#
#   url      — the first repo-qualified source tarball only (see the note above).
#   sha256   — the first one only: the source tarball's, at the top of the
#              formula. A later resource/bottle sha256 stays put. Dropping `/g`
#              would NOT be enough — that still substitutes once per LINE, on
#              every line.
#   revision — every `revision N` line is dropped on a version bump. Revision
#              only matters when REbuilding the same upstream version (e.g. an
#              install-script fix at the same tag); a fresh tag resets it
#              naturally. Without this, a revision bumped while fixing a prior
#              release rides forward and renders as `1.5.0_2`.
#
# Splicing with substr() around RSTART/RLENGTH rather than sub() also means the
# replacement is inserted LITERALLY: a `&` or a `\1` arriving in TAG or NEW_SHA
# cannot turn into a backreference, which the sed form simply had to trust.
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
awk -v url_re="$url_re" -v new_url="$new_url" -v new_sha="$NEW_SHA" '
  !url_done && match($0, url_re) {
    $0 = substr($0, 1, RSTART - 1) new_url substr($0, RSTART + RLENGTH)
    url_done = 1
  }
  !sha_done && match($0, /sha256 "[0-9a-f]{64}"/) {
    $0 = substr($0, 1, RSTART - 1) "sha256 \"" new_sha "\"" substr($0, RSTART + RLENGTH)
    sha_done = 1
  }
  /^  revision [0-9]+$/ { next }
  { print }
' "$f" >"$tmp"

# Assert the bump landed BEFORE it becomes the formula. Checking the candidate
# rather than the file makes a refusal ATOMIC: a formula whose url format drifted
# so the url pattern matched nothing used to be left on disk with its sha256
# already rewritten — refused, but half-updated. Nothing downstream shipped that
# (update-tap.yml's commit/push steps never run after a non-zero exit), yet a
# rewritten working tree after a command that said it refused is a trap for
# whoever debugs the drift by hand.
#
# These assert PRESENCE of the new values only; they cannot see collateral damage
# elsewhere in the file, which is why the rewrites above are scoped rather than
# merely checked afterwards.
grep -qE "$tag_url_re" "$tmp" \
  || { echo "::error::tap bump failed: ${TAG} tarball URL missing in ${f} after rewrite (formula left untouched)."; exit 1; }
grep -q "sha256 \"${NEW_SHA}\"" "$tmp" \
  || { echo "::error::tap bump failed: sha256 not updated in ${f} after rewrite (formula left untouched)."; exit 1; }

# Commit. Write THROUGH the original path rather than `mv` — keeps the inode,
# mode and any git-tracked permissions of the formula the caller handed us.
cat "$tmp" >"$f"
