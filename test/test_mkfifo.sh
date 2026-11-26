#!/bin/sh
# mkfifo: differential tests against GNU mkfifo 9.7 (C locale). References: GNU
# manual "mkfifo invocation"; POSIX.1-2024 mkfifo.
UTIL="mkfifo"
. "$(dirname "$0")/testlib.sh"
help_cmp
S='touch exists; mkdir d; ln -s nowhere dangling'
run_tree "no args"            "$S"
run_tree "one"                "$S" a
run_tree "several"            "$S" a b c
run_tree "exists"             "$S" exists
run_tree "mixed"              "$S" a exists b
run_tree "in dir"             "$S" d/x
run_tree "missing dir"        "$S" nodir/x
run_tree "dangling symlink"   "$S" dangling
run_tree "directory name"     "$S" d
run_tree "trailing slash"     "$S" a/
run_tree "dash name"          "$S" -- -a
run_tree "weird name"         "$S" 'a b'
for m in 600 644 666 700 777 000 4755 1777 u+x g-r a=rwx +x -w =r o+rwx u=rw,go= 0 a+x,a-r; do
    run_tree "-m $m"          "$S" -m $m a
    TREE_UMASK=077 run_tree "-m $m umask 077" "$S" -m $m a
    TREE_UMASK=000 run_tree "-m $m umask 000" "$S" -m $m a
done
run_tree "-m abc"             "$S" -m abc a
run_tree "-m empty"           "$S" -m '' a
run_tree "-m 999"             "$S" -m 999 a
run_tree "--mode=600"         "$S" --mode=600 a
run_tree "--mode 600"         "$S" --mode 600 a
run_tree "-m600 attached"     "$S" -m600 a
run_tree "-m needs arg"       "$S" -m
run_tree "umask 077 default"  "$S" a
TREE_UMASK=077 run_tree "umask 077" "$S" a
TREE_UMASK=000 run_tree "umask 000" "$S" a
TREE_UMASK=277 run_tree "umask 277" "$S" a
run_tree "-Z"                 "$S" -Z a
run_tree "--context"          "$S" --context a
run_tree "--context=x"        "$S" --context=x a
run_tree "bad option"         "$S" -x a
run_tree "long abbrev"        "$S" --mo=600 a
run_tree "fifo is fifo"       "$S; " a
# The new file is replaced by a link to "victim" before mkfifo sets its mode;
# strace holds mkfifo after the call that creates it.
d=$(mktemp -d)
if can_inject; then
    : > "$d/victim"
    chmod 600 "$d/victim"
    (cd "$d" && exec timeout 30 strace -o /dev/null -e trace=mknodat -e inject=mknodat:delay_exit=1500000:when=1 "$BIN_DIR/mkfifo" -m 666 node > out 2>&1) & race_pid=$!
    tries=0
    while [ ! -e "$d/node" ] && [ "$tries" -lt 200 ]; do sleep 0.05; tries=$((tries + 1)); done
    mv "$d/node" "$d/moved" && ln -s victim "$d/node"
    wait "$race_pid"; rc=$?
    mode=$(stat -c %a "$d/victim")
    if [ "$rc" -eq 1 ] && [ "$mode" = 600 ]; then
        PASS=$((PASS + 1)); echo "PASS mkfifo -m 666 node does not change the target of a swapped-in link"
    else
        FAIL=$((FAIL + 1)); echo "FAIL mkfifo -m 666 node does not change the target of a swapped-in link (rc=$rc, victim $mode)"; cat "$d/out"
    fi
else
    skip_test "mkfifo -m 666 node link race (needs strace)"
fi
chmod -R u+rwx "$d"; rm -rf "$d"
print_summary
[ "$FAIL" -eq 0 ]
