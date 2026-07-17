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
url_re="github\.com/${REPO}/archive/refs/tags/v[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz"
new_url="github.com/${REPO}/archive/refs/tags/${TAG}.tar.gz"

# No-op when the formula already matches (repo tarball url at TAG and the new sha
# both present). Leaves the file untouched.
if grep -qE "github\.com/${REPO}/archive/refs/tags/${TAG//./\\.}\.tar\.gz" "$f" \
   && grep -q "sha256 \"${NEW_SHA}\"" "$f"; then
  echo "::notice::Formula already at ${TAG} — nothing to do."
  exit 0
fi

# Refuse to move the formula BACKWARD unless explicitly allowed.
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

# Repo-qualified, first-match seds: rewrite ONLY this repo's source tarball url
# and the FIRST sha256 (the source tarball's), leaving a vendored resource block's
# third-party url/sha untouched. Drop a leftover `revision N` line on a bump.
sed -i -E "0,\|${url_re}| s|${url_re}|${new_url}|" "$f"
sed -i -E "0,/sha256 \"[0-9a-f]{64}\"/ s|sha256 \"[0-9a-f]{64}\"|sha256 \"${NEW_SHA}\"|" "$f"
sed -i -E '/^  revision [0-9]+$/d' "$f"

# Assert the bump landed (a drifted url/sha format makes a sed match nothing —
# fail loud rather than leave a no-op or half-updated formula).
grep -qE "github\.com/${REPO}/archive/refs/tags/${TAG//./\\.}\.tar\.gz" "$f" \
  || { echo "::error::tap bump failed: ${TAG} tarball URL missing in ${f} after sed."; exit 1; }
grep -q "sha256 \"${NEW_SHA}\"" "$f" \
  || { echo "::error::tap bump failed: sha256 not updated in ${f} after sed."; exit 1; }
