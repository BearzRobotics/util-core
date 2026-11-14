#!/bin/sh
# du --json: GNU du has no --json, so each entry is compared with what GNU du
# prints for the same tree (GNU coreutils 9.7): `du -B1` for bytes, `du --inodes`
# for counts, `du --time` for the time. Needs python3 and GNU du.
BIN="$(cd "${OURS_DIR:-$(dirname "$0")/../zig-out/bin}" && pwd)"
pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
t() { name=$1; shift; if "$@" >/dev/null 2>&1; then ok; else bad "$name"; fi; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT; cd "$W" || exit 1
mkdir -p tree/a/b tree/c "tree/we ird"; head -c 100000 /dev/zero > tree/big; printf x > tree/a/small; printf hi > tree/a/b/deep
ln tree/a/small tree/hard; ln -s a tree/lnk; : > tree/empty; mkdir tree/noaccess; chmod 000 tree/noaccess
touch -d @1234567890.5 tree/a/small
export TZ=UTC

# compare: GNU du output lines (size<TAB>path) against our JSON, as {path: size}
cmp_opts() { # name, options for both
    name=$1; shift
    gnu=$(du -B1 "$@" tree 2>/dev/null | sort)
    ours=$("$BIN/du" --json "$@" tree 2>/dev/null | python3 -c '
import json,sys
for e in json.load(sys.stdin): print("%d\t%s" % (e["size"], e["path"]))' | sort)
    [ -n "$gnu" ] && [ "$gnu" = "$ours" ] && ok || { bad "$name"; echo "--- GNU"; echo "$gnu" | head -4; echo "--- OURS"; echo "$ours" | head -4; }
}
cmp_opts "default"
cmp_opts "-a"                 -a
cmp_opts "-s"                 -s
cmp_opts "-d1"                -d 1
cmp_opts "-S"                 -S
cmp_opts "-l"                 -l
cmp_opts "-c"                 -c
cmp_opts "-b apparent"        -b
cmp_opts "--apparent-size"    --apparent-size
cmp_opts "-L"                 -L
cmp_opts "-x"                 -x
cmp_opts "--exclude"          --exclude=b
cmp_opts "-t threshold"       -t 5000
cmp_opts "-ac"                -a -c

# inode counts
gnu=$(du --inodes tree 2>/dev/null | sort)
ours=$("$BIN/du" --json tree 2>/dev/null | python3 -c '
import json,sys
for e in json.load(sys.stdin): print("%d\t%s" % (e["inodes"], e["path"]))' | sort)
[ -n "$gnu" ] && [ "$gnu" = "$ours" ] && ok || bad "inodes"
gnu=$(du --inodes -a tree 2>/dev/null | sort)
ours=$("$BIN/du" --json -a tree 2>/dev/null | python3 -c '
import json,sys
for e in json.load(sys.stdin): print("%d\t%s" % (e["inodes"], e["path"]))' | sort)
[ -n "$gnu" ] && [ "$gnu" = "$ours" ] && ok || bad "inodes -a"

# times: GNU prints the latest time under each path with --time
for kind in mtime atime ctime; do
    # GNU du has no --time=mtime word: plain --time shows the modification time.
    if [ $kind = mtime ]; then topt="--time"; else topt="--time=$kind"; fi
    gnu=$(du $topt --time-style=+%s -a tree 2>/dev/null | awk -F'\t' '{print $2"\t"$3}' | sort)
    ours=$("$BIN/du" --json $topt -a tree 2>/dev/null | python3 -c '
import json,sys
for e in json.load(sys.stdin): print("%d\t%s" % (e["time"], e["path"]))' | sort)
    [ -n "$gnu" ] && [ "$gnu" = "$ours" ] && ok || bad "time $kind"
done
t "time_kind names the kind" sh -c "'$BIN/du' --json --time=ctime -s tree | python3 -c 'import json,sys;assert json.load(sys.stdin)[0][\"time_kind\"]==\"ctime\"'"
t "default time kind is mtime" sh -c "'$BIN/du' --json -s tree | python3 -c 'import json,sys;assert json.load(sys.stdin)[0][\"time_kind\"]==\"mtime\"'"

t "--total is flagged and last" sh -c "'$BIN/du' --json -c tree tree/a 2>/dev/null | python3 -c 'import json,sys;r=json.load(sys.stdin);assert r[-1][\"total\"] and r[-1][\"path\"]==\"total\" and not any(e[\"total\"] for e in r[:-1])'"
t "several operands" sh -c "[ \"\$('$BIN/du' --json -s tree/a tree/c 2>/dev/null | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')\" = 2 ]"
t "unreadable dir: entries printed, status 1" sh -c "'$BIN/du' --json tree >/dev/null 2>&1; [ \$? = 1 ]"
t "valid JSON for a name with a quote" sh -c "mkdir 'q\"d' && '$BIN/du' --json 'q\"d' | python3 -c 'import json,sys;assert json.load(sys.stdin)[0][\"path\"]==\"q\\\"d\"'"
for o in -h --si -k -m -B1 -0 --time-style=iso; do
    t "--json with $o is refused" sh -c "! '$BIN/du' --json $o tree"
done
t "--json is not in --help" sh -c "! '$BIN/du' --help | grep -q json"
chmod 700 tree/noaccess
echo "Summary: $pass passed, $fail failed"
[ "$fail" = 0 ]
