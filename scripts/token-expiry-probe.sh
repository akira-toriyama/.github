#!/usr/bin/env bash
# Decide what a token-health probe SAW, separately from performing it. The
# expiry reminders used to do this inline, which made the decision unreachable
# from any test: the branch that files the reminder only runs when a real
# token is really dying, so the interesting paths shipped unexecuted — the
# retired homebrew-tap reminder's 401 branch never once ran (t-j72g), and
# fleet-sync-pat-expiry-reminder.yml (today's one production caller) read
# every `gh api` failure as transient, so a dead FLEET_SYNC_PAT would have
# stayed silent forever (t-v2zf).
#
#   usage:  token-expiry-probe.sh <http-code> <headers-file>
#   stdout: `key=value` lines for $GITHUB_OUTPUT — always `due` and `reason`,
#           plus `kind` when due and `days` when an expiry was readable.
#   exit:   0 always. A probe never fails the job: a transient 5xx must not read
#           as a dead token, and a dead token is reported through `due`, not
#           through a red run that nobody can distinguish from a runner fault.
#
# env:  EXPIRY_WARN_DAYS  file the reminder this many days before expiry (default 30)
#       PROBE_NOW         ISO8601 UTC instant to treat as "now" (tests only)
#
# `kind` is what the caller files against:
#   dead    the credential itself is invalid — 401 on an authenticated GET. An
#           invalid Bearer fails even on a public repo, so this is unambiguous.
#   expiry  the credential still works but the calendar is closing in.
#
# A 200 with no GitHub-Authentication-Token-Expiration header means the token
# was issued non-expiring: the calendar path CANNOT arm, and saying so is the
# point (t-8jpv reissues FLEET_SYNC_PAT with an expiry at the next rotation to
# close that hole).
set -uo pipefail

warn_days="${EXPIRY_WARN_DAYS:-30}"

emit() { printf '%s\n' "$*"; }

die_usage() {
  emit "due=false"
  emit "reason=probe script called wrong ($1) — treating as transient; fix the caller"
  exit 0
}

code="${1:-}"
hdrs="${2:-}"
[ -n "$code" ] || die_usage "no http code"
[ -n "$hdrs" ] || die_usage "no headers file"

# ISO8601 UTC -> epoch seconds, GNU or BSD userland. The reminders run on
# ubuntu, but this repo's posix-portability job runs the scripts on macOS too,
# and `date -u -d` is GNU-only — the inline version was silently ubuntu-locked.
iso_epoch() {
  if date -u -d '@0' +%s >/dev/null 2>&1; then
    date -u -d "$1" +%s 2>/dev/null
  else
    # GitHub sends RFC1123-ish ("2026-08-02 05:00:00 UTC") and ISO both; try the
    # two shapes BSD date can parse rather than guessing one.
    date -u -j -f '%Y-%m-%d %H:%M:%S %Z' "$1" +%s 2>/dev/null \
      || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null
  fi
}

if [ -n "${PROBE_NOW:-}" ]; then
  now_s="$(iso_epoch "$PROBE_NOW")"
  [ -n "$now_s" ] || die_usage "unparseable PROBE_NOW: $PROBE_NOW"
else
  now_s="$(date -u +%s)"
fi

case "$code" in
  401)
    emit "due=true"
    emit "kind=dead"
    emit "reason=probe got 401 — the token is dead (revoked or expired); everything it authenticates is failing NOW"
    exit 0
    ;;
  200) ;;
  *)
    # Includes curl's own 000. Anything that is not a definite 401 and not a
    # definite 200 is "we did not learn anything this week", never "fine".
    emit "due=false"
    emit "reason=probe returned $code (transient?) — skipped this run, retries next week"
    exit 0
    ;;
esac

# Guard the file, not just the read: `< "$missing"` is a SHELL redirect failure,
# so `2>/dev/null` on the command never suppresses it — the reminder's log would
# carry a "No such file or directory" line under an otherwise correct verdict.
if [ -f "$hdrs" ]; then
  hdr="$(tr -d '\r' < "$hdrs" \
    | awk -F': ' 'tolower($1)=="github-authentication-token-expiration"{print $2; exit}')"
else
  hdr=''
fi

if [ -z "$hdr" ]; then
  emit "due=false"
  emit "reason=no expiration header — the token is non-expiring, so the calendar path cannot arm; reissue it WITH an expiry"
  exit 0
fi

exp_s="$(iso_epoch "$hdr")"
if [ -z "$exp_s" ]; then
  emit "due=false"
  emit "reason=could not parse expiry '$hdr' — skipped this run"
  exit 0
fi

# Truncating division: 29.9 days left reads as 29, which fires a day early
# rather than a day late. Deliberate — the failure that matters is silence.
days=$(( (exp_s - now_s) / 86400 ))
emit "days=$days"
if [ "$days" -le "$warn_days" ]; then
  emit "due=true"
  emit "kind=expiry"
  emit "reason=token expires $hdr (${days} days) — within the ${warn_days}-day window"
else
  emit "due=false"
  emit "reason=token expires $hdr (${days} days) — outside the ${warn_days}-day window, nothing to do"
fi
