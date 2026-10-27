#!/usr/bin/env bash
# Re-pin flake.nix's vendorHash on the fleet's dependabot gomod branches — the
# one write a gomod bump needs that dependabot cannot make. fleet-repin.yml
# runs this with FLEET_SYNC_PAT and nix on PATH.
#
#   usage:  fleet-repin.sh <owner> [only-repo]
#   env:    APPLY=1 writes; anything else is a dry run that reads everything and
#           writes nothing (the fleet-sync shape: dispatch defaults to dry)
#   stdout: one line per pull request the run had an opinion on —
#             repinned / would-repin / already-repinned / unchanged / held /
#             skipped(no-go.sum) / skipped(no-flake) / skipped(no-vendorhash) /
#             skipped(no-script) / failed
#           then `done: …` with every count, and the same as a step-summary
#           table when GITHUB_STEP_SUMMARY is set
#   exit:   0 when nothing failed; 1 when any read, clone, re-pin or write
#           failed, or the repo list could not be read; 2 usage
#
# WHY A BUMP BRANCH NEEDS THIS. A buildGoModule flake pins the vendored modules
# with a fixed-output hash; every gomod bump moves go.sum and leaves that pin
# stale, so the repo's `nix build` — and furrow's lockstep guard — stay red
# while auto-merge sits armed (furrow#396: 17 days). The ritual itself is the
# repo's own scripts/repin-vendorhash.sh — the canonical fleet-sync ships to
# every repo with a root flake.nix — so this script decides WHICH pulls need it
# and lands the result; it never re-pins by itself.
#
# WHICH PULLS. An open pull on a `dependabot/go_modules/` branch, authored by
# dependabot, not a draft, not labelled `hold`, aimed at the default branch,
# whose diff touches go.sum and does NOT touch flake.nix. A diff that already
# carries flake.nix is a re-pin that landed (ours or a hand's) — dependabot
# never writes that file, so its presence is the idempotence signal, and a
# force-push that drops it (dependabot rebasing onto a newer bump) is exactly
# when the re-pin is owed again. A repo whose head has no flake.nix, a flake
# with no vendorHash, and a head without the synced script are each one
# counted skip, never a guess.
#
# WHY THE PAT, AND THE CONTENTS API. The commit must be a user's: a push that
# github.token makes raises no pull_request run, so the bump's required checks
# would never re-run (the measured fact behind fleet-automerge). One file, one
# commit — the Contents API, with the blob sha read from the same head, so a
# branch dependabot moved meanwhile is a refused write (counted failed; the
# next run is idempotent), never a clobber. The author is akira-fleet-repin[bot]
# for attribution only — the App registered on this account for exactly that
# (github.com/apps/akira-fleet-repin, bot user id 348590270, no permissions,
# installed nowhere) — and the id-prefixed noreply address is what pins it:
# GitHub resolves an author by email alone, so a bare <name>[bot]@users.noreply
# resolves to whoever registers an App of that name (fleet-sync[bot] was a
# stranger's from 2026-10-15; scripts/fleet-commit-bundle.sh has the history).
# The `=` sigil is what keeps the commit lint-clean and folds none.
#
# READ-BACK. A PUT gh reports as success is re-read: the pull's diff must now
# carry flake.nix; anything else is `failed`, because "gh exited 0" is a claim
# and the pull request is the measurement. The pull's file list lags the push
# by a few seconds (measured on glyph-test#124, run 38372458940: the commit
# was on the branch and the first read still showed go.mod,go.sum), so the
# read is retried — a handful of times, seconds apart — before it is a verdict.
set -uo pipefail

owner="${1:-}"; only="${2:-}"
if [ -z "$owner" ]; then
  echo "usage: fleet-repin.sh <owner> [only-repo]" >&2
  exit 2
fi
apply="${APPLY:-0}"
dry=true; [ "$apply" = "1" ] && dry=false

repinned=0 would_repin=0 already=0 unchanged=0 held=0 skipped=0 failed=0 nrepos=0

fail() { echo "::error::fleet-repin: failed: $1"; failed=$((failed + 1)); }
skip() { echo "skipped($1): $2"; skipped=$((skipped + 1)); }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if [ -n "$only" ]; then
  repos="$only"
else
  repos="$(gh repo list "$owner" --no-archived --source --limit 200 --json name --jq '.[].name' 2>/dev/null | sort)" \
    || { echo "::error::fleet-repin: cannot list $owner's repositories" >&2; exit 1; }
  [ -n "$repos" ] || { echo "::error::fleet-repin: the repository list is empty — refusing to call that a fleet run" >&2; exit 1; }
fi

candidates='[.[] | select(.headRefName | startswith("dependabot/go_modules/"))] | sort_by(.number) | .[]
  | [.number, .headRefName, .baseRefName, .author.login, .isDraft, .mergeStateStatus,
     ([.labels[].name] | index("hold") != null), .title] | @tsv'

# The pull list is read on fd 3 and the repo list on fd 4: gh inside the loops
# must not eat the loops' own stdin.
while IFS= read -r -u 4 name; do
  [ -n "$name" ] || continue
  nrepos=$((nrepos + 1))
  full="$owner/$name"

  if ! prs="$(gh pr list --repo "$full" --state open --limit 50 \
        --json number,title,headRefName,baseRefName,author,labels,isDraft,mergeStateStatus \
        --jq "$candidates" 2>/dev/null </dev/null)"; then
    fail "$full cannot list its open pull requests"; continue
  fi
  [ -n "$prs" ] || continue

  if ! db="$(gh api "repos/$full" --jq .default_branch 2>/dev/null </dev/null)"; then
    fail "$full cannot read the repository settings"; continue
  fi

  while IFS=$'\t' read -r -u 3 num head base author draft ms hold title; do
    tag="$full#$num"

    if [ "$draft" = "true" ]; then echo "held: $tag draft — $title"; held=$((held + 1)); continue; fi
    if [ "$hold" = "true" ]; then echo "held: $tag label hold — $title"; held=$((held + 1)); continue; fi
    case "$author" in app/dependabot|dependabot|"dependabot[bot]") ;;
      *) echo "held: $tag author $author is not dependabot — $title"; held=$((held + 1)); continue ;;
    esac
    if [ "$base" != "$db" ]; then echo "held: $tag base $base is not the default branch $db — $title"; held=$((held + 1)); continue; fi
    if [ "$ms" = "DIRTY" ]; then echo "held: $tag merge conflict (dependabot rebases its own) — $title"; held=$((held + 1)); continue; fi

    if ! files="$(gh api "repos/$full/pulls/$num/files" --paginate --jq '.[].filename' 2>/dev/null </dev/null)"; then
      fail "$tag cannot read its changed files — $title"; continue
    fi
    if ! printf '%s\n' "$files" | grep -qx 'go.sum'; then skip no-go.sum "$tag the bump leaves go.sum alone — $title"; continue; fi
    if printf '%s\n' "$files" | grep -qx 'flake.nix'; then echo "already-repinned: $tag — $title"; already=$((already + 1)); continue; fi

    # The head's flake.nix: its blob sha is what the write below names, so the
    # write refuses a branch that moved between this read and the PUT.
    err="$work/err"
    if flake_json="$(gh api "repos/$full/contents/flake.nix?ref=$head" 2>"$err" </dev/null)"; then
      flake_sha="$(printf '%s' "$flake_json" | jq -r '.sha')"
      if ! printf '%s' "$flake_json" | jq -r '.content' | base64 -d 2>/dev/null | grep -q '^[[:space:]]*vendorHash = '; then
        skip no-vendorhash "$tag flake.nix pins no vendorHash — $title"; continue
      fi
    elif grep -q 'HTTP 404' "$err"; then
      skip no-flake "$tag no flake.nix at $head — $title"; continue
    else
      fail "$tag cannot read flake.nix at $head: $(head -c 200 "$err") — $title"; continue
    fi
    if ! gh api "repos/$full/contents/scripts/repin-vendorhash.sh?ref=$head" >/dev/null 2>"$err" </dev/null; then
      if grep -q 'HTTP 404' "$err"; then
        skip no-script "$tag scripts/repin-vendorhash.sh is not on $head (fleet-sync has not shipped it) — $title"; continue
      fi
      fail "$tag cannot read scripts/repin-vendorhash.sh at $head: $(head -c 200 "$err") — $title"; continue
    fi

    if [ "$apply" != "1" ]; then echo "would-repin: $tag — $title"; would_repin=$((would_repin + 1)); continue; fi

    clone="$work/$name-$num"
    rm -rf "$clone"
    if ! gh repo clone "$full" "$clone" -- --quiet --depth 1 --branch "$head" >/dev/null 2>"$err" </dev/null; then
      fail "$tag cannot clone $head: $(head -c 200 "$err") — $title"; continue
    fi
    if ! out="$( (cd "$clone" && sh scripts/repin-vendorhash.sh) 2>&1 </dev/null)"; then
      fail "$tag scripts/repin-vendorhash.sh failed: $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ' | head -c 300) — $title"; continue
    fi
    if cmp -s "$clone/flake.nix" <(printf '%s' "$flake_json" | jq -r '.content' | base64 -d); then
      echo "unchanged: $tag the ritual left flake.nix as it was ($(printf '%s' "$out" | tail -n 1 | head -c 120)) — $title"
      unchanged=$((unchanged + 1)); continue
    fi

    b64="$(base64 < "$clone/flake.nix" | tr -d '\n')"
    msg="$(printf ':package:(nix)= re-pin vendorHash for the gomod bump\n\ngo.sum moved with the bump, so the flake'"'"'s fixed-output vendor hash no longer\nmatched. Derived by scripts/repin-vendorhash.sh (fleet-repin, %s).' "$(printf '%s' "$out" | tail -n 1 | head -c 200)")"
    if ! gh api -X PUT "repos/$full/contents/flake.nix" \
          -f "message=$msg" \
          -f "author[name]=akira-fleet-repin[bot]" \
          -f "author[email]=348590270+akira-fleet-repin[bot]@users.noreply.github.com" \
          -f "content=$b64" -f "branch=$head" -f "sha=$flake_sha" >/dev/null 2>"$err" </dev/null; then
      fail "$tag write refused: $(head -c 300 "$err" | tr '\n' ' ') — $title"; continue
    fi
    seen=false; back_ok=true
    for attempt in 1 2 3 4 5 6; do
      if ! back="$(gh api "repos/$full/pulls/$num/files" --paginate --jq '.[].filename' 2>/dev/null </dev/null)"; then
        back_ok=false; break
      fi
      if printf '%s\n' "$back" | grep -qx 'flake.nix'; then seen=true; break; fi
      [ "$attempt" -lt 6 ] && sleep "${FLEET_REPIN_READBACK_DELAY:-5}"
    done
    if [ "$back_ok" != true ]; then
      fail "$tag written, but the read-back failed — $title"; continue
    fi
    if [ "$seen" = true ]; then
      echo "repinned: $tag $(printf '%s' "$out" | tail -n 1 | head -c 160) — $title"; repinned=$((repinned + 1))
    else
      fail "$tag write answered success but the pull request's diff shows no flake.nix after 6 reads — $title"
    fi
  done 3<<<"$prs"
done 4<<<"$repos"

echo "done: repinned=$repinned would-repin=$would_repin already-repinned=$already unchanged=$unchanged held=$held skipped=$skipped failed=$failed dry-run=$dry across $nrepos repo(s)"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## fleet-repin — $nrepos repo(s), dry-run=$dry"
    echo
    echo "| repinned | would repin | already repinned | unchanged | held | skipped | failed |"
    echo "|---|---|---|---|---|---|---|"
    echo "| $repinned | $would_repin | $already | $unchanged | $held | $skipped | $failed |"
  } >> "$GITHUB_STEP_SUMMARY"
fi
[ "$failed" -eq 0 ] || exit 1
exit 0
