#!/usr/bin/env bash
# contents-has.sh [-E] <pattern> — does a file read through the Contents API
# hold this string (or, with -E, a line matching this extended regex)?
#
# stdin: the API's `.content` (base64, newline-wrapped as GitHub sends it).
# Exit 0 = the decoded file holds it. Exit 1 = the file was decoded and does
# not. Exit 2 = nothing arrived or it would not decode: the answer is UNKNOWN,
# and a caller must never read 2 as "no" — the callers decide deletions and
# secret fan-out on this answer.
#
# Why this is a script and not `… | base64 -d | grep -q X` inline: the callers
# run under `set -o pipefail`, and grep -q exits at its first match. The decoder
# is then still writing, dies of SIGPIPE (141), and pipefail turns a MATCH into
# a failed pipeline, which an `if` reads as "no". On 2026-11-24 that read
# glyph's 19,680-byte pr-verdict.yml — a reusable, `workflow_call` at byte
# 5,406 — as "not a reusable", and fleet-sync's prune deleted it from glyph's
# main (run 45323003149; run 45230939319 had read the same bytes as a reusable
# the day before: the verdict was a race). This reads all of stdin first and
# matches a here-string, so no writer is left to be signalled.
# tests/contents-has.test.sh holds the input the old shape misreads every time.
set -uo pipefail

mode=-F
if [ "${1:-}" = "-E" ]; then mode=-E; shift; fi
pattern="${1:?usage: contents-has.sh [-E] <pattern> < base64-content}"

if ! body="$(base64 -d 2>/dev/null)" || [ -z "$body" ]; then
  exit 2
fi
if grep -q "$mode" -- "$pattern" <<<"$body"; then
  exit 0
fi
exit 1
