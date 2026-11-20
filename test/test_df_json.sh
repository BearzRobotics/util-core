#!/bin/sh
# df --json: GNU df has no --json, so each field is compared with what GNU
# `df -B1 --output=...` prints for the same operand (GNU coreutils 9.7). Sizes
# and counts that change while the test runs (used, avail, free inodes) are
# compared with a tolerance. Needs python3 and GNU df.
BIN="$(cd "${OURS_DIR:-$(dirname "$0")/../zig-out/bin}" && pwd)"
pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
t() { name=$1; shift; if "$@" >/dev/null 2>&1; then ok; else bad "$name"; fi; }

for f in / /tmp /dev /proc /run /sys "$HOME"; do
    [ -e "$f" ] || continue
    gnu=$(df -B1 --output=source,fstype,size,used,avail,itotal,target -- "$f" 2>/dev/null | tail -n 1)
    [ -n "$gnu" ] || continue
    if "$BIN/df" --json -- "$f" | GNU_LINE="$gnu" python3 -c '
import json, os, sys
e = json.load(sys.stdin)
assert len(e) == 1, len(e)
e = e[0]
g = os.environ["GNU_LINE"].split()
source, fstype, size, used, avail, itotal = g[0], g[1], g[2], g[3], g[4], g[5]
target = " ".join(g[6:])
assert e["source"] == source, (e["source"], source)
assert e["fstype"] == fstype, (e["fstype"], fstype)
assert e["target"] == target, (e["target"], target)
assert e["file"] == sys.argv[1], e["file"]
assert e["size"] == int(size), (e["size"], size)
assert e["inodes"] == int(itotal), (e["inodes"], itotal)
tol = 256 * 1024 * 1024
assert abs(e["used"] - int(used)) < tol, (e["used"], used)
assert abs(e["avail"] - int(avail)) < tol, (e["avail"], avail)
assert e["size"] >= e["used"] >= 0 or e["used"] < 0
assert e["total"] is False
' "$f" 2>/dev/null; then ok; else bad "operand $f"; fi
done

# Without operands: the same mounts as GNU df (the visible, non-dummy ones).
gnu_n=$(df -B1 --output=target 2>/dev/null | tail -n +2 | wc -l)
ours_n=$("$BIN/df" --json | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')
[ "$gnu_n" = "$ours_n" ] && ok || bad "mount count: GNU=$gnu_n OURS=$ours_n"
gnu_t=$(df -B1 --output=target 2>/dev/null | tail -n +2 | sort)
ours_t=$("$BIN/df" --json | python3 -c 'import json,sys;print("\n".join(e["target"] for e in json.load(sys.stdin)))' | sort)
[ "$gnu_t" = "$ours_t" ] && ok || bad "mount targets differ"
gnu_a=$(df -a -B1 --output=target 2>/dev/null | tail -n +2 | sort)
ours_a=$("$BIN/df" --json -a | python3 -c 'import json,sys;print("\n".join(e["target"] for e in json.load(sys.stdin)))' | sort)
[ "$gnu_a" = "$ours_a" ] && ok || bad "-a mount targets differ"

t "--total adds one last total entry" sh -c "'$BIN/df' --json --total / | python3 -c 'import json,sys;r=json.load(sys.stdin);assert len(r)==2 and r[1][\"total\"] and r[1][\"source\"] is None and not r[0][\"total\"]'"
t "--total size is the sum" sh -c "'$BIN/df' --json --total / /tmp | python3 -c 'import json,sys;r=json.load(sys.stdin);assert r[-1][\"size\"]==sum(e[\"size\"] for e in r[:-1])'"
t "-t selects types like GNU" sh -c "[ \"\$('$BIN/df' --json -t tmpfs | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')\" = \"\$(df -t tmpfs --output=target | tail -n +2 | wc -l)\" ]"
t "-x excludes types like GNU" sh -c "[ \"\$('$BIN/df' --json -x tmpfs | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')\" = \"\$(df -x tmpfs --output=target | tail -n +2 | wc -l)\" ]"
t "missing operand: status 1, no entries for it" sh -c "out=\$('$BIN/df' --json /nonexistent / 2>/dev/null); rc=\$?; [ \$rc = 1 ] && echo \"\$out\" | python3 -c 'import json,sys;assert len(json.load(sys.stdin))==1'"
for o in -h -H -k -m -i -P -T "-B1" --output; do
    t "--json with $o is refused" sh -c "! '$BIN/df' --json $o"
done
t "--json is listed in --help as a non-GNU line" sh -c "'$BIN/df' --help | grep -q -e '--json .*not in GNU' -e '-json .*JSON'"
t "inode counts are plain numbers" sh -c "'$BIN/df' --json / | python3 -c 'import json,sys;e=json.load(sys.stdin)[0];assert isinstance(e[\"inodes\"],int) and isinstance(e[\"inodes_used\"],int)'"

echo "Summary: $pass passed, $fail failed"
[ "$fail" = 0 ]
