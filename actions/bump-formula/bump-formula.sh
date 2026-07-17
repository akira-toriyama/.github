#!/usr/bin/env bash
# Pure Homebrew-formula mutation extracted from update-tap.yml's Bump step so
# self-test can table-test it (the git commit/push half needs a fake tap and
# stays in the reusable). Behavior-preserving: byte-equivalent to the old inline
# logic; only the formula path is now $1 (was tap/Formula/$FORMULA.rb) and git is
# gone. GNU sed (0,/re/) required. See t-kve5.
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
url_re="github\.com/${REPO}/archive/refs/tags/v[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz"
new_url="github.com/${REPO}/archive/refs/tags/${TAG}.tar.gz"

# No-op when the formula already matches (repo tarball url at TAG and the new sha
# both present). Leaves the file untouched.
if grep -qE "github\.com/${REPO}/archive/refs/tags/${TAG//./\\.}\.tar\.gz" "$f" \
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

sed -i -E "0,\|${url_re}| s|${url_re}|${new_url}|" "$f"
# Replace ONLY the first sha256 (the source tarball's, at the top of the
# formula). `0,/re/` scopes the substitution to the first match in the file, so a
# later resource/bottle sha256 is left untouched. Dropping `/g` alone would NOT
# achieve this — sed still substitutes once per line, on every line.
sed -i -E "0,/sha256 \"[0-9a-f]{64}\"/ s|sha256 \"[0-9a-f]{64}\"|sha256 \"${NEW_SHA}\"|" "$f"
# On any version bump, drop a leftover `revision N` line. Revision only matters
# when REbuilding the same upstream version (e.g. an install-script fix at the
# same tag); a fresh tag naturally resets it. Without this, a revision bumped
# while fixing a prior release follows the formula forward and produces e.g.
# `1.5.0_2` when the natural display is `1.5.0`.
sed -i -E '/^  revision [0-9]+$/d' "$f"

# Assert the bump actually landed — catches a formula whose url/sha format
# drifted so a sed matched nothing (better to fail than leave a no-op or a
# half-updated formula). These assert PRESENCE of the new values only; they
# cannot see collateral damage elsewhere in the file, which is why the seds above
# are scoped rather than merely checked afterwards.
grep -qE "github\.com/${REPO}/archive/refs/tags/${TAG//./\\.}\.tar\.gz" "$f" \
  || { echo "::error::tap bump failed: ${TAG} tarball URL missing in ${f} after sed."; exit 1; }
grep -q "sha256 \"${NEW_SHA}\"" "$f" \
  || { echo "::error::tap bump failed: sha256 not updated in ${f} after sed."; exit 1; }
