#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# stat --json: GNU stat has no --json, so every field is compared with the
# value GNU stat itself prints for the same file (GNU coreutils 9.7), and the
# output must parse as JSON. Needs python3 and GNU stat.
BIN="$(cd "${OURS_DIR:-$(dirname "$0")/../zig-out/bin}" && pwd)"
pass=0; fail=0
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT; cd "$W" || exit 1
printf 'hello\n' > file; : > empty; head -c 100000 /dev/zero > big; mkdir dir; ln -s file lnk; ln -s nowhere dangling
mkfifo fifo; printf x > "we\"ird name"; printf x > "$(printf 'bad\377name')"; chmod 4755 big; chmod 2755 dir
touch -d @1234567890.123456789 file
export TZ=UTC

# field name -> GNU stat directive
check_field() { # file, json key, GNU format, extra GNU args
    f=$1; key=$2; gfmt=$3; shift 3
    want=$(stat "$@" -c "$gfmt" -- "$f")
    got=$("$BIN/stat" "$@" --json -- "$f" | python3 -c "import json,sys; v=json.load(sys.stdin)[\"$key\"]; print(v)" 2>/dev/null)
    if [ "$want" = "$got" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $f $key: GNU=[$want] OURS=[$got]"; fi
}
for f in file empty big dir lnk dangling fifo /dev/null /dev/zero / /proc "we\"ird name"; do
    check_field "$f" size '%s'
    check_field "$f" blocks '%b'
    check_field "$f" block_size '%o'
    [ "$f" = /proc ] || check_field "$f" nlink '%h'   # /proc's link count follows the process count
    check_field "$f" inode '%i'
    check_field "$f" uid '%u'
    check_field "$f" gid '%g'
    check_field "$f" user '%U'
    check_field "$f" group '%G'
    check_field "$f" mode_string '%A'
    check_field "$f" mode_octal '%04a'
    check_field "$f" type_desc '%F'
    check_field "$f" dev '%d'
    check_field "$f" dev_major '%Hd'
    check_field "$f" dev_minor '%Ld'
    check_field "$f" atime '%X'
    check_field "$f" mtime '%Y'
    check_field "$f" ctime '%Z'
    check_field "$f" mtime '%Y' -L
    check_field "$f" type_desc '%F' -L
done
for f in /dev/null /dev/zero; do
    check_field "$f" rdev_major '%Hr'
    check_field "$f" rdev_minor '%Lr'
done

t() { name=$1; shift; if "$@" >/dev/null 2>&1; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $name"; fi; }
t "symlink target" sh -c "[ \"\$('$BIN/stat' --json lnk | python3 -c 'import json,sys;print(json.load(sys.stdin)[\"link_target\"])')\" = file ]"
t "dangling target" sh -c "[ \"\$('$BIN/stat' --json dangling | python3 -c 'import json,sys;print(json.load(sys.stdin)[\"link_target\"])')\" = nowhere ]"
t "non-link target is null" sh -c "'$BIN/stat' --json file | python3 -c 'import json,sys;assert json.load(sys.stdin)[\"link_target\"] is None'"
t "mtime nsec" sh -c "'$BIN/stat' --json file | python3 -c 'import json,sys;d=json.load(sys.stdin);assert (d[\"mtime\"],d[\"mtime_nsec\"])==(1234567890,123456789)'"
t "non-UTF-8 name still parses" sh -c "'$BIN/stat' --json bad* | python3 -c 'import json,sys;json.load(sys.stdin)'"
t "one line per operand" sh -c "[ \"\$('$BIN/stat' --json file dir empty | wc -l)\" = 3 ]"
t "missing operand: others still printed, status 1" sh -c "out=\$('$BIN/stat' --json nofile file 2>/dev/null); rc=\$?; [ \$rc = 1 ] && [ \$(echo \"\$out\" | wc -l) = 1 ]"
t "-f parses and matches block counts" sh -c "[ \"\$('$BIN/stat' --json -f / | python3 -c 'import json,sys;print(json.load(sys.stdin)[\"block_size\"])')\" = \"\$(stat -f -c %s /)\" ]"
t "--json with -c is refused" sh -c "! '$BIN/stat' --json -c %n file"
t "--json with -t is refused" sh -c "! '$BIN/stat' --json -t file"
t "--json is listed in --help as a non-GNU line" sh -c "'$BIN/stat' --help | grep -q -e '--json .*not in GNU' -e '-json .*JSON'"

echo "Summary: $pass passed, $fail failed"
[ "$fail" = 0 ]
