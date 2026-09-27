#!/usr/bin/env bash
# Table-test scripts/automerge-tier.sh — the classifier fleet-automerge asks
# before arming auto-merge on a bot pull request. Runs the REAL script
# (drift-free); self-test.yml invokes this. Needs bash + awk + grep only.
#
# The shapes are the fleet's real ones: glyph-pin-rewrite's `(vA -> vB)` title,
# fleet-sync's sync / prune titles, and dependabot's `updated-dependencies:`
# trailer as it appears on prq#44 (one patch), study-engine#18 (a group of
# four), fleet-test#3 (actions/checkout 5 -> 7) and dotfiles#393 (a SHA-pinned
# action, which carries NO update-type). The property that matters most is
# fail-closed: everything the script cannot read as a tier is `hold`.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
script="$root/scripts/automerge-tier.sh"
fails=0

[ -f "$script" ] || { echo "FAIL - $script is missing"; exit 1; }

# case_ <name> <head> <title> <stdin> <want-verdict> [<want-detail-substring>]
case_() {
  local name="$1" head="$2" title="$3" stdin="$4" want="$5" sub="${6:-}" got rc v d
  got="$(printf '%s' "$stdin" | bash "$script" "$head" "$title" 2>&1)"; rc=$?
  v="${got%%	*}"; d="${got#*	}"
  if [ "$rc" -eq 0 ] && [ "$v" = "$want" ] && [ "$(printf '%s\n' "$got" | wc -l | tr -d ' ')" = "1" ] \
     && { [ -z "$sub" ] || case "$d" in *"$sub"*) true ;; *) false ;; esac; }; then
    echo "ok   - $name"
  else
    echo "FAIL - $name (rc=$rc)"
    echo "       want: $want${sub:+ … $sub}"
    echo "       got:  $got"
    fails=$((fails + 1))
  fi
}

trailer() { # trailer <entries...> — each entry "name[:type]" → a dependabot commit message
  printf ':arrow_up:(deps) bump something\n\nBumps the group.\n\n---\nupdated-dependencies:\n'
  local e name type
  for e in "$@"; do
    name="${e%%:*}"; type=""; [ "$e" != "$name" ] && type="${e#*:}"
    printf -- '- dependency-name: %s\n  dependency-version: 1.2.3\n  dependency-type: direct:production\n' "$name"
    [ -z "$type" ] || printf '  update-type: version-update:semver-%s\n' "$type"
    printf '  dependency-group: g\n'
  done
  printf '...\n\nSigned-off-by: dependabot[bot] <support@github.com>\n'
}

# usage
bash "$script" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then echo "ok   - no arguments is usage (exit 2)"; else echo "FAIL - no arguments is usage (rc=$rc)"; fails=$((fails + 1)); fi
bash "$script" glyph-pin/v1 >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then echo "ok   - a missing title is usage (exit 2)"; else echo "FAIL - a missing title is usage (rc=$rc)"; fails=$((fails + 1)); fi

# glyph-pin: the tier is the first differing component of (vA -> vB)
case_ "glyph-pin patch"  glyph-pin/v3.3.1 ':arrow_up:(ci)= pin glyph v3.3.1 (v3.3.0 -> v3.3.1)' "" auto  "patch"
case_ "glyph-pin minor"  glyph-pin/v3.4.0 ':arrow_up:(ci)= pin glyph v3.4.0 (v3.3.1 -> v3.4.0)' "" auto  "minor"
case_ "glyph-pin major"  glyph-pin/v4.0.0 ':arrow_up:(ci)= pin glyph v4.0.0 (v3.3.1 -> v4.0.0)' "" major "v3.3.1 -> v4.0.0"
case_ "glyph-pin major across a minor+patch reset" glyph-pin/v5.0.0 'pin (v4.9.9 -> v5.0.0)' "" major
case_ "glyph-pin short versions compare by component" glyph-pin/v5 'pin (v4 -> v5)' "" major
case_ "glyph-pin prerelease is a hold" glyph-pin/v3.3.1-rc.1 'pin (v3.3.0 -> v3.3.1-rc.1)' "" hold "release-to-release"
case_ "glyph-pin no version pair is a hold (config-only pull)" glyph-pin/v3.3.1 ':wrench:(ci)= add glyph.toml — the config-first invariant, ahead of the v3.3.1 pins' "" hold '(vA -> vB)'
case_ "glyph-pin same version is a hold" glyph-pin/v4.0.0 'pin (v4.0.0 -> v4.0.0)' "" hold "moves nothing"
case_ "glyph-pin ignores stdin" glyph-pin/v3.3.1 'pin (v3.3.0 -> v3.3.1)' "$(trailer a:major)" auto

# fleet-sync: always auto, whatever the title
case_ "fleet-sync sync title"  fleet-sync/commit-lint ':wrench:(fleet)= sync .github/workflows/commit-lint.yml' "" auto "canonical"
case_ "fleet-sync prune title" fleet-sync/prune-release ':fire:(fleet)= drop retired .github/workflows/release.yml' "" auto

# dependabot: the updated-dependencies trailer decides
case_ "dependabot one patch"          dependabot/go_modules/gomod-1 'bump go-gh in the gomod group' "$(trailer go-gh:patch)" auto "highest semver-patch"
case_ "dependabot group takes its highest (minor)" dependabot/npm_and_yarn/npm-2 'bump the npm group' "$(trailer a:minor b:patch c:patch)" auto "3 update(s), highest semver-minor"
case_ "dependabot group with a major is major" dependabot/npm_and_yarn/npm-3 'bump the npm group' "$(trailer a:patch b:major c:minor)" major "highest semver-major"
case_ "dependabot single major (actions/checkout 5 -> 7)" dependabot/github_actions/actions-4 'Bump actions/checkout from 5 to 7 in the actions group' "$(trailer actions/checkout:major)" major
case_ "dependabot SHA bump has no update-type: hold" dependabot/github_actions/actions-5 'Bump DeterminateSystems/nix-installer-action' "$(trailer DeterminateSystems/nix-installer-action)" hold "nix-installer-action has no semver update-type"
case_ "dependabot group with one SHA bump: hold, not the highest typed" dependabot/github_actions/actions-6 'Bump the actions group' "$(trailer a:patch sha/thing b:minor)" hold "sha/thing"
case_ "dependabot quoted name is unquoted in the detail" dependabot/npm_and_yarn/npm-7 'bump' "$(trailer '"@scope/pkg"')" hold "@scope/pkg has no"
case_ "dependabot no trailer at all: hold" dependabot/go_modules/gomod-8 'bump x from 1.0.0 to 2.0.0' "$(printf ':arrow_up:(deps) bump x from 1.0.0 to 2.0.0\n\nUpdates x from 1.0.0 to 2.0.0\n')" hold "no updated-dependencies trailer"
case_ "dependabot prose 'from A to B' never decides" dependabot/go_modules/gomod-9 'bump' "$(printf 'Bumps x from 1.0.0 to 9.0.0.\nRelease notes: migrated from 1 to 9.\n'; trailer x:patch)" auto "highest semver-patch"
case_ "dependabot two commits accumulate" dependabot/npm_and_yarn/npm-10 'bump' "$(trailer a:patch; trailer b:major)" major "2 update(s)"
case_ "dependabot update-type outside the trailer is ignored" dependabot/npm_and_yarn/npm-11 'bump' "$(printf 'note: update-type: version-update:semver-major\n'; trailer a:patch)" auto "1 update(s), highest semver-patch"

# anything else is nobody's bot
case_ "a feature branch is a hold" feature/thing 'some title (v1.0.0 -> v2.0.0)' "" hold "not a bot branch family"
case_ "a glyph-pin lookalike in another prefix is a hold" pin/glyph 'pin (v1.0.0 -> v1.0.1)' "" hold

[ "$fails" -eq 0 ] || { echo "$fails automerge-tier case(s) failed"; exit 1; }
echo "all automerge-tier cases passed"
