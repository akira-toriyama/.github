#!/usr/bin/env bash
# apply-repo-settings.sh — idempotently apply akira-toriyama's recommended GitHub
# settings across the fleet (t-tvzh). The recipe is the one proven on `.github`
# (t-s7me). fleet-sync distributes *files*; THESE are *repo settings*, so they go
# through gh api here instead. The safe baseline is reconciled by machine
# (.github/workflows/repo-settings-sync.yml: daily, and on every push to main that
# touches this script); the WITH_* opt-ins below are run by hand.
#
# Usage:
#   ./apply-repo-settings.sh                 # DRY RUN: report the diff, change nothing
#   APPLY=1 ./apply-repo-settings.sh         # apply the SAFE baseline (5 settings), read each write back
#   APPLY=1 WITH_TOKEN_FLIP=1 ...            # also flip default token -> read (see SKIP_TOKEN_FLIP)
#   APPLY=1 WITH_PROTECTION=1 ...            # also add the commit-lint required check (additive)
#   APPLY=1 WITH_IMMUTABLE=1 ...             # also enable immutable releases on release repos
#   APPLY=1 WITH_CODEQL_GO=1 ...             # also add CodeQL "go" (build) on GO_REPOS
#   ONLY=facet APPLY=1 ...                   # limit to one repo (the canary)
#
# Safe baseline (always): delete_branch_on_merge, private vuln reporting (public
# repos), code scanning default setup (CodeQL "actions", public repos), Dependabot
# alerts, Dependabot security updates. Token-flip / branch protection / immutable
# releases / CodeQL-go are opt-in because they need per-repo judgement.
#
# Contract for every setting, in both modes:
#   - a state this script could not READ is neither compliant nor drifted. It is
#     reported as `unreadable:`, never written to, and fails the run. The old shape
#     read every GET failure as drift: on 2026-09-24 a rate-limited token produced
#     37 repos x 2 false `would:` lines, and in APPLY mode would have PUT/PATCHed
#     every one of them (t-4ghh).
#   - `landed:` means the setting was re-read after the write and HOLDS. A 2xx
#     whose read-back does not show the change is a ::FAILED:: mutation; a
#     read-back that itself cannot read is `unreadable:` (the write was sent,
#     nothing is known). Code scanning is the one asynchronous API here: it is
#     reported `applied:` and confirmed by the next run.
set -uo pipefail

OWNER=akira-toriyama
APPLY="${APPLY:-0}"                       # 0 = dry run
ONLY="${ONLY:-}"
WITH_TOKEN_FLIP="${WITH_TOKEN_FLIP:-0}"
WITH_PROTECTION="${WITH_PROTECTION:-0}"
WITH_IMMUTABLE="${WITH_IMMUTABLE:-0}"
WITH_CODEQL_GO="${WITH_CODEQL_GO:-0}"

# Repos to skip entirely (space-separated).
EXCLUDE="${EXCLUDE:-}"
# Token-flip is only safe where every write-needing job already declares
# explicit permissions:. The only two write-default repos (akira-toriyama,
# dotfiles) were audited (rollout-analysis workflow) and BOTH verified safe —
# every write-needing job declares its own permissions: block; tracker writes use
# PROJECTS_WRITE_PAT, not the default token. So this list is empty. Add a repo
# here only if a future audit finds a job relying on the implicit write default.
SKIP_TOKEN_FLIP="${SKIP_TOKEN_FLIP:-}"
# Repos that run the rolling-DRAFT release flow (immutable-releases candidates).
RELEASE_REPOS="${RELEASE_REPOS:-chord facet halo perch wand}"
# Go repos to enable CodeQL `go` (compiled) analysis on, when WITH_CODEQL_GO=1.
# This is a hand-kept allowlist (CI cost is a per-repo call) — when creating a
# new Go repo, decide and add it here (t-tndq precedent: glyph).
GO_REPOS="${GO_REPOS:-cifail pare furrow glyph}"
# Branch-protection allowlist. Empty = every repo with a commit-lint caller. Set it
# to keep the merge-blocking "lint / lint" check on the originally-intended app
# repos only (not every repo that gained a caller via a fleet-sync gap-fill).
PROTECT_REPOS="${PROTECT_REPOS:-}"

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"

# Tallies across every repo. A fleet-wide run makes hundreds of calls and prints
# hundreds of lines; without them the operator has to read all of it to notice
# that (say) an expired token 403'd every single mutation, or that half the fleet
# was never read at all, and the script would still exit 0 under "done".
failures=0   # mutations that failed, or whose read-back shows the change did not take
landed=0     # mutations re-read after the write and confirmed
async=0      # mutations accepted by the one asynchronous API (code scanning) — not
             # confirmed in this run; a repo that shows up here every day is stuck
drift=0      # mutations a dry run WOULD make
unread=0     # settings this run could not read — reported, never written, and fatal
examined=0

errf="$(mktemp)"
trap 'rm -f "$errf"' EXIT

# A failed GET is retried once, unless its error is an answer (404) or a
# rate-limited token (not transient at this timescale — retrying only burns
# time). One blip must not turn the daily run red; a run that is red should be
# red for something the next run cannot heal by itself.
transient() { ! grep -qE 'HTTP 404|rate limit' "$errf"; }
# get_field <path> <jq> — the field's value; exit 1 = the GET failed (unreadable).
get_field() {
  local v try
  for try in 1 2; do
    if v=$(gh api "$1" --jq "$2" 2>"$errf"); then printf '%s\n' "$v"; return 0; fi
    transient || return 1
    [ "$try" = 1 ] && sleep 2
  done
  return 1
}
# get_toggle <path> — `on` (2xx) or `off` (404) for the bare-PUT/DELETE toggle
# endpoints (vulnerability-alerts, immutable-releases); exit 1 = any other failure.
get_toggle() {
  local try
  for try in 1 2; do
    if gh api "$1" >/dev/null 2>"$errf"; then echo on; return 0; fi
    if grep -q 'HTTP 404' "$errf"; then echo off; return 0; fi
    transient || return 1
    [ "$try" = 1 ] && sleep 2
  done
  return 1
}
# unreadable <what> [<consequence>] — report a state this run could not read.
unreadable() {
  echo "    unreadable: $1 in $R — ${2:-not touched this run} (transient API failure? rate limit?)"
  unread=$((unread + 1))
}

# holds <setting> — the read-back: re-fetch <setting> on $full. 0 = it is in its
# target state now; 1 = it is readable and is NOT; 2 = it could not be read (so
# nothing is known — neither "landed" nor "failed"). `protection` checks that
# every context in $want_ctxs (a JSON array) is required.
holds() {
  local v
  case "$1" in
    delete_branch_on_merge)          v=$(get_field "repos/$full" '.delete_branch_on_merge') || return 2; [ "$v" = "true" ] ;;
    private-vulnerability-reporting) v=$(get_field "repos/$full/private-vulnerability-reporting" '.enabled') || return 2; [ "$v" = "true" ] ;;
    vulnerability-alerts)            v=$(get_toggle "repos/$full/vulnerability-alerts") || return 2; [ "$v" = "on" ] ;;
    automated-security-fixes)        v=$(get_field "repos/$full/automated-security-fixes" '.enabled') || return 2; [ "$v" = "true" ] ;;
    default_workflow_permissions)    v=$(get_field "repos/$full/actions/permissions/workflow" '.default_workflow_permissions') || return 2; [ "$v" = "read" ] ;;
    immutable-releases)              v=$(get_field "repos/$full/immutable-releases" '.enabled') || return 2; [ "$v" = "true" ] ;;
    protection)
      v=$(get_field "repos/$full/branches/main/protection" '.required_status_checks.contexts // []') || return 2
      jq -e --argjson have "$v" 'all(.[]; . as $c | $have | index($c) != null)' <<<"$want_ctxs" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

# run <desc> <setting> <gh api mutation...> — dry-run: report; APPLY: mutate, then
# `holds <setting>` re-reads it. `-` skips the read-back for the one asynchronous
# API (code scanning), which the next run confirms.
run() {
  local desc="$1" setting="$2" hs; shift 2
  if [ "$APPLY" != "1" ]; then
    echo "    would: $desc"
    drift=$((drift + 1))
    return
  fi
  if ! "$@" >/dev/null 2>&1; then
    echo "    ::FAILED:: $desc"
    failures=$((failures + 1))
    return
  fi
  if [ "$setting" = "-" ]; then
    echo "    applied: $desc (asynchronous — the next run reads it back)"
    async=$((async + 1))
    return
  fi
  holds "$setting"; hs=$?
  if [ "$hs" -eq 0 ]; then
    echo "    landed: $desc"
    landed=$((landed + 1))
  elif [ "$hs" -eq 2 ]; then
    unreadable "$desc" "read-back after the write: the call returned 2xx, but this run cannot confirm it"
  else
    echo "    ::FAILED:: $desc — the call returned 2xx but the read-back does not show it"
    failures=$((failures + 1))
  fi
}

in_list() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# 0 if an active branch ruleset on repo $1 already requires status-check context $2.
ruleset_requires() {
  local f="$1" ctx="$2" id
  for id in $(gh api "repos/$f/rulesets" --jq '.[]|select(.target=="branch" and .enforcement=="active").id' 2>/dev/null); do
    if gh api "repos/$f/rulesets/$id" \
      --jq '[.rules[]|select(.type=="required_status_checks").parameters.required_status_checks[].context]' 2>/dev/null \
      | grep -qF "$ctx"; then return 0; fi
  done
  return 1
}

# Read the repo list WITHOUT `mapfile`: this script is run by hand, from the dev
# machine, and macOS ships bash 3.2 where mapfile does not exist. It used to abort
# with "mapfile: command not found" followed by "REPOS: unbound variable" — on the
# one platform its operator actually runs it from. (It only worked here because a
# newer bash happened to be earlier in PATH.)
#
# Check the raw text BEFORE building the array, so the array is never empty when
# it is expanded: bash 3.2 treats an empty array as unset under `set -u`.
repo_list="$(gh repo list "$OWNER" --no-archived --source --limit 200 \
  --json name,isFork,visibility -q '.[] | select(.isFork==false) | "\(.name)\t\(.visibility)"' | sort)"
[ -n "$repo_list" ] || { echo "::error:: empty repo list (transient API failure?)"; exit 1; }
REPOS=()
while IFS= read -r repo_line; do
  [ -n "$repo_line" ] || continue
  REPOS+=("$repo_line")
done < <(printf '%s\n' "$repo_list")

# The `uses:` line fleet-sync actually distributes as each repo's commit-lint
# caller, DERIVED from the canonical rather than restated here. The literal that
# used to live at the detector below still named the hub's own commit-lint
# reusable, which #82 repointed at glyph on 2026-07-12 and #111 later deleted —
# so for two weeks every repo failed the match, every repo printed
# "skip(protection)", and WITH_PROTECTION=1 applied nothing while exiting 0.
# Reading the canonical means the next repoint moves this with it.
commit_lint_uses="$(awk '$1 == "uses:" && $2 ~ /^akira-toriyama\// { sub(/@.*$/, "", $2); print $2; exit }' \
  "$root/fleet/commit-lint.yml")"
[ -n "$commit_lint_uses" ] || {
  echo "::error:: could not read the caller \`uses:\` from $root/fleet/commit-lint.yml"
  echo "          without it the protection detector matches nothing and skips the whole fleet silently"
  exit 1
}
# Escape for ERE: the path is full of dots that would otherwise be wildcards.
commit_lint_re="${commit_lint_uses//./[.]}"
protection_considered=0
protection_matched=0

echo "mode: $([ "$APPLY" = 1 ] && echo APPLY || echo DRY-RUN)  token-flip=$WITH_TOKEN_FLIP protection=$WITH_PROTECTION immutable=$WITH_IMMUTABLE codeql-go=$WITH_CODEQL_GO"
echo

for line in "${REPOS[@]}"; do
  R="${line%%$'\t'*}"; VIS="${line##*$'\t'}"
  in_list "$R" "$EXCLUDE" && { echo "skip(excluded): $R"; continue; }
  [ -n "$ONLY" ] && [ "$R" != "$ONLY" ] && continue
  full="$OWNER/$R"
  examined=$((examined + 1))
  echo "== $R ($VIS) =="

  # 1) auto-delete head branch on merge
  if cur=$(get_field "repos/$full" '.delete_branch_on_merge'); then
    [ "$cur" = "true" ] || run "delete_branch_on_merge=true" delete_branch_on_merge \
      gh api -X PATCH "repos/$full" -F delete_branch_on_merge=true
  else
    unreadable "delete_branch_on_merge"
  fi

  # 2) private vulnerability reporting (public repos only; 404/N-A on private)
  if [ "$VIS" = "PUBLIC" ]; then
    if cur=$(get_field "repos/$full/private-vulnerability-reporting" '.enabled'); then
      [ "$cur" = "true" ] || run "private-vulnerability-reporting=on" private-vulnerability-reporting \
        gh api -X PUT "repos/$full/private-vulnerability-reporting"
    else
      unreadable "private-vulnerability-reporting"
    fi
  else
    echo "    n/a: private vuln reporting (private repo)"
  fi

  # 2b) code scanning default setup — CodeQL "actions" (workflow-YAML) analysis.
  #    Public repos only (free; private needs GitHub Advanced Security). Scoped to
  #    `actions` ON PURPOSE — the no-build analysis that catches the script-injection
  #    / over-broad-permissions patterns we audit by hand. Omitting `languages` would
  #    auto-enable EVERY *detected* language (swift/go/c-cpp/ruby/…) i.e. heavy build
  #    jobs on every PR — a separate per-repo decision, not this baseline. The GET
  #    returns the detectable languages even when not-configured, so we guard on it:
  #    repos with no `actions` (no workflows: prq/rundiff) are skipped, and a repo
  #    already configured for actions is a no-op. If configured for *other* languages
  #    only, we ADD actions (union) rather than clobber the existing set. A GET that
  #    fails (transient) yields state "?" -> warn+skip, never a false "no actions".
  if [ "$VIS" = "PUBLIC" ]; then
    # `|| cs='{}'` discards gh's error *body* (which it writes to stdout on failure)
    # so a transient GET can't masquerade as a real not-configured / no-actions repo.
    cs=$(gh api "repos/$full/code-scanning/default-setup" 2>/dev/null) || cs='{}'
    cs_state=$(printf '%s' "$cs" | jq -r '.state // "?"')
    cs_has_actions=$(printf '%s' "$cs" | jq -e '(.languages // [])|index("actions")' >/dev/null 2>&1 && echo 1 || echo 0)
    if [ "$cs_state" = "configured" ] && [ "$cs_has_actions" = 1 ]; then
      echo "    ok: code scanning already configured (actions) in $R"
    elif [ "$cs_state" = "configured" ]; then
      body=$(printf '%s' "$cs" | jq -c '{state:"configured", languages:((.languages // [])+["actions"]|unique)}')
      run "code-scanning: add 'actions' to configured set $(printf '%s' "$cs" | jq -c '.languages')" - \
        gh api -X PATCH "repos/$full/code-scanning/default-setup" --input - <<<"$body"
    elif [ "$cs_state" = "not-configured" ] && [ "$cs_has_actions" = 1 ]; then
      run "code-scanning default setup=configured (languages=[actions])" - \
        gh api -X PATCH "repos/$full/code-scanning/default-setup" \
          --input - <<<'{"state":"configured","languages":["actions"]}'
    elif [ "$cs_state" = "not-configured" ]; then
      echo "    n/a: code scanning (no 'actions' language detected in $R)"
    else
      unreadable "code scanning default setup"
    fi
  else
    echo "    n/a: code scanning default setup (private repo; needs GH Advanced Security)"
  fi

  # 2c) CodeQL `go` — OPT-IN compiled analysis for the curated Go repos. It catches
  #    code patterns (SQL injection / path traversal / tampering) that govulncheck
  #    (reachable known-CVEs) does NOT — the two are complementary. Unlike the
  #    no-build `actions` baseline (2b), `go` runs a BUILD every PR, so it is gated
  #    behind WITH_CODEQL_GO + the GO_REPOS allowlist (a per-repo CI-cost call — the
  #    same axis on which swift/go were kept OUT of the always-on baseline). `go` is
  #    UNIONed into the language set, so it never clobbers the `actions` baseline. It
  #    only unions into an ALREADY-configured setup; a not-yet-configured repo is left
  #    for 2b to set `actions` first (that PATCH is async) and picks `go` up on the
  #    NEXT run — never a same-run clobber of the just-set baseline.
  if [ "$WITH_CODEQL_GO" = "1" ] && in_list "$R" "$GO_REPOS"; then
    if [ "$VIS" != "PUBLIC" ]; then
      echo "    n/a: CodeQL 'go' opt-in ($R is private; needs GH Advanced Security)"
    else
      cs=$(gh api "repos/$full/code-scanning/default-setup" 2>/dev/null) || cs='{}'
      cs_state=$(printf '%s' "$cs" | jq -r '.state // "?"')
      cs_has_go=$(printf '%s' "$cs" | jq -e '(.languages // [])|index("go")' >/dev/null 2>&1 && echo 1 || echo 0)
      if [ "$cs_state" = "configured" ] && [ "$cs_has_go" = 1 ]; then
        echo "    ok: code scanning already analyzes 'go' in $R"
      elif [ "$cs_state" = "configured" ]; then
        body=$(printf '%s' "$cs" | jq -c '{state:"configured", languages:((.languages // [])+["go"]|unique)}')
        run "code-scanning: add 'go' to configured set $(printf '%s' "$cs" | jq -c '.languages') in $R" - \
          gh api -X PATCH "repos/$full/code-scanning/default-setup" --input - <<<"$body"
      elif [ "$cs_state" = "not-configured" ]; then
        echo "    defer: code scanning not configured in $R yet — 'go' lands after the 'actions' baseline settles (re-run)"
      else
        unreadable "code scanning default setup (go opt-in)"
      fi
    fi
  fi

  # 3) Dependabot alerts (toggle endpoint: 204 = on, 404 = off)
  if cur=$(get_toggle "repos/$full/vulnerability-alerts"); then
    [ "$cur" = "on" ] || run "vulnerability-alerts=on" vulnerability-alerts \
      gh api -X PUT "repos/$full/vulnerability-alerts"
  else
    unreadable "vulnerability-alerts"
  fi

  # 4) Dependabot security updates (needs alerts on)
  if cur=$(get_field "repos/$full/automated-security-fixes" '.enabled'); then
    [ "$cur" = "true" ] || run "automated-security-fixes=on" automated-security-fixes \
      gh api -X PUT "repos/$full/automated-security-fixes"
  else
    unreadable "automated-security-fixes"
  fi

  # 5) default workflow GITHUB_TOKEN -> read (opt-in; skip the unverified ones)
  if [ "$WITH_TOKEN_FLIP" = "1" ]; then
    if in_list "$R" "$SKIP_TOKEN_FLIP"; then
      echo "    skip(token-flip): $R needs per-workflow permissions verification first"
    elif cur=$(get_field "repos/$full/actions/permissions/workflow" '.default_workflow_permissions'); then
      [ "$cur" = "read" ] || run "default_workflow_permissions=read, can_approve=false" default_workflow_permissions \
        gh api -X PUT "repos/$full/actions/permissions/workflow" \
          -F default_workflow_permissions=read -F can_approve_pull_request_reviews=false
    else
      unreadable "default_workflow_permissions"
    fi
  fi

  # 6) branch protection: make the repo's required checks required (admin bypass).
  #    "lint / lint" for every repo carrying the fleet's commit-lint caller (the
  #    file fleet-sync distributes: fleet/commit-lint.yml, job `lint` calling
  #    glyph's reusable ⇒ context "lint / lint"). The hub itself never appears
  #    here: fleet-sync EXCLUDEs `.github`, and its hand-maintained
  #    self-commit-lint.yml uses job id `commit-lint` ⇒ a different context.
  #    PLUS "build" — but only where a check-run named `build` exists on the
  #    default branch HEAD (t-jvdr). The swift family's `build` was hand-added
  #    per repo, so every new repo opened the same hole: red bite/build PRs that
  #    were still mergeable. The probe is ground truth, not file inference: a
  #    required context that no run produces wedges every PR invisibly (the
  #    t-c51t shape), so we require only what the repo demonstrably runs — a
  #    build.yml whose job never fired on main is exactly the case to skip.
  #    For already-protected repos we PATCH only the status-check contexts
  #    (preserving enforce_admins / force-push / strict / reviews — a full PUT
  #    would reset allow_force_pushes etc.). For unprotected repos we PUT a fresh
  #    config matching the .github reference. Contexts an active ruleset already
  #    requires, and repos outside PROTECT_REPOS, are skipped.
  if [ "$WITH_PROTECTION" = "1" ] && { [ -z "$PROTECT_REPOS" ] || in_list "$R" "$PROTECT_REPOS"; }; then
    protection_considered=$((protection_considered + 1))
    cl=$(gh api -H "Accept: application/vnd.github.raw" \
      "repos/$full/contents/.github/workflows/commit-lint.yml" 2>/dev/null || true)
    if ! printf '%s' "$cl" | grep -qE "^[[:space:]]*uses:[[:space:]]*${commit_lint_re}@"; then
      echo "    skip(protection): no commit-lint caller in $R"
    else
      protection_matched=$((protection_matched + 1))
      wants="lint / lint"
      if cr=$(gh api "repos/$full/commits/HEAD/check-runs" --jq '[.check_runs[].name]' 2>/dev/null); then
        if printf '%s' "$cr" | jq -e 'index("build") != null' >/dev/null 2>&1; then
          wants=$(printf 'build\n%s' "$wants")
        fi
      else
        echo "    warn: cannot read check-runs on $R@HEAD — 'build' not considered this run (the next run heals)"
      fi
      need=""
      while IFS= read -r w; do
        [ -n "$w" ] || continue
        if ruleset_requires "$full" "$w"; then
          echo "    ok: a ruleset already requires '$w' in $R"
        else
          need="$need$w
"
        fi
      done <<<"$wants"
      if [ -z "$need" ]; then
        : # every wanted context is ruleset-held
      else
        # An unprotected branch is a 404; anything else is a state this run must
        # not act on — a fresh PUT over protection it merely failed to read would
        # reset force-push / reviews / strict on a repo that had them.
        if prot=$(gh api "repos/$full/branches/main/protection" 2>"$errf"); then :
        elif grep -q 'HTTP 404' "$errf"; then prot=""
        else unreadable "branch protection"; prot="?"
        fi
        if [ "$prot" = "?" ]; then
          :
        elif [ -n "$prot" ]; then
          existing=$(printf '%s' "$prot" | jq -r '(.required_status_checks.contexts // [])[]' 2>/dev/null || true)
          missing=$(printf '%s' "$need" | while IFS= read -r w; do
            [ -n "$w" ] || continue
            printf '%s\n' "$existing" | grep -qxF "$w" || printf '%s\n' "$w"
          done)
          if [ -z "$missing" ]; then
            echo "    ok: branch protection already requires [$(printf '%s' "$need" | sed '/^$/d' | jq -R . | jq -rsc 'join(", ")')]"
          else
            strict=$(printf '%s' "$prot" | jq -r '.required_status_checks.strict // false' 2>/dev/null)
            merged=$(printf '%s\n%s\n' "$existing" "$missing" | sed '/^$/d' | sort -u | jq -R . | jq -sc .)
            patch=$(jq -nc --argjson ctx "$merged" --argjson strict "$strict" '{strict:$strict, contexts:$ctx}')
            want_ctxs="$merged"
            run "protection(PATCH): require [$(printf '%s' "$merged" | jq -r 'join(", ")')] (preserve other settings)" protection \
              gh api -X PATCH "repos/$full/branches/main/protection/required_status_checks" --input - <<<"$patch"
          fi
        else
          ctxs=$(printf '%s' "$need" | sed '/^$/d' | sort -u | jq -R . | jq -sc .)
          body=$(jq -nc --argjson ctx "$ctxs" '{
            required_status_checks:{strict:false, contexts:$ctx},
            enforce_admins:false, required_pull_request_reviews:null, restrictions:null,
            allow_force_pushes:false, allow_deletions:false,
            required_linear_history:false, required_conversation_resolution:false
          }')
          want_ctxs="$ctxs"
          run "protection(PUT new): require [$(printf '%s' "$ctxs" | jq -r 'join(", ")')] (admin bypass, .github template)" protection \
            gh api -X PUT "repos/$full/branches/main/protection" --input - <<<"$body"
        fi
      fi
    fi
  fi

  # 7) immutable releases (opt-in; release repos only; release.yml hardened in #47).
  #    Toggle endpoint like vulnerability-alerts: bare PUT enables, DELETE disables —
  #    no body. (`enabled` is a GET-response field, not a writable key → 422.)
  if [ "$WITH_IMMUTABLE" = "1" ] && in_list "$R" "$RELEASE_REPOS"; then
    if cur=$(get_field "repos/$full/immutable-releases" '.enabled'); then
      [ "$cur" = "true" ] || run "immutable-releases=on" immutable-releases \
        gh api -X PUT "repos/$full/immutable-releases"
    else
      unreadable "immutable-releases"
    fi
  fi
done

echo
if [ "$APPLY" = "1" ]; then
  echo "done (mode: APPLY): landed=$landed async=$async failed=$failures unreadable=$unread across $examined repo(s)"
else
  echo "done (mode: DRY-RUN — NOTHING WAS APPLIED): would=$drift unreadable=$unread across $examined repo(s)"
fi

# Fail loud on the two ways this script has silently done nothing.
#
# A detector that matches ZERO repos is the shape of bug that hid here for two
# weeks: it is indistinguishable, in the log, from a fleet that is simply already
# compliant. Every repo carrying a caller is the norm — fleet-sync puts one in all
# of them — so zero matches out of a non-empty candidate list means the caller's
# shape moved, not that the fleet stopped using commit-lint.
rc=0
if [ "$WITH_PROTECTION" = "1" ] && [ "$protection_considered" -gt 0 ] && [ "$protection_matched" -eq 0 ]; then
  echo "::error:: WITH_PROTECTION=1 examined $protection_considered repo(s) and matched NONE."
  echo "          Expected \`uses: $commit_lint_uses@…\` (read from fleet/commit-lint.yml)."
  echo "          Either the fleet has not been synced with that caller, or the canonical moved again."
  rc=1
fi
if [ "$failures" -gt 0 ]; then
  echo "::error:: $failures mutation(s) FAILED — see the ::FAILED:: lines above."
  rc=1
fi
# Fail loud, not open: a run that could not read a setting must not be green,
# because its green would read as "compliant" for repos it never saw.
if [ "$unread" -gt 0 ]; then
  echo "::error:: $unread setting(s) could not be read — this run says nothing about them (see the unreadable: lines above)."
  rc=1
fi
# ONLY= is the canary. A name that matches nothing (a typo, an archived repo, a
# fork) must not read as a clean canary over zero repos.
if [ -n "$ONLY" ] && [ "$examined" -eq 0 ]; then
  echo "::error:: ONLY=$ONLY matched no repo — nothing was examined (typo? archived? a fork?)."
  rc=1
fi
exit "$rc"
