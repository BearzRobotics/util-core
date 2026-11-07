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
print_summary
[ "$FAIL" -eq 0 ]
