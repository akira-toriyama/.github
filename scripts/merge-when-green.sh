#!/usr/bin/env bash
# Squash-merge a list of pull requests, each only once its checks have finished
# green — the merges a rollout leaves to a person: the pin pulls fleet-automerge
# logs `major-left:`, `skipped(no-auto-merge):` or `skipped(unprotected):`, and
# the one-line config pulls scripts/glyph-config-drop.sh opens
# (docs/glyph-rollout-runbook.md, step 5 and "A major that removes a
# `glyph.toml` key").
#
#   usage:  merge-when-green.sh <list-file> [<deadline-seconds>]
#           <list-file>: one pull per line, `<owner/repo> <pr-url-or-number> …`;
#           fields after the second are ignored, so glyph-config-drop.sh's
#           stdout is a list as it stands; blank lines are skipped, and a last
#           line with no newline is read like any other
#   env:    MERGE_WHEN_GREEN_POLL_SECONDS  seconds between polls (default 30)
#   stdout: one line per pull —
#             <owner/repo> #<n> merged checks=[<bucket>=<count> …]
#             <owner/repo> #<n> MERGE-FAILED checks=[…]     gh's words on stderr
#             <owner/repo> #<n> NOT merged rc=<rc> bad=[<name>=<bucket> …]
#           rc is the last `gh pr checks` exit, or 124 when the deadline passed
#           while checks were still pending; checks=[none] is a head gh reports
#           no checks on
#   exit:   0  every listed pull merged
#           1  any pull not merged
#           2  usage: no list, an unreadable or empty one, a line that names no
#              <owner/repo> and pull, or a deadline / poll that is not a whole
#              number of seconds (read as decimal: `08` is 8) — nothing is
#              merged
#
# The deadline (default 1800 s) is per pull, counted from its first poll; the
# list is worked top to bottom, one pull at a time.
#
# WHAT GREEN MEANS: every check's bucket is pass or skipping, or gh reports no
# checks at all. Read from gh 2.96.0's source (pkg/cmd/pr/checks): with stdout
# not a terminal `gh pr checks` prints one tab-separated row per check — name,
# bucket, elapsed, link, description — and no header (measured 2026-11-03:
# .github#264 printed 35 rows of 5 fields, every bucket `pass`, exit 0, and this
# script tallied dotfiles#414 as pass=15 skipping=4). The bucket is
# pass / fail / pending / skipping, and a CANCELLED check prints `fail` without
# counting as failed, so with nothing else failing or pending the command exits
# 0 over it — the verdict is read from the rows, never from the exit code
# alone. gh exits 8
# while a check is pending and none has failed (the one answer this polls on),
# 1 once one has failed, and 1 with `no checks reported on the '<branch>'
# branch` on stderr when the head carries no check at all. That last answer
# reads the same for a repository with no pull-request CI as for a pull whose
# runs GitHub has not attached yet: list a pull only once its checks have had
# time to appear.
set -uo pipefail

usage() {
  echo "usage: merge-when-green.sh <list-file> [<deadline-seconds>]" >&2
  exit 2
}

{ [ "$#" -ge 1 ] && [ "$#" -le 2 ]; } || usage
list="$1"; deadline="${2:-1800}"; poll="${MERGE_WHEN_GREEN_POLL_SECONDS:-30}"
case "$deadline" in ''|*[!0-9]*) usage ;; esac
case "$poll" in ''|*[!0-9]*) echo "MERGE_WHEN_GREEN_POLL_SECONDS must be a whole number of seconds" >&2; exit 2 ;; esac
# Bash arithmetic reads a leading zero as octal, and `08` aborts it.
deadline=$((10#$deadline)); poll=$((10#$poll))
{ [ -f "$list" ] && [ -r "$list" ]; } || { echo "list file not readable: $list" >&2; exit 2; }

# The whole list is validated before the first merge, so a typo on line 9 is a
# usage error and not a run that merged eight pulls and then stopped.
malformed="$(awk 'NF == 0 { next }
  { n = $2; sub(".*/", "", n) }
  $1 !~ "^[^/]+/[^/]+$" || n !~ "^[0-9]+$" { print NR; exit }' "$list")"
if [ -n "$malformed" ]; then
  echo "$list:$malformed: not \`<owner/repo> <pr-url-or-number>\` — nothing merged" >&2
  exit 2
fi
if ! awk 'NF > 0 { found = 1 } END { exit !found }' "$list"; then
  echo "$list lists no pull requests" >&2
  exit 2
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

all=0
while read -r full ref _ <&3 || [ -n "${full:-}" ]; do
  [ -n "$full" ] || continue
  n="${ref##*/}"

  end=$(( $(date +%s) + deadline ))
  announced=0
  while :; do
    gh pr checks "$n" --repo "$full" </dev/null >"$tmp/out" 2>"$tmp/err"
    rc=$?
    [ "$rc" -eq 8 ] || break
    if [ "$(date +%s)" -ge "$end" ]; then rc=124; break; fi
    if [ "$announced" -eq 0 ]; then
      echo "$full #$n: checks pending — polling every ${poll}s for up to ${deadline}s" >&2
      announced=1
    fi
    sleep "$poll"
  done

  bad="$(awk -F'\t' 'NF > 1 && $2 != "pass" && $2 != "skipping" { printf "%s%s=%s", sep, $1, $2; sep = " " }' "$tmp/out")"
  tally="$(awk -F'\t' 'NF > 1 { print $2 }' "$tmp/out" | sort | uniq -c \
    | awk '{ printf "%s%s=%s", sep, $2, $1; sep = " " }')"

  green=0
  if [ -z "$bad" ]; then
    if [ "$rc" -eq 0 ] && [ -n "$tally" ]; then
      green=1
    elif [ "$rc" -eq 1 ] && [ -z "$tally" ] && grep -q 'no checks reported' "$tmp/err"; then
      green=1; tally=none
    fi
  fi

  if [ "$green" -eq 0 ]; then
    echo "$full #$n NOT merged rc=$rc bad=[$bad]"
    [ -n "$bad" ] || [ ! -s "$tmp/err" ] || sed "s|^|$full #$n: gh pr checks: |" "$tmp/err" >&2
    all=1
    continue
  fi
  if gh pr merge "$n" --repo "$full" --squash </dev/null >/dev/null 2>"$tmp/merge.err"; then
    echo "$full #$n merged checks=[$tally]"
  else
    echo "$full #$n MERGE-FAILED checks=[$tally]"
    sed "s|^|$full #$n: gh pr merge: |" "$tmp/merge.err" >&2
    all=1
  fi
done 3< "$list"

exit "$all"
