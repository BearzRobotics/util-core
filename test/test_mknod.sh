#!/bin/sh
# mknod: differential tests against GNU mknod 9.7 (C locale). References: GNU
# manual "mknod invocation". Block/character devices need privilege, so for an
# unprivileged user those cases compare the diagnostics.
UTIL="mknod"
. "$(dirname "$0")/testlib.sh"
help_cmp
S='touch exists; mkdir d'
run_tree "no args"            "$S"
run_tree "name only"          "$S" x
run_tree "fifo"               "$S" x p
run_tree "fifo in dir"        "$S" d/x p
run_tree "fifo exists"        "$S" exists p
run_tree "fifo missing dir"   "$S" nodir/x p
run_tree "fifo with numbers"  "$S" x p 1 2
run_tree "fifo with one num"  "$S" x p 1
run_tree "fifo with three"    "$S" x p 1 2 3
run_tree "char no numbers"    "$S" x c
run_tree "char one number"    "$S" x c 1
run_tree "block no numbers"   "$S" x b
run_tree "unsigned no nums"   "$S" x u
run_tree "char extra"         "$S" x c 1 2 3
run_tree "char bad major"     "$S" x c a 2
run_tree "char bad minor"     "$S" x c 1 b
run_tree "char hex"           "$S" x c 0x1 0x3
run_tree "char devnull"       "$S" x c 1 3
run_tree "block loop"         "$S" x b 7 0
# MAJOR and MINOR must fit in 32 bits; 4294967296 once meant 0, and "0 0" is a
# node that needs no privilege. Forms are those of strtoumax in base 0. Majors
# of 4096 and more do not fit the system call.
for n in 4294967296 8589934592 18446744073709551616 4294967295 4294967294 4096 4095 0b1 0B1 0b 0b2 0o7 1_000 ' 1' '1 ' ' +1' '+0x1' '++1' '+' ' ' 010 08 0x10 0X1f 0x 0x_1 0x+1 1k; do
    run_tree "major '$n'"     "$S" x c "$n" 7
    run_tree "minor '$n'"     "$S" x c 7 "$n"
done
run_tree "major wraps to 0"   "$S" x c 4294967296 0
run_tree "minor wraps to 0"   "$S" x c 0 4294967296
run_tree "block major wraps"  "$S" x b 4294967296 0
run_tree "no such device"     "$S" x c 4294967295 4294967295
run_tree "char 0 0"           "$S" x c 0 0
run_tree "bad type"           "$S" x q
run_tree "long type"          "$S" x pp
run_tree "empty type"         "$S" x ''
run_tree "r type"             "$S" x r
for m in 600 644 666 700 777 000 u+x g-r a=rwx +x -w =r u=rw,go=; do
    run_tree "-m $m"          "$S" -m $m x p
    TREE_UMASK=077 run_tree "-m $m umask 077" "$S" -m $m x p
done
run_tree "-m 4755"            "$S" -m 4755 x p
run_tree "-m 1777"            "$S" -m 1777 x p
run_tree "-m abc"             "$S" -m abc x p
run_tree "-m empty"           "$S" -m '' x p
run_tree "--mode=600"         "$S" --mode=600 x p
run_tree "-m600 attached"     "$S" -m600 x p
run_tree "-m bad then missing" "$S" -m zz
TREE_UMASK=077 run_tree "umask 077" "$S" x p
TREE_UMASK=000 run_tree "umask 000" "$S" x p
run_tree "-Z"                 "$S" -Z x p
run_tree "--context=x"        "$S" --context=x x p
run_tree "bad option"         "$S" -x x p
run_tree "-- operands"        "$S" -- x p
run_tree "dash name"          "$S" -- -x p
# The new file is replaced by a link to "victim" before mknod sets its mode;
# strace holds mknod after the call that creates it.
d=$(mktemp -d)
if can_inject; then
    : > "$d/victim"
    chmod 600 "$d/victim"
    (cd "$d" && exec timeout 30 strace -o /dev/null -e trace=mknodat -e inject=mknodat:delay_exit=1500000:when=1 "$BIN_DIR/mknod" -m 666 node p > out 2>&1) & race_pid=$!
    tries=0
    while [ ! -e "$d/node" ] && [ "$tries" -lt 200 ]; do sleep 0.05; tries=$((tries + 1)); done
    mv "$d/node" "$d/moved" && ln -s victim "$d/node"
    wait "$race_pid"; rc=$?
    mode=$(stat -c %a "$d/victim")
    if [ "$rc" -eq 1 ] && [ "$mode" = 600 ]; then
        PASS=$((PASS + 1)); echo "PASS mknod -m 666 node p does not change the target of a swapped-in link"
    else
        FAIL=$((FAIL + 1)); echo "FAIL mknod -m 666 node p does not change the target of a swapped-in link (rc=$rc, victim $mode)"; cat "$d/out"
    fi
else
    skip_test "mknod -m 666 node p link race (needs strace)"
fi
chmod -R u+rwx "$d"; rm -rf "$d"
print_summary
[ "$FAIL" -eq 0 ]
