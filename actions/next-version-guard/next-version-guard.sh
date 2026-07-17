#!/usr/bin/env bash
# Pure next-version decision extracted from release.yml's "Compute next version"
# step so self-test can table-test it (the git-cliff / git tag / gh reads that
# feed it stay in the reusable). Behavior-preserving. See t-kve5 / t-fqhx.
#
# Contract:
#   env NEXT       = git-cliff --bumped-version (may be empty)
#   env LAST       = newest local git tag (may be empty)
#   env PUB_LATEST = newest PUBLISHED release tag vX.Y.Z (may be empty)
#   writes to $GITHUB_OUTPUT:  release=true|false  and (when true) version=<NEXT>
#   exit 0 = decided (release true or false) · exit 1 = deadlock (unpublishable)
set -euo pipefail

echo "next=${NEXT:-<none>} last=${LAST:-<none>} pub_latest=${PUB_LATEST:-<none>}"

# No release-worthy changes: git-cliff bumped nothing, or the bump equals the
# last tag already cut.
if [ -z "$NEXT" ] || [ "$NEXT" = "$LAST" ]; then
  echo "release=false" >> "$GITHUB_OUTPUT"
  echo "::notice::No release-worthy changes (feat/fix/perf/breaking) since ${LAST:-<none>}; nothing to do."
  exit 0
fi

# Deadlock guard (immutable-releases safe): never draft a version that can't be
# Published. If NEXT is not strictly greater than the latest PUBLISHED release,
# the tag/release state is off (e.g. a deleted-then-recomputed version whose
# immutable tag is permanently burned). Fail loud rather than drafting.
# BSD-portable numeric sort (inputs are strict vX.Y.Z) — macos-15's sort has no
# reliable `-V`.
if [ -n "$PUB_LATEST" ]; then
  top="v$(printf '%s\n%s\n' "${NEXT#v}" "${PUB_LATEST#v}" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n1)"
  if [ "$NEXT" = "$PUB_LATEST" ] || [ "$top" != "$NEXT" ]; then
    echo "::error::Computed version $NEXT is not greater than the latest published release $PUB_LATEST — refusing to create a draft (it would collide with or regress below a published immutable release). Investigate the tag/release state; if a published release was deleted, its tag is permanently burned — bump past it."
    exit 1
  fi
fi

echo "release=true"  >> "$GITHUB_OUTPUT"
echo "version=$NEXT" >> "$GITHUB_OUTPUT"
