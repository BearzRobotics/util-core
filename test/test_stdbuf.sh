#!/bin/sh
# stdbuf: differential tests against GNU stdbuf 9.7 (C locale). References: GNU
# manual "stdbuf invocation". Both use GNU's libstdbuf.so, so the environment
# handed to the command is compared, plus a buffering behaviour check.
UTIL="stdbuf"
. "$(dirname "$0")/testlib.sh"
help_cmp
E="env -u _ -u LC_ALL"
run_cmp "no args"
run_cmp "no mode"              true
run_cmp "mode without cmd"     -oL
run_cmp "-i needs arg"         -i
run_cmp "-x"                   -x L true
run_cmp "-iL"                  -iL true
run_cmp "-o abc"               -o abc true
run_cmp "-o -1"                -o -1 true
run_cmp "-o empty"             -o '' true
run_cmp "-o huge"              -o 99999999999999999999 true
run_cmp "not found"            -oL nonexistent-cmd
run_cmp "directory"            -oL /etc
for m in 0 1 L 4096 4K 1KB 1M 1MB 2G 1KiB; do
    run_cmp "-o $m env"        -o $m $E
    run_cmp "-e $m env"        -e $m $E
    run_cmp "-i $m env"        -i $m $E
done
run_cmp "all three"            -i 4K -oL -e0 $E
run_cmp "order irrelevant"     -e 0 -o L -i 1 $E
run_cmp "long options"         --input=1 --output=L --error=0 $E
run_cmp "long separate"        --input 1 --output L $E
run_cmp "long abbrev"          --out=L $E
run_cmp "LD_PRELOAD kept"      -oL env -u _ -u LC_ALL LD_PRELOAD=/lib/x.so env
run_cmp "-- command"           -oL -- $E
run_cmp "exit status"          -oL sh -c 'exit 5'
run_cmp "pipe line buffering"  -oL sh -c 'printf a; printf b'
# Behaviour: a stdio program writing to a pipe flushes per line with -oL.
run_cmp "awk -oL"              -oL awk 'BEGIN{print "x"}'
print_summary
[ "$FAIL" -eq 0 ]
