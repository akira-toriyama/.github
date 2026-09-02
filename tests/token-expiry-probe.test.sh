#!/usr/bin/env bash
# Table-test scripts/token-expiry-probe.sh — the decision half of the expiry
# reminder. Every case here is a path that, inline in the workflow, could only
# be reached by a real token really dying: the retired homebrew-tap reminder's
# 401 branch was armed from 2026-07-20 and never executed once (t-j72g), and
# fleet-sync-pat-expiry-reminder.yml shipped reading every probe failure as
# transient (t-v2zf). Runs the REAL script; self-test.yml invokes this.
# Needs bash + awk + date only.
#
# PROBE_NOW pins "now" so the day arithmetic is deterministic — without it the
# window cases would flip as the fixtures aged, which is the same "green while
# seeing nothing" failure this test exists to prevent.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
script="$root/scripts/token-expiry-probe.sh"
fails=0

[ -f "$script" ] || { echo "FAIL - $script is missing"; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

NOW='2026-08-02T00:00:00Z'

# case <name> <http-code> <headers-content> <expected-stdout>
case_() {
  local name="$1" code="$2" hdrs="$3" want="$4" got rc
  printf '%s' "$hdrs" > "$tmp/hdrs"
  got="$(EXPIRY_WARN_DAYS=30 PROBE_NOW="$NOW" bash "$script" "$code" "$tmp/hdrs" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && [ "$got" = "$want" ]; then
    echo "ok   - $name"
  else
    echo "FAIL - $name (rc=$rc)"
    echo "       want:"; printf '%s\n' "$want" | sed 's/^/         /'
    echo "       got:";  printf '%s\n' "$got"  | sed 's/^/         /'
    fails=$((fails + 1))
  fi
}

# THE case this file exists for. A dead credential must be reported as dead
# even though the headers file is whatever the failed request left behind.
case_ "401 -> dead, regardless of headers" 401 'HTTP/2 401
content-type: application/json
' 'due=true
kind=dead
reason=probe got 401 — the token is dead (revoked or expired); everything it authenticates is failing NOW'

# curl writes 000 when it never got an HTTP response at all. This must not read
# as "the token is fine" (silence) nor as "the token is dead" (false alarm).
case_ "000 transport failure -> not due, not dead" 000 '' 'due=false
reason=probe returned 000 (transient?) — skipped this run, retries next week'

case_ "503 -> not due, not dead" 503 '' 'due=false
reason=probe returned 503 (transient?) — skipped this run, retries next week'

# A 403 is NOT a dead token (rate limit / permission), so it must fall in the
# transient bucket rather than the 401 one.
case_ "403 -> transient bucket, not dead" 403 '' 'due=false
reason=probe returned 403 (transient?) — skipped this run, retries next week'

# A token issued non-expiring: the calendar path cannot arm at all. The reason
# line has to SAY that. (Not FLEET_SYNC_PAT's live state any more — it carries
# a 2027-06-30 expiry, measured run 33603210056 — but a rotation can regress
# to this, and t-8jpv acts on the observation at the next one.)
case_ "200 without the expiration header -> non-expiring" 200 'HTTP/2 200
content-type: application/json
x-ratelimit-limit: 5000
' 'due=false
reason=no expiration header — the token is non-expiring, so the calendar path cannot arm; reissue it WITH an expiry'

# Header present and far out: quiet, but the day count is still reported so the
# run log shows the probe actually read something.
case_ "200, 90 days out -> not due, days reported" 200 'HTTP/2 200
GitHub-Authentication-Token-Expiration: 2026-10-31 00:00:00 UTC
' 'days=90
due=false
reason=token expires 2026-10-31 00:00:00 UTC (90 days) — outside the 30-day window, nothing to do'

# One day OUTSIDE the window — the boundary that must stay quiet.
case_ "200, 31 days out -> not due (boundary)" 200 'HTTP/2 200
GitHub-Authentication-Token-Expiration: 2026-09-02 00:00:00 UTC
' 'days=31
due=false
reason=token expires 2026-09-02 00:00:00 UTC (31 days) — outside the 30-day window, nothing to do'

# The boundary itself — <= warn_days fires.
case_ "200, exactly 30 days out -> due/expiry (boundary)" 200 'HTTP/2 200
GitHub-Authentication-Token-Expiration: 2026-09-01 00:00:00 UTC
' 'days=30
due=true
kind=expiry
reason=token expires 2026-09-01 00:00:00 UTC (30 days) — within the 30-day window'

# Already past its expiry but the API still answered 200 (clock skew, or a
# grace period). Negative days must still fire, not wrap into "fine".
case_ "200, already expired -> due/expiry with negative days" 200 'HTTP/2 200
GitHub-Authentication-Token-Expiration: 2026-07-01 00:00:00 UTC
' 'days=-32
due=true
kind=expiry
reason=token expires 2026-07-01 00:00:00 UTC (-32 days) — within the 30-day window'

# Header case-insensitivity: GitHub has shipped both casings.
case_ "200, lowercased header name -> still read" 200 'HTTP/2 200
github-authentication-token-expiration: 2026-08-15 00:00:00 UTC
' 'days=13
due=true
kind=expiry
reason=token expires 2026-08-15 00:00:00 UTC (13 days) — within the 30-day window'

# Garbage where a date belongs must be "we learned nothing", never a crash and
# never a silent due=false with no explanation.
case_ "200, unparseable expiry -> not due, says why" 200 'HTTP/2 200
GitHub-Authentication-Token-Expiration: not-a-date
' 'due=false
reason=could not parse expiry '"'"'not-a-date'"'"' — skipped this run'

# A headers file that does not exist (the probe died before writing it) must not
# take the job down with `set -e` inside a command substitution.
rm -f "$tmp/nonexistent"
got="$(EXPIRY_WARN_DAYS=30 PROBE_NOW="$NOW" bash "$script" 200 "$tmp/nonexistent" 2>&1)"; rc=$?
want='due=false
reason=no expiration header — the token is non-expiring, so the calendar path cannot arm; reissue it WITH an expiry'
if [ "$rc" -eq 0 ] && [ "$got" = "$want" ]; then
  echo "ok   - 200 with a missing headers file -> exits 0, reads as no header"
else
  echo "FAIL - 200 with a missing headers file (rc=$rc)"
  echo "       got:"; printf '%s\n' "$got" | sed 's/^/         /'
  fails=$((fails + 1))
fi

# Called wrong: still exit 0 (a broken caller must not look like a dead token).
for bad in "" "200"; do
  # shellcheck disable=SC2086  # deliberate word-split: $bad is an argv fragment, empty means "no args"
  got="$(bash "$script" $bad 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$got" | grep -q '^due=false$'; then
    echo "ok   - called with '${bad:-<no args>}' -> exit 0, due=false"
  else
    echo "FAIL - called with '${bad:-<no args>}' (rc=$rc): $got"
    fails=$((fails + 1))
  fi
done

# EXPIRY_WARN_DAYS is honoured, not hard-coded at 30.
got="$(printf 'GitHub-Authentication-Token-Expiration: 2026-09-15 00:00:00 UTC\n' > "$tmp/h2"; \
  EXPIRY_WARN_DAYS=60 PROBE_NOW="$NOW" bash "$script" 200 "$tmp/h2" 2>&1)"
if printf '%s' "$got" | grep -q '^due=true$' && printf '%s' "$got" | grep -q 'kind=expiry'; then
  echo "ok   - EXPIRY_WARN_DAYS=60 widens the window (44 days now fires)"
else
  echo "FAIL - EXPIRY_WARN_DAYS not honoured: $got"
  fails=$((fails + 1))
fi

if [ "$fails" -gt 0 ]; then
  echo "FAIL - $fails case(s)"
  exit 1
fi
echo "ok - all token-expiry-probe cases passed"
