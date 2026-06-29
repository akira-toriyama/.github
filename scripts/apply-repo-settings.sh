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
#   ONLY=facet APPLY=1 ...                   # limit to one repo
#
# Safe baseline (always): delete_branch_on_merge, private vuln reporting (public
# repos), Dependabot alerts, Dependabot security updates. Token-flip / branch
# protection / immutable releases are opt-in because they need per-repo judgement.
set -uo pipefail

OWNER=akira-toriyama
APPLY="${APPLY:-0}"                       # 0 = dry run
ONLY="${ONLY:-}"
WITH_TOKEN_FLIP="${WITH_TOKEN_FLIP:-0}"
WITH_PROTECTION="${WITH_PROTECTION:-0}"
WITH_IMMUTABLE="${WITH_IMMUTABLE:-0}"

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
# Branch-protection allowlist. Empty = every repo with a commit-lint caller. Set it
# to keep the merge-blocking "lint / lint" check on the originally-intended app
# repos only (not every repo that gained a caller via a fleet-sync gap-fill).
PROTECT_REPOS="${PROTECT_REPOS:-}"

run() { # echo + (apply) a gh api mutation
  local desc="$1"; shift
  if [ "$APPLY" = "1" ]; then
    if "$@" >/dev/null 2>&1; then echo "    applied: $desc"; else echo "    ::FAILED:: $desc"; fi
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

echo "mode: $([ "$APPLY" = 1 ] && echo APPLY || echo DRY-RUN)  token-flip=$WITH_TOKEN_FLIP protection=$WITH_PROTECTION immutable=$WITH_IMMUTABLE"
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
  #    A real caller has a `uses: …/commit-lint.yml@` line (job `lint` ⇒ context
  #    "lint / lint"); the hub's commit-lint.yml is the REUSABLE (on: workflow_call,
  #    no caller line) so it is correctly skipped. For already-protected repos we
  #    PATCH only the status-check contexts (preserving enforce_admins / force-push
  #    / strict / reviews — a full PUT would reset allow_force_pushes etc.). For
  #    unprotected repos we PUT a fresh config matching the .github reference. Repos
  #    whose ruleset already requires it, or outside PROTECT_REPOS, are skipped.
  if [ "$WITH_PROTECTION" = "1" ] && { [ -z "$PROTECT_REPOS" ] || in_list "$R" "$PROTECT_REPOS"; }; then
    want="lint / lint"
    cl=$(gh api -H "Accept: application/vnd.github.raw" \
      "repos/$full/contents/.github/workflows/commit-lint.yml" 2>/dev/null || true)
    if ! printf '%s' "$cl" | grep -qE '^[[:space:]]*uses:[[:space:]]*akira-toriyama/\.github/\.github/workflows/commit-lint\.yml@'; then
      echo "    skip(protection): no commit-lint caller in $R"
    elif ruleset_requires "$full" "$want"; then
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
        body=$(jq -nc '{
          required_status_checks:{strict:false, contexts:["lint / lint"]},
          enforce_admins:false, required_pull_request_reviews:null, restrictions:null,
          allow_force_pushes:false, allow_deletions:false,
          required_linear_history:false, required_conversation_resolution:false
        }')
        run "protection(PUT new): require [lint / lint] (admin bypass, .github template)" \
          gh api -X PUT "repos/$full/branches/main/protection" --input - <<<"$body"
      fi
    fi
  fi

  # 7) immutable releases (opt-in; release repos only; verify rolling-draft compat first)
  if [ "$WITH_IMMUTABLE" = "1" ] && in_list "$R" "$RELEASE_REPOS"; then
    cur=$(gh api "repos/$full/immutable-releases" --jq '.enabled' 2>/dev/null || echo "?")
    [ "$cur" = "true" ] || run "immutable-releases=on" \
      gh api -X PUT "repos/$full/immutable-releases" -F enabled=true
  fi
done

echo
echo "done (mode: $([ "$APPLY" = 1 ] && echo APPLY || echo DRY-RUN))."
