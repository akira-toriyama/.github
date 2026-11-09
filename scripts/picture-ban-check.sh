#!/usr/bin/env bash
# The picture ban: no picture, sprite pack or large binary enters a repository
# that keeps personal pictures off its tree (canon, zmk-vfx-beacon, zmk-vfx-lantern:
# the sprite GIFs are personal files, and the repositories are public). Run
# per-repo by the picture-ban reusable (.github/workflows/picture-ban.yml)
# against the CALLER repo's checkout, and by the pre-commit hook this script
# installs. Extracted here so the logic is table-tested
# (tests/picture-ban-check.test.sh) instead of living in workflow YAML — the
# same split as repo-policy-check.sh.
#
#   usage:  picture-ban-check.sh [<repo-dir>]             every tracked file
#           picture-ban-check.sh [<repo-dir>] --staged    the files a commit stages
#           picture-ban-check.sh --install-hook [<repo-dir>] [--force]
#   stdout: one "<path>: <message>" per violation, then a summary
#   exit:   0 clean, 1 violations, 2 broken input or a refused install
#
# What fails, in the order a file is judged (one line a file):
#   1. its name — the extensions .gif .png .jpg .jpeg .webp .bmp (a picture) and
#      .spk (a sprite pack), the basename beacon_sprite_pack.inc (a pack embedded
#      as C), a path naming the sprites' source (pokeapi) and a sprites/
#      directory, all in any letter case;
#   2. its first bytes — GIF87a / GIF89a, PNG, JPEG, WebP (RIFF….WEBP) and BMP
#      (BM with the four reserved bytes zero: "BM" alone opens ordinary text);
#   3. its size — a binary (a NUL byte in the first 8000 bytes, git's own
#      heuristic) of 16 KiB or more. No picture or pack has to be found by this
#      rule; it stops a container the two above do not know (a zip, a .uf2, a
#      pack renamed). 16 KiB: the three repositories track no binary at all
#      (2026-11-08), and a sprite pack starts at tens of KiB.
#
# Content is read from the INDEX (`:<path>`), never the working tree: on a
# checkout they are the same, and in a pre-commit hook the blob about to be
# committed is what matters. Symlinks are judged by their own name and the link
# text; a submodule entry (mode 160000) has no blob and only its name counts.
#
# --staged lists `git diff --cached --diff-filter=ACMR` (what this commit adds
# or changes), so a picture already in history is the full check's finding,
# not every later commit's. --install-hook writes a pre-commit hook that runs
# this file, at its path now, with --staged: it honours core.hooksPath (through
# `git rev-parse --git-path hooks`), refuses a hook it did not write (exit 2)
# until --force, and fails the commit, not skips it, when this file has moved —
# the ban outranks convenience, and the hook says how to reinstall.
set -uo pipefail

limit=16384
marker='installed-by: picture-ban-check.sh --install-hook'

dir="."
mode="tracked"
force=0
for arg in "$@"; do
  case "$arg" in
    --staged) mode="staged" ;;
    --install-hook) mode="install" ;;
    --force) force=1 ;;
    --*) echo "picture-ban: unknown flag: $arg" >&2; exit 2 ;;
    *) dir="$arg" ;;
  esac
done

[ -d "$dir" ] || { echo "picture-ban: no such directory: $dir" >&2; exit 2; }
git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "picture-ban: not a git work tree: $dir" >&2; exit 2; }

if [ "$mode" = "install" ]; then
  self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  hooks="$(cd "$dir" && git rev-parse --git-path hooks)"
  case "$hooks" in /*) ;; *) hooks="$(cd "$dir" && pwd)/$hooks" ;; esac
  hook="$hooks/pre-commit"
  if [ -e "$hook" ] && ! grep -q "$marker" "$hook" && [ "$force" -ne 1 ]; then
    echo "picture-ban: $hook exists and is not this script's — pass --force to replace it" >&2
    exit 2
  fi
  mkdir -p "$hooks"
  cat > "$hook" <<EOF
#!/bin/sh
# picture-ban pre-commit hook — $marker
#
# Judges the files this commit stages with the hub's picture-ban check (the
# same script the PR gate runs), so a picture never enters history, where a
# red PR would still leave it. Nothing is copied here: the script holds the
# rules. Regenerate with: bash "$self" --install-hook --force
script="$self"
if [ ! -f "\$script" ]; then
  echo "picture-ban: \$script is missing — the hub clone moved; run its scripts/picture-ban-check.sh --install-hook --force from where it is now (a commit with --no-verify skips this hook, and the PR gate still judges)" >&2
  exit 1
fi
exec bash "\$script" --staged
EOF
  chmod +x "$hook"
  echo "picture-ban: hook installed at $hook"
  exit 0
fi

violations=0

# judge <path> <mode> — prints the one line a file earns, if any
judge() {
  local path="$1" fmode="$2" lower base hex size nuls
  lower="$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')"
  base="${lower##*/}"
  case "$lower" in
    *.gif | *.png | *.jpg | *.jpeg | *.webp | *.bmp)
      echo "$path: a picture by its name — the repository tracks no pictures; keep it off the tree"
      return 1 ;;
    *.spk)
      echo "$path: a sprite pack by its name — the repository tracks no sprite packs; keep it off the tree"
      return 1 ;;
    *pokeapi*)
      echo "$path: a path naming the sprites' source — the repository tracks nothing of the sprites; keep it off the tree"
      return 1 ;;
    sprites/* | */sprites/*)
      echo "$path: a sprites/ directory — the repository tracks nothing of the sprites; keep it off the tree"
      return 1 ;;
  esac
  if [ "$base" = "beacon_sprite_pack.inc" ]; then
    echo "$path: a sprite pack embedded as C — the build writes it, the repository never tracks it"
    return 1
  fi
  [ "$fmode" = "160000" ] && return 0

  hex="$(git -C "$dir" cat-file blob ":$path" 2>/dev/null | head -c 16 | od -An -tx1 | tr -d ' \n')"
  case "$hex" in
    474946383761* | 474946383961*)
      echo "$path: a GIF by its first bytes — the repository tracks no pictures; keep it off the tree"
      return 1 ;;
    89504e470d0a1a0a*)
      echo "$path: a PNG by its first bytes — the repository tracks no pictures; keep it off the tree"
      return 1 ;;
    ffd8ff*)
      echo "$path: a JPEG by its first bytes — the repository tracks no pictures; keep it off the tree"
      return 1 ;;
    52494646????????57454250*)
      echo "$path: a WebP by its first bytes — the repository tracks no pictures; keep it off the tree"
      return 1 ;;
    424d????????00000000*)
      echo "$path: a BMP by its first bytes — the repository tracks no pictures; keep it off the tree"
      return 1 ;;
  esac

  size="$(git -C "$dir" cat-file -s ":$path" 2>/dev/null || echo 0)"
  if [ "$size" -ge "$limit" ]; then
    nuls="$(git -C "$dir" cat-file blob ":$path" 2>/dev/null | head -c 8000 | tr -cd '\000' | wc -c | tr -d ' ')"
    if [ "$nuls" -gt 0 ]; then
      echo "$path: a binary of $size bytes — the repository tracks no binary of $limit bytes or more; keep it off the tree"
      return 1
    fi
  fi
  return 0
}

# one record a file: "<mode> <path>", NUL-terminated, from the index
if [ "$mode" = "staged" ]; then
  list() {
    git -C "$dir" diff --cached --name-only -z --diff-filter=ACMR \
      | while IFS= read -r -d '' p; do
          git -C "$dir" ls-files -s -z -- "$p"
        done
  }
else
  list() { git -C "$dir" ls-files -s -z; }
fi

while IFS= read -r -d '' rec; do
  fmode="${rec%% *}"
  path="${rec#*$'\t'}"
  judge "$path" "$fmode" || violations=$((violations + 1))
done < <(list)

if [ "$violations" -gt 0 ]; then
  echo "picture-ban: $violations violation(s)"
  exit 1
fi
echo "picture-ban: clean"
exit 0
