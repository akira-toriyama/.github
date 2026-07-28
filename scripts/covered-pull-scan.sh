#!/usr/bin/env bash
# Detect the two preconditions of glyph's covered-pull trap. Read ONE input on
# stdin; write TAB-separated records, one per line. Two modes, one per half of
# glyph-covered-pull-audit.yml (which is where the trap itself is explained):
#
#   merges      stdin:  TSV rows  <sha> <parents> <author>  — one per commit
#               stdout: covered-merge     <sha>     <author>
#                       malformed-input   -         <line>
#
#     A row is reported when BOTH gates that arm the trap hold at once: the
#     commit is a merge (parents >= 2) and its author is one glyph's merge-point
#     resolution skips. The author patterns MIRROR glyph's
#     internal/bump/bump.go ExcludedFromResolution verbatim — suffix `[bot]`,
#     prefix `github-actions`, exact `web-flow` — and must move when that
#     function moves, or this audit watches a gate that no longer exists.
#     A row this scanner cannot read (wrong arity, non-numeric parent count) is
#     REPORTED, not skipped: it means the API plumbing feeding this script
#     changed shape, and a scanner fed garbage that stays silent is
#     indistinguishable from a fleet with no bot merges.
#
#   workflows   stdin:  one workflow YAML
#               stdout: merge-strategy             merge|rebase|squash  <line>
#                       merge-strategy-unreadable  -                    <line>
#
#     Every `gh pr merge` invocation is a record; only the classification
#     varies (the same fail-loud shape as glyph-pin-scan.sh, for the same
#     reason: an invocation whose strategy cannot be read must not look like a
#     file with no invocation at all). `merge` and `rebase` are the arming
#     strategies — `--merge` puts a bot-authored merge commit on main, which is
#     exactly what the `merges` half then finds after the fact; this half finds
#     the WORD before the commit exists. `squash` is the fleet's normal path
#     and harmless. A strategy held in a variable is `merge-strategy-unreadable`
#     — a human reads that line, not this scanner.
#
# WHAT IS DELIBERATELY NOT PARSED (same posture as glyph-pin-scan.sh):
#   - a line whose first non-space character is `#` is documentation; a ` #…`
#     trailer is stripped. Advice text about `gh pr merge` must not red the
#     fleet — only a line the shell would execute.
#   - quotes are erased before matching, so `"--merge"` reads as `--merge`.
#   - a trailing `\` joins the next physical line first, because the joined
#     form is what the shell executes; the record carries the FIRST line.
#   - flags are matched as whole tokens: `--match-head-commit` is not
#     `--merge`, `-R` (repo) is not `-r` (rebase). Cobra's grouped short form
#     (`-dm`) matches no token and classifies unreadable — fail loud, not open.
set -euo pipefail

mode="${1:-}"
case "$mode" in
  merges)
    awk '
    BEGIN { FS = "\t"; OFS = "\t" }
    /^[ \t]*$/ { next }
    NF != 3 || $2 !~ /^[0-9]+$/ { print "malformed-input", "-", NR; next }
    {
      # Both gates, in the order glyph applies them is irrelevant — arming
      # needs the conjunction. Patterns: internal/bump/bump.go
      # ExcludedFromResolution (see header).
      if ($2 + 0 < 2) next
      if ($3 ~ /\[bot\]$/ || $3 ~ /^github-actions/ || $3 == "web-flow")
        print "covered-merge", $1, $3
    }
    '
    ;;
  workflows)
    awk '
    BEGIN {
      # A dynamic regex, because a literal quote cannot be written inside the
      # single-quoted awk program this script passes to the shell.
      qre = "[" sprintf("%c%c", 39, 34) "]"
    }
    {
      line = $0
      start = NR
      # A `\` immediately before the newline continues the command; the joined
      # form is what the shell executes, so it is what gets matched.
      while (line ~ /\\$/) {
        sub(/\\$/, " ", line)
        if ((getline nxt) <= 0) break
        line = line " " nxt
      }
      if (line ~ /^[ \t]*#/) next       # a whole-line comment is documentation
      sub(/[ \t]+#.*$/, "", line)       # and so is a trailing one
      if (line ~ /^[ \t]*$/) next
      gsub(qre, "", line)

      # `gh` as a word (start of line/command, not a suffix of another word),
      # then the exact subcommand path. `gh -R owner/repo pr merge` — global
      # flags between `gh` and the subcommand — does not match; no fleet
      # workflow is written that way, and the dynamic half still catches what
      # such a merge would produce. Padded with sentinel spaces instead of
      # anchored alternations — mawk (the runner awk) and BSD awk (the
      # posix-portability job) do not guarantee `^`/`$` inside a group, the
      # same reason glyph-pin-scan.sh matches `[ \t{,]version:`.
      padded = " " line " "
      if (match(padded, /[ \t;&|(]gh[ \t]+pr[ \t]+merge[ \t]/)) {
        rest = substr(padded, RSTART + RLENGTH)
        n = split(rest, toks, /[ \t]+/)
        kind = ""
        for (i = 1; i <= n; i++) {
          if (toks[i] == "--merge"  || toks[i] == "-m") { kind = "merge";  break }
          if (toks[i] == "--rebase" || toks[i] == "-r") { kind = "rebase"; break }
          if (toks[i] == "--squash" || toks[i] == "-s") { kind = "squash"; break }
        }
        if (kind != "") print "merge-strategy\t" kind "\t" start
        else            print "merge-strategy-unreadable\t-\t" start
      }
    }
    '
    ;;
  *)
    echo "usage: covered-pull-scan.sh merges|workflows (input on stdin)" >&2
    exit 2
    ;;
esac
