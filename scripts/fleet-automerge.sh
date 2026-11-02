#!/usr/bin/env bash
# Arm auto-merge on the fleet's bot pull requests that a person never reads:
# glyph-pin/ and fleet-sync/ pulls the hub itself opened, and dependabot/ bumps
# below a major. fleet-automerge.yml runs this with FLEET_SYNC_PAT.
#
#   usage:  fleet-automerge.sh <owner> [only-repo]
#   env:    APPLY=1 arms; anything else is a dry run that reads everything and
#           writes nothing (the fleet-sync shape: dispatch defaults to dry)
#   stdout: one line per pull request the run had an opinion on —
#             armed / merged-now / would-arm / major-left / held /
#             already-armed / skipped(no-auto-merge) / skipped(unprotected) /
#             failed
#           then `done: …` with every count, and the same as a step-summary
#           table when GITHUB_STEP_SUMMARY is set
#   exit:   0 when nothing failed; 1 when any read or arm failed, or the repo
#           list could not be read; 2 usage
#
# WHO MERGES, AND WHY IT MUST BE THE PAT. Measured on glyph-test (t-ksee,
# 2026-09-27, pulls #97-#100): an auto-merge that GITHUB_TOKEN armed lands as
# github-actions[bot]'s merge and raises NO `on: push` run on the default
# branch — a repo's release.yml never sees the pin move. Armed by the PAT user it
# lands as that user's merge and Release / commit-lint start within seconds. So
# this runs in the hub, with fleet-sync's credential, and never in a consumer.
#
# THE REVIEWER IS THE REPO'S REQUIRED CHECKS. `gh pr merge --auto` arms a merge
# GitHub performs once the branch protection is satisfied; on a branch with no
# protection GitHub refuses to arm at all, so an unprotected repo is skipped and
# counted, never merged blind. The two refusals classified below are measured
# text, not guessed (fleet-test #1 for the first, glyph-test #101 for the
# second, both `gh pr merge --auto --squash`):
#   GraphQL: Pull request Protected branch rules not configured for this branch (enablePullRequestAutoMerge)
#   GraphQL: Auto merge is not allowed for this repository (enablePullRequestAutoMerge)
# A pull request whose checks already pass is merged on the spot by gh (that is
# what --auto does when nothing is pending) — reported as merged-now. gh decides
# that from one read of the pull, so a pull that turns CLEAN between gh's read
# and its mutation is refused with a third measured text (dotfiles#406, run
# 37215471110, 2026-10-04) and this merges it outright, which is what gh would
# have done a moment later:
#   GraphQL: Pull request Pull request is in clean status (enablePullRequestAutoMerge)
# Any other refusal is a failure that reds the run — a new message is a new fact
# to read, not a case to wave through.
# Under `required_status_checks.strict` a BEHIND pull stays armed and waits
# (measured, #99); glyph-pin-land rebuilds its branches nightly, dependabot
# rebases its own, and apply-repo-settings levels strict to false.
#
# WHAT A PERSON KEEPS. A major (either family), anything automerge-tier.sh cannot
# classify, a draft, a merge conflict, a pull labelled `hold`, a pull whose
# author is not the family's bot, and a pull not aimed at the default branch.
# Each is one log line with the title, so the daily log IS the list to read.
#
# READ-BACK. An arm that gh reports as success is re-read: the pull must now
# show an auto-merge request or be MERGED; anything else is `failed`, because
# "gh exited 0" is a claim and the pull request is the measurement. A read-back
# that itself cannot read fails WITH gh's words in the line — glyph-test#113
# (run 36528379136, 2026-09-29) failed with them discarded, and the pull turned
# out to be merged; the cause is still unknown because nothing kept it.
#
# THE REBASE NUDGE (t-ezyr; NUDGE=1 while it is staged). An armed dependabot
# pull stays BLOCKED for days when a required check is red on its head and the
# fix landed on the base afterwards: strict=false means GitHub never calls it
# BEHIND, and dependabot rebases only on a conflict. Measured 2026-10-23..11-02:
# glyph#315 / cifail#49 / prq#52 (71-77h), prq#50 (226h), dotfiles#418 (17h),
# each released by a hand-typed `@dependabot rebase` and merged within minutes.
# So when an armed dependabot pull is BLOCKED, behind its base, and a check-run
# the base's classic protection requires is red on its head, this comments
# `@dependabot rebase` and reads the comment back — once per head: any such
# comment newer than the head commit, a person's included, is the nudge already
# in. A base without classic protection (a ruleset repo) is left alone and said
# so. glyph-pin/ pulls need none of this: glyph-pin-land rebuilds them nightly.
#
# `hold` is a plain label — nothing creates it; put it on a pull request and
# this leaves that pull alone until it is removed.
set -uo pipefail

owner="${1:-}"; only="${2:-}"
if [ -z "$owner" ]; then
  echo "usage: fleet-automerge.sh <owner> [only-repo]" >&2
  exit 2
fi
apply="${APPLY:-0}"
dry=true; [ "$apply" = "1" ] && dry=false
# The rebase nudge (header) is gated while it is staged (t-ezyr): only a run
# that sets NUDGE=1 asks dependabot to rebase; every other run logs the same
# already-armed line as before and reads nothing extra.
nudge="${NUDGE:-0}"

here="$(cd "$(dirname "$0")" && pwd)"
tier="$here/automerge-tier.sh"
[ -f "$tier" ] || { echo "::error::fleet-automerge: $tier is missing" >&2; exit 1; }

armed=0 merged_now=0 would_arm=0 major_left=0 held=0 already_armed=0
rebase_asked=0 would_rebase=0 skipped_no_auto=0 skipped_unprotected=0 failed=0 nrepos=0

fail() { echo "::error::fleet-automerge: failed: $1"; failed=$((failed + 1)); }
# gh's own words, flattened and capped, for a log line that has to stand alone.
oneline() { printf '%s' "$1" | tr '\n' ' ' | head -c 300; }
errf="$(mktemp)"; trap 'rm -f "$errf"' EXIT

# nudge_rebase — the caller has an armed, BLOCKED dependabot/ pull in $full/$num
# at head $sha against $db (header: THE REBASE NUDGE). Reads, in order: behind
# count, failing check-runs on the head, the base's classic required contexts,
# the head commit's date, the pull's `@dependabot rebase` comments. Prints its
# own line and counts it, returning 0, when the pull was nudged, had been nudged
# on this head already, or sits on a base without classic protection; returns 1
# when the pull is merely armed and waiting, so the caller logs already-armed.
# A read that fails is a `failed`, never a silent skip (the script's contract).
nudge_rebase() {
  case "$author" in app/dependabot|dependabot|"dependabot[bot]") ;; *) return 1 ;; esac
  local behind failing req ctx red head_at asked_at err
  if ! behind="$(gh api "repos/$full/compare/$db...$sha" --jq '.behind_by' 2>/dev/null </dev/null)"; then
    fail "$tag cannot compare its head with $db — $title"; return 0
  fi
  [ "$behind" -gt 0 ] 2>/dev/null || return 1
  if ! failing="$(gh api --paginate "repos/$full/commits/$sha/check-runs" --jq '.check_runs[] | select(.conclusion == "failure") | .name' 2>/dev/null </dev/null)"; then
    fail "$tag cannot read the check-runs on its head — $title"; return 0
  fi
  [ -n "$failing" ] || return 1
  if ! req="$(gh api "repos/$full/branches/$db/protection/required_status_checks" --jq '.contexts[]' 2>"$errf" </dev/null)"; then
    if grep -q 'HTTP 404' "$errf"; then
      echo "already-armed: $tag $behind behind $db with a red check, but $db has no classic protection naming the required checks — left alone — $title"
      already_armed=$((already_armed + 1)); return 0
    fi
    fail "$tag cannot read the required checks of $db: $(oneline "$(cat "$errf")") — $title"; return 0
  fi
  red=""
  while IFS= read -r ctx; do
    [ -n "$ctx" ] || continue
    if printf '%s\n' "$failing" | grep -qxF "$ctx"; then red="$ctx"; break; fi
  done <<<"$req"
  [ -n "$red" ] || return 1
  if ! head_at="$(gh api "repos/$full/commits/$sha" --jq '.commit.committer.date' 2>/dev/null </dev/null)"; then
    fail "$tag cannot read its head commit — $title"; return 0
  fi
  # Newest `@dependabot rebase` comment on the pull, whoever wrote it; ISO-8601
  # UTC strings order as text.
  if ! asked_at="$(gh api --paginate "repos/$full/issues/$num/comments" --jq '.[] | select(.body | test("^\\s*@dependabot rebase\\b")) | .created_at' 2>/dev/null </dev/null | sort | tail -n 1)"; then
    fail "$tag cannot read its comments — $title"; return 0
  fi
  if [ -n "$asked_at" ] && [[ "$asked_at" > "$head_at" ]]; then
    echo "already-armed: $tag rebase asked at $asked_at for this head ($red red, $behind behind $db) — $title"
    already_armed=$((already_armed + 1)); return 0
  fi
  if [ "$apply" != "1" ]; then
    echo "would-rebase: $tag $red is red on a head $behind behind $db — $title"; would_rebase=$((would_rebase + 1)); return 0
  fi
  if ! err="$(gh pr comment "$num" --repo "$full" --body '@dependabot rebase' 2>&1 </dev/null)"; then
    fail "$tag asking dependabot to rebase was refused: $(oneline "$err") — $title"; return 0
  fi
  if ! asked_at="$(gh api --paginate "repos/$full/issues/$num/comments" --jq '.[] | select(.body | test("^\\s*@dependabot rebase\\b")) | .created_at' 2>/dev/null </dev/null | sort | tail -n 1)" \
     || [ -z "$asked_at" ] || ! [[ "$asked_at" > "$head_at" ]]; then
    fail "$tag asked dependabot to rebase, but the read-back shows no such comment — $title"; return 0
  fi
  echo "rebase-asked: $tag $red is red on a head $behind behind $db — $title"; rebase_asked=$((rebase_asked + 1)); return 0
}

if [ -n "$only" ]; then
  repos="$only"
else
  repos="$(gh repo list "$owner" --no-archived --source --limit 200 --json name --jq '.[].name' 2>/dev/null | sort)" \
    || { echo "::error::fleet-automerge: cannot list $owner's repositories" >&2; exit 1; }
  [ -n "$repos" ] || { echo "::error::fleet-automerge: the repository list is empty — refusing to call that a fleet run" >&2; exit 1; }
fi

candidates='[.[] | select(.headRefName | test("^(glyph-pin|fleet-sync|dependabot)/"))] | sort_by(.number) | .[]
  | [.number, .headRefName, .baseRefName, .author.login, .isDraft, .mergeStateStatus,
     (.autoMergeRequest != null), ([.labels[].name] | index("hold") != null), .headRefOid, .title] | @tsv'

# The pull list is read on fd 3: gh inside the loop must not eat the loop's
# own stdin.
while IFS= read -r -u 4 name; do
  [ -n "$name" ] || continue
  nrepos=$((nrepos + 1))
  full="$owner/$name"

  if ! settings="$(gh api "repos/$full" --jq '[(.allow_auto_merge|tostring), .default_branch] | @tsv' 2>/dev/null </dev/null)"; then
    fail "$full cannot read the repository settings"; continue
  fi
  allow="${settings%%	*}"; db="${settings#*	}"

  if ! prs="$(gh pr list --repo "$full" --state open --limit 50 \
        --json number,title,headRefName,baseRefName,author,labels,isDraft,mergeStateStatus,autoMergeRequest,headRefOid \
        --jq "$candidates" 2>/dev/null </dev/null)"; then
    fail "$full cannot list its open pull requests"; continue
  fi
  [ -n "$prs" ] || continue

  if [ "$allow" != "true" ]; then
    n="$(printf '%s\n' "$prs" | grep -c .)"
    echo "skipped(no-auto-merge): $full allow_auto_merge=false ($n candidate pull request(s) left to a person)"
    skipped_no_auto=$((skipped_no_auto + n)); continue
  fi

  while IFS=$'\t' read -r -u 3 num head base author draft ms armed_already hold sha title; do
    family="${head%%/*}"
    tag="$full#$num $family"

    if [ "$draft" = "true" ]; then echo "held: $tag draft — $title"; held=$((held + 1)); continue; fi
    if [ "$hold" = "true" ]; then echo "held: $tag label hold — $title"; held=$((held + 1)); continue; fi
    if [ "$armed_already" = "true" ]; then
      if [ "$nudge" = "1" ] && [ "$family" = "dependabot" ] && [ "$ms" = "BLOCKED" ] && nudge_rebase; then continue; fi
      echo "already-armed: $tag — $title"; already_armed=$((already_armed + 1)); continue
    fi
    if [ "$base" != "$db" ]; then echo "held: $tag base $base is not the default branch $db — $title"; held=$((held + 1)); continue; fi
    case "$family" in
      dependabot)
        case "$author" in app/dependabot|dependabot|"dependabot[bot]") ;;
          *) echo "held: $tag author $author is not dependabot — $title"; held=$((held + 1)); continue ;;
        esac ;;
      *)
        if [ "$author" != "$owner" ]; then echo "held: $tag author $author is not the hub's PAT user $owner — $title"; held=$((held + 1)); continue; fi ;;
    esac

    if [ "$family" = "dependabot" ]; then
      if ! msgs="$(gh api "repos/$full/pulls/$num/commits" --jq '.[].commit.message' 2>/dev/null </dev/null)"; then
        fail "$tag cannot read its commits — $title"; continue
      fi
      verdict="$(printf '%s\n' "$msgs" | bash "$tier" "$head" "$title")"
    else
      verdict="$(bash "$tier" "$head" "$title" </dev/null)"
    fi
    v="${verdict%%	*}"; detail="${verdict#*	}"
    case "$v" in
      major) echo "major-left: $tag $detail — $title"; major_left=$((major_left + 1)); continue ;;
      auto) ;;
      *)     echo "held: $tag $detail — $title"; held=$((held + 1)); continue ;;
    esac
    if [ "$ms" = "DIRTY" ]; then echo "held: $tag merge conflict — $title"; held=$((held + 1)); continue; fi
    if [ "$apply" != "1" ]; then echo "would-arm: $tag $detail — $title"; would_arm=$((would_arm + 1)); continue; fi

    if ! err="$(gh pr merge "$num" --repo "$full" --auto --squash 2>&1 </dev/null)"; then
      case "$err" in
        *"is in clean status"*)
          # gh arms only a pull it read as not yet mergeable and merges a CLEAN
          # one outright (merge.go: autoMerge = enable && !isImmediatelyMergeable);
          # a pull that turns CLEAN between that read and the mutation is refused
          # with this text (dotfiles#406, run 37215471110, 2026-10-04). Merge it
          # outright, as gh would have: CLEAN means the required checks passed.
          if ! err="$(gh pr merge "$num" --repo "$full" --squash 2>&1 </dev/null)"; then
            fail "$tag turned clean while arming, and the outright merge was refused: $(oneline "$err") — $title"; continue
          fi ;;
        *"Protected branch rules not configured"*)
          echo "skipped(unprotected): $tag the base branch has no protection, so auto-merge cannot be armed — $title"
          skipped_unprotected=$((skipped_unprotected + 1)); continue ;;
        *"not allowed"*|*"not enabled"*)
          echo "skipped(no-auto-merge): $tag auto-merge is not allowed on this repository — $title"
          skipped_no_auto=$((skipped_no_auto + 1)); continue ;;
        *) fail "$tag arm refused: $(oneline "$err") — $title"; continue ;;
      esac
    fi
    if ! back="$(gh pr view "$num" --repo "$full" --json state,autoMergeRequest --jq '[.state, (.autoMergeRequest != null)] | @tsv' 2>"$errf" </dev/null)"; then
      fail "$tag armed, but the read-back failed: $(oneline "$(cat "$errf")") — $title"; continue
    fi
    state="${back%%	*}"; armed_now="${back#*	}"
    if [ "$state" = "MERGED" ]; then
      echo "merged-now: $tag $detail — $title"; merged_now=$((merged_now + 1))
    elif [ "$armed_now" = "true" ]; then
      echo "armed: $tag $detail — $title"; armed=$((armed + 1))
    else
      fail "$tag arm answered success but the pull request shows neither auto-merge nor MERGED — $title"
    fi
  done 3<<<"$prs"
done 4<<<"$repos"

echo "done: armed=$armed merged-now=$merged_now would-arm=$would_arm major-left=$major_left held=$held already-armed=$already_armed rebase-asked=$rebase_asked would-rebase=$would_rebase skipped-no-auto-merge=$skipped_no_auto skipped-unprotected=$skipped_unprotected failed=$failed dry-run=$dry across $nrepos repo(s)"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## fleet-automerge — $nrepos repo(s), dry-run=$dry"
    echo
    echo "| armed | merged now | would arm | major left | held | already armed | rebase asked | would rebase | no auto-merge | unprotected | failed |"
    echo "|---|---|---|---|---|---|---|---|---|---|---|"
    echo "| $armed | $merged_now | $would_arm | $major_left | $held | $already_armed | $rebase_asked | $would_rebase | $skipped_no_auto | $skipped_unprotected | $failed |"
  } >> "$GITHUB_STEP_SUMMARY"
fi
[ "$failed" -eq 0 ] || exit 1
exit 0
