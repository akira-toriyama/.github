#!/usr/bin/env bash
# Table-test scripts/picture-ban-check.sh — the whole check the picture-ban
# reusable runs against a sprite repository's PR, and the pre-commit hook it
# installs. A rule that stops matching reads exactly like a clean repository,
# so the table pins both directions for each rule: the picture that must fail
# (by name, by first bytes, by size), and the look-alike that must pass (text
# that opens with "BM" or "RIFF", "gif" inside a name, a mention in content
# rather than a path, a binary under the limit, an untracked file). The hook
# cases run a real `git commit` through the installed hook.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
script="$root/scripts/picture-ban-check.sh"
fails=0

[ -f "$script" ] || { echo "FAIL - $script is missing"; exit 1; }

# Hermetic git: the author's hooks path, identity and templates stay out.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=picture-ban GIT_AUTHOR_EMAIL=picture-ban@example.invalid
export GIT_COMMITTER_NAME=picture-ban GIT_COMMITTER_EMAIL=picture-ban@example.invalid

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# repo <name> — fresh git repo to stage a case in; the INDEX is what counts,
# so every fixture file must be `git add`ed (add_file and add_bytes do).
repo() {
  casedir="$work/$1"
  mkdir -p "$casedir"
  git -C "$casedir" init -q
}

add_file() { # $1 = relative path, stdin = content
  mkdir -p "$casedir/$(dirname "$1")"
  cat > "$casedir/$1"
  git -C "$casedir" add -f "$1"
}

write_bytes() { # $1 = relative path, $2 = printf format of the content
  mkdir -p "$casedir/$(dirname "$1")"
  # shellcheck disable=SC2059 # the format IS the fixture
  printf "$2" > "$casedir/$1"
}

add_bytes() { # $1 = relative path, $2 = printf format of the content
  write_bytes "$1" "$2"
  git -C "$casedir" add -f "$1"
}

check() { # $1 = name, $2… = a test to run; ok when it passes
  local name="$1"
  shift
  if "$@"; then
    echo "ok   - $name"
  else
    echo "FAIL - $name"
    fails=$((fails + 1))
  fi
}

# run_case <name> <want-rc> <want-grep|-> [flags…] — runs the script on
# $casedir; checks exit code, and (unless "-") that stdout matches the grep -E
# pattern.
run_case() {
  local name="$1" want_rc="$2" want="$3" got rc=0
  shift 3
  got="$(bash "$script" "$casedir" "$@" 2>&1)" || rc=$?
  if [ "$rc" != "$want_rc" ]; then
    echo "FAIL - $name (want rc=$want_rc, got rc=$rc)"
    echo "       out: $(printf '%s' "$got" | tr '\n' '|')"
    fails=$((fails + 1))
    return
  fi
  if [ "$want" != "-" ] && ! printf '%s' "$got" | grep -qE "$want"; then
    echo "FAIL - $name (missing /$want/)"
    echo "       out: $(printf '%s' "$got" | tr '\n' '|')"
    fails=$((fails + 1))
    return
  fi
  echo "ok   - $name"
}

gif89='GIF89a\001\000\001\000\200\000\000\000\000\000\377\377\377!\371\004\001\000\000\000\000,\000\000\000\000\001\000\001\000\000\002\002D\001\000;'
gif87='GIF87a\001\000\001\000\200\000\000\000\000\000\377\377\377,\000\000\000\000\001\000\001\000\000\002\002D\001\000;'
png='\211PNG\r\n\032\n\000\000\000\015IHDR\000\000\000\001\000\000\000\001\010\006\000\000\000'
jpeg='\377\330\377\340\000\020JFIF\000\001\001\000\000\001\000\001\000\000'
webp='RIFF\044\000\000\000WEBPVP8 \030\000\000\000'
bmp='BM\072\000\000\000\000\000\000\000\066\000\000\000\050\000\000\000\001\000\000\000\001\000\000\000\001\000\030\000'

# an empty repo is clean, not an error
repo empty
run_case "empty repo is clean" 0 "picture-ban: clean"

# not a work tree: broken input, never a verdict
mkdir -p "$work/plain"
casedir="$work/plain"
run_case "a directory that is no work tree is exit 2" 2 "not a git work tree"

# rule 2: pictures by their first bytes, under names that say nothing
repo by-bytes
add_bytes "data/a.bin" "$gif89"
add_bytes "data/b.bin" "$gif87"
add_bytes "data/c.bin" "$png"
add_bytes "data/d.bin" "$jpeg"
add_bytes "data/e.bin" "$webp"
add_bytes "data/f.bin" "$bmp"
run_case "five picture formats are found by their first bytes" 1 'picture-ban: 6 violation'
run_case "  GIF89a" 1 'data/a\.bin: a GIF by its first bytes'
run_case "  GIF87a" 1 'data/b\.bin: a GIF by its first bytes'
run_case "  PNG" 1 'data/c\.bin: a PNG by its first bytes'
run_case "  JPEG" 1 'data/d\.bin: a JPEG by its first bytes'
run_case "  WebP" 1 'data/e\.bin: a WebP by its first bytes'
run_case "  BMP" 1 'data/f\.bin: a BMP by its first bytes'

# the look-alikes: text that opens like a header, a header not at the start,
# a mention in content, "gif" inside a name, a sprites word that is no directory
repo bytes-lookalikes
add_file "notes/BMW.md" <<'EOF'
BM is also how this note opens; the reserved bytes of a BMP would be zero here.
EOF
add_file "notes/riff.txt" <<'EOF'
RIFF through the archive; the WEBP word is further on than a header allows.
EOF
add_file "notes/mentions.md" <<'EOF'
A GIF89a header opens every animated GIF; the sprites come from pokeapi and
live under sprites/ in the source, never here.
EOF
add_file "tools/gifpics.py" <<'EOF'
print("gif in the name, not the extension")
EOF
add_file "docs/sprites-notes.md" <<'EOF'
sprites- is not a sprites/ directory
EOF
run_case "look-alikes by content and by name are clean" 0 "picture-ban: clean"

# rule 1: names, in any letter case, before content is read
repo by-name
add_file "assets/one.GIF" <<'EOF'
text under a picture's name still fails
EOF
add_file "a.png" <<'EOF'
x
EOF
add_file "b.jpg" <<'EOF'
x
EOF
add_file "c.JPEG" <<'EOF'
x
EOF
add_file "d.webp" <<'EOF'
x
EOF
add_file "e.bmp" <<'EOF'
x
EOF
add_file "pack/one.spk" <<'EOF'
x
EOF
add_file "build/beacon_sprite_pack.inc" <<'EOF'
0x00,
EOF
add_file "third_party/PokeAPI-notes.txt" <<'EOF'
x
EOF
add_file "sprites/1.txt" <<'EOF'
x
EOF
add_file "data/Sprites/1.txt" <<'EOF'
x
EOF
run_case "eleven names fail" 1 'picture-ban: 11 violation'
run_case "  .GIF in capitals" 1 'assets/one\.GIF: a picture by its name'
run_case "  .spk" 1 'pack/one\.spk: a sprite pack by its name'
run_case "  the embedded pack" 1 'build/beacon_sprite_pack\.inc: a sprite pack embedded as C'
run_case "  the source's name in a path" 1 "third_party/PokeAPI-notes\.txt: a path naming the sprites' source"
run_case "  a sprites/ directory at the root" 1 'sprites/1\.txt: a sprites/ directory'
run_case "  a Sprites/ directory below" 1 'data/Sprites/1\.txt: a sprites/ directory'

# one line a file: a GIF under a .gif name is one violation, not two
repo one-line
add_bytes "one.gif" "$gif89"
run_case "a GIF named .gif is one violation" 1 'picture-ban: 1 violation'

# rule 3: a binary at the limit fails, text of any size and a small binary pass
repo by-size
head -c 16384 /dev/zero > "$casedir/big.bin"
git -C "$casedir" add big.bin
run_case "a 16 KiB binary fails" 1 'big\.bin: a binary of 16384 bytes'

repo size-lookalikes
{ for _ in $(seq 1 2000); do echo "0123456789abcdef0123456789abcdef"; done; } > "$casedir/big.txt"
git -C "$casedir" add big.txt
head -c 16383 /dev/zero > "$casedir/small.bin"
git -C "$casedir" add small.bin
run_case "a large text file and a binary under the limit are clean" 0 "picture-ban: clean"

# an untracked picture is invisible: the check reads the index, never the
# working tree (scratch files must not fail CI)
repo untracked
write_bytes "scratch.gif" "$gif89"
run_case "an untracked picture is not a violation" 0 "picture-ban: clean"

# the working tree may differ from the index: the index is what is judged
repo index-not-tree
add_file "frame.bin" <<'EOF'
text in the index
EOF
write_bytes "frame.bin" "$gif89"
run_case "a GIF in the working tree over a text blob in the index is clean" 0 "picture-ban: clean"

# --staged: the files this commit adds or changes, not the whole tree
repo staged
add_file "README.md" <<'EOF'
first commit
EOF
git -C "$casedir" commit -q -m "text"
add_bytes "frame.gif" "$gif89"
run_case "--staged finds a staged picture" 1 'frame\.gif: a picture by its name' --staged
git -C "$casedir" commit -q -m "picture"
add_file "README.md" <<'EOF'
second commit
EOF
run_case "--staged ignores a picture already in history" 0 "picture-ban: clean" --staged
run_case "the full check still finds it" 1 'frame\.gif: a picture by its name'
git -C "$casedir" rm -q --cached frame.gif
run_case "--staged ignores a removal" 0 "picture-ban: clean" --staged

# --install-hook: the hook runs this script with --staged on every commit
repo hook
run_case "--install-hook writes the hook" 0 'picture-ban: hook installed at .*/hooks/pre-commit' --install-hook
hook="$casedir/.git/hooks/pre-commit"
check "the hook is executable" test -x "$hook"
add_file "README.md" <<'EOF'
text
EOF
if git -C "$casedir" commit -q -m "text" 2>/dev/null; then
  echo "ok   - the hook lets a text commit through"
else
  echo "FAIL - the hook stopped a text commit"; fails=$((fails + 1))
fi
add_bytes "frame.bin" "$gif89"
if out="$(git -C "$casedir" commit -q -m "picture" 2>&1)"; then
  echo "FAIL - the hook let a GIF commit through"; fails=$((fails + 1))
elif printf '%s' "$out" | grep -q 'frame\.bin: a GIF by its first bytes'; then
  echo "ok   - the hook stops a GIF commit and names the file"
else
  echo "FAIL - the hook stopped the commit without the finding: $(printf '%s' "$out" | tr '\n' '|')"; fails=$((fails + 1))
fi
if git -C "$casedir" commit -q --no-verify -m "picture" 2>/dev/null; then
  echo "ok   - --no-verify is the escape hatch (the PR gate still judges)"
else
  echo "FAIL - --no-verify did not skip the hook"; fails=$((fails + 1))
fi
run_case "installing over its own hook needs no --force" 0 'picture-ban: hook installed' --install-hook

# a hook this script did not write is refused until --force
repo foreign-hook
mkdir -p "$casedir/.git/hooks"
printf '#!/bin/sh\nexit 0\n' > "$casedir/.git/hooks/pre-commit"
run_case "a foreign pre-commit hook is refused" 2 'not this script' --install-hook
run_case "--force replaces it" 0 'picture-ban: hook installed' --install-hook --force
check "the replaced hook is this script's" grep -q 'installed-by: picture-ban-check.sh' "$casedir/.git/hooks/pre-commit"

# core.hooksPath is honoured, relative to the work tree
repo hooks-path
git -C "$casedir" config core.hooksPath scripts/hooks
run_case "core.hooksPath decides where the hook goes" 0 'hook installed at .*/hooks-path/scripts/hooks/pre-commit' --install-hook
check "the hook is there" test -x "$casedir/scripts/hooks/pre-commit"

# a moved script fails the commit, and the hook says how to reinstall
repo moved-script
copy="$work/moved-copy.sh"
cp "$script" "$copy"
bash "$copy" "$casedir" --install-hook >/dev/null
rm "$copy"
add_file "README.md" <<'EOF'
text
EOF
if out="$(git -C "$casedir" commit -q -m "text" 2>&1)"; then
  echo "FAIL - a missing script let the commit through"; fails=$((fails + 1))
elif printf '%s' "$out" | grep -q 'is missing' && printf '%s' "$out" | grep -q -- '--install-hook --force'; then
  echo "ok   - a missing script fails the commit and names the reinstall"
else
  echo "FAIL - a missing script failed the commit without the reinstall line: $(printf '%s' "$out" | tr '\n' '|')"; fails=$((fails + 1))
fi

[ "$fails" -eq 0 ] || { echo "$fails picture-ban-check case(s) failed"; exit 1; }
echo "all picture-ban-check cases passed"
