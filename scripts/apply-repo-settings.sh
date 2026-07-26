#!/usr/bin/env bash
# apply-repo-settings.sh — idempotently apply akira-toriyama's recommended GitHub
# settings across the fleet (t-tvzh). The recipe is the one proven on `.github`
# (t-s7me). fleet-sync distributes *files*; THESE are *repo settings*, so they go
# through gh api here instead.
#
# Usage:
#   ./apply-repo-settings.sh                 # DRY RUN: report the diff, change nothing
#   APPLY=1 ./apply-repo-settings.sh         # apply the SAFE baseline (5 settings)
#   APPLY=1 WITH_TOKEN_FLIP=1 ...            # also flip default token -> read (see SKIP_TOKEN_FLIP)
#   APPLY=1 WITH_PROTECTION=1 ...            # also add the commit-lint required check (additive)
#   APPLY=1 WITH_IMMUTABLE=1 ...             # also enable immutable releases on release repos
#   APPLY=1 WITH_CODEQL_GO=1 ...             # also add CodeQL "go" (build) on GO_REPOS
#   ONLY=facet APPLY=1 ...                   # limit to one repo
#
# Safe baseline (always): delete_branch_on_merge, private vuln reporting (public
# repos), code scanning default setup (CodeQL "actions", public repos), Dependabot
# alerts, Dependabot security updates. Token-flip / branch protection / immutable
# releases / CodeQL-go are opt-in because they need per-repo judgement.
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

# Every mutation that failed, across every repo. A fleet-wide run makes hundreds
# of calls and prints hundreds of lines; without a tally the operator has to read
# all of them to notice that (say) an expired token 403'd every single one, and
# the script would still exit 0 under "done (mode: APPLY)".
failures=0

run() { # echo + (apply) a gh api mutation
  local desc="$1"; shift
  if [ "$APPLY" = "1" ]; then
    if "$@" >/dev/null 2>&1; then
      echo "    applied: $desc"
    else
      echo "    ::FAILED:: $desc"
      failures=$((failures + 1))
    fi
  else
    echo "    would: $desc"
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

mapfile -t REPOS < <(gh repo list "$OWNER" --no-archived --source --limit 200 \
  --json name,isFork,visibility -q '.[] | select(.isFork==false) | "\(.name)\t\(.visibility)"' | sort)
[ "${#REPOS[@]}" -ge 1 ] || { echo "::error:: empty repo list (transient API failure?)"; exit 1; }

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
  echo "== $R ($VIS) =="

  # 1) auto-delete head branch on merge
  cur=$(gh api "repos/$full" --jq '.delete_branch_on_merge' 2>/dev/null)
  [ "$cur" = "true" ] || run "delete_branch_on_merge=true" \
    gh api -X PATCH "repos/$full" -F delete_branch_on_merge=true

  # 2) private vulnerability reporting (public repos only; 404/N-A on private)
  if [ "$VIS" = "PUBLIC" ]; then
    cur=$(gh api "repos/$full/private-vulnerability-reporting" --jq '.enabled' 2>/dev/null || echo "?")
    [ "$cur" = "true" ] || run "private-vulnerability-reporting=on" \
      gh api -X PUT "repos/$full/private-vulnerability-reporting"
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
      # configured for other languages only -> add actions, preserve the rest (no clobber)
      body=$(printf '%s' "$cs" | jq -c '{state:"configured", languages:((.languages // [])+["actions"]|unique)}')
      run "code-scanning: add 'actions' to configured set $(printf '%s' "$cs" | jq -c '.languages')" \
        gh api -X PATCH "repos/$full/code-scanning/default-setup" --input - <<<"$body"
    elif [ "$cs_state" = "not-configured" ] && [ "$cs_has_actions" = 1 ]; then
      run "code-scanning default setup=configured (languages=[actions])" \
        gh api -X PATCH "repos/$full/code-scanning/default-setup" \
          --input - <<<'{"state":"configured","languages":["actions"]}'
    elif [ "$cs_state" = "not-configured" ]; then
      echo "    n/a: code scanning (no 'actions' language detected in $R)"
    else
      echo "    warn: code scanning state unreadable in $R (skipped; transient API failure?)"
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
        run "code-scanning: add 'go' to configured set $(printf '%s' "$cs" | jq -c '.languages') in $R" \
          gh api -X PATCH "repos/$full/code-scanning/default-setup" --input - <<<"$body"
      elif [ "$cs_state" = "not-configured" ]; then
        echo "    defer: code scanning not configured in $R yet — 'go' lands after the 'actions' baseline settles (re-run)"
      else
        echo "    warn: code scanning state unreadable in $R (go opt-in skipped; transient API failure?)"
      fi
    fi
  fi

  # 3) Dependabot alerts
  if gh api "repos/$full/vulnerability-alerts" >/dev/null 2>&1; then :; else
    run "vulnerability-alerts=on" gh api -X PUT "repos/$full/vulnerability-alerts"
  fi

  # 4) Dependabot security updates (needs alerts on)
  cur=$(gh api "repos/$full/automated-security-fixes" --jq '.enabled' 2>/dev/null || echo "?")
  [ "$cur" = "true" ] || run "automated-security-fixes=on" \
    gh api -X PUT "repos/$full/automated-security-fixes"

  # 5) default workflow GITHUB_TOKEN -> read (opt-in; skip the unverified ones)
  if [ "$WITH_TOKEN_FLIP" = "1" ]; then
    if in_list "$R" "$SKIP_TOKEN_FLIP"; then
      echo "    skip(token-flip): $R needs per-workflow permissions verification first"
    else
      cur=$(gh api "repos/$full/actions/permissions/workflow" --jq '.default_workflow_permissions' 2>/dev/null)
      [ "$cur" = "read" ] || run "default_workflow_permissions=read, can_approve=false" \
        gh api -X PUT "repos/$full/actions/permissions/workflow" \
          -F default_workflow_permissions=read -F can_approve_pull_request_reviews=false
    fi
  fi

  # 6) branch protection: make "lint / lint" a required check (admin bypass).
  #    A real caller is the file fleet-sync distributes (fleet/commit-lint.yml,
  #    job `lint` calling glyph's reusable ⇒ context "lint / lint"). The hub itself
  #    never appears here: fleet-sync EXCLUDEs `.github`, and its hand-maintained
  #    self-commit-lint.yml uses job id `commit-lint` ⇒ a different context.
  #    For already-protected repos we PATCH only the status-check contexts
  #    (preserving enforce_admins / force-push / strict / reviews — a full PUT
  #    would reset allow_force_pushes etc.). For unprotected repos we PUT a fresh
  #    config matching the .github reference. Repos whose ruleset already requires
  #    it, or outside PROTECT_REPOS, are skipped.
  if [ "$WITH_PROTECTION" = "1" ] && { [ -z "$PROTECT_REPOS" ] || in_list "$R" "$PROTECT_REPOS"; }; then
    want="lint / lint"
    protection_considered=$((protection_considered + 1))
    cl=$(gh api -H "Accept: application/vnd.github.raw" \
      "repos/$full/contents/.github/workflows/commit-lint.yml" 2>/dev/null || true)
    if ! printf '%s' "$cl" | grep -qE "^[[:space:]]*uses:[[:space:]]*${commit_lint_re}@"; then
      echo "    skip(protection): no commit-lint caller in $R"
    else
      protection_matched=$((protection_matched + 1))
      if ruleset_requires "$full" "$want"; then
        echo "    ok: a ruleset already requires '$want' in $R"
      else
        prot=$(gh api "repos/$full/branches/main/protection" 2>/dev/null) || prot=""
        if [ -n "$prot" ]; then
          existing=$(printf '%s' "$prot" | jq -r '(.required_status_checks.contexts // [])[]' 2>/dev/null || true)
          if printf '%s\n' "$existing" | grep -qxF "$want"; then
            echo "    ok: branch protection already requires '$want'"
          else
            strict=$(printf '%s' "$prot" | jq -r '.required_status_checks.strict // false' 2>/dev/null)
            merged=$(printf '%s\n%s\n' "$existing" "$want" | sed '/^$/d' | sort -u | jq -R . | jq -sc .)
            patch=$(jq -nc --argjson ctx "$merged" --argjson strict "$strict" '{strict:$strict, contexts:$ctx}')
            run "protection(PATCH): require [$(printf '%s' "$merged" | jq -r 'join(", ")')] (preserve other settings)" \
              gh api -X PATCH "repos/$full/branches/main/protection/required_status_checks" --input - <<<"$patch"
          fi
        else
          body=$(jq -nc --arg want "$want" '{
            required_status_checks:{strict:false, contexts:[$want]},
            enforce_admins:false, required_pull_request_reviews:null, restrictions:null,
            allow_force_pushes:false, allow_deletions:false,
            required_linear_history:false, required_conversation_resolution:false
          }')
          run "protection(PUT new): require [$want] (admin bypass, .github template)" \
            gh api -X PUT "repos/$full/branches/main/protection" --input - <<<"$body"
        fi
      fi
    fi
  fi

  # 7) immutable releases (opt-in; release repos only; release.yml hardened in #47).
  #    Toggle endpoint like vulnerability-alerts: bare PUT enables, DELETE disables —
  #    no body. (`enabled` is a GET-response field, not a writable key → 422.)
  if [ "$WITH_IMMUTABLE" = "1" ] && in_list "$R" "$RELEASE_REPOS"; then
    cur=$(gh api "repos/$full/immutable-releases" --jq '.enabled' 2>/dev/null || echo "?")
    [ "$cur" = "true" ] || run "immutable-releases=on" \
      gh api -X PUT "repos/$full/immutable-releases"
  fi
done

echo
echo "done (mode: $([ "$APPLY" = 1 ] && echo APPLY || echo DRY-RUN))."

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
exit "$rc"
