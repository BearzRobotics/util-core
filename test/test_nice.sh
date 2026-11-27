#!/bin/sh
# nice: differential tests against GNU nice 9.7 (C locale). References: GNU
# manual "nice invocation"; POSIX.1-2024 nice. Negative adjustments need
# privilege; unprivileged runs compare the warning and that the command runs.
UTIL="nice"
. "$(dirname "$0")/testlib.sh"
help_cmp
run_cmp "no args"
run_cmp "-n 5 nice"            -n 5 nice
run_cmp "-n 0 nice"            -n 0 nice
run_cmp "-n -5 nice"           -n -5 nice
run_cmp "-n 19 nice"           -n 19 nice
run_cmp "-n 100 nice"          -n 100 nice
run_cmp "-n -100 nice"         -n -100 nice
run_cmp "-n +3 nice"           -n +3 nice
run_cmp "-n5 attached"         -n5 nice
run_cmp "--adjustment=7"       --adjustment=7 nice
run_cmp "--adjustment 7"       --adjustment 7 nice
run_cmp "--adj=7"              --adj=7 nice
run_cmp "-5 obsolete"          -5 nice
run_cmp "--5 obsolete"         --5 nice
run_cmp "-n abc"               -n abc true
run_cmp "-n empty"             -n '' true
run_cmp "-n 1x"                -n 1x true
run_cmp "-n 99999999999999999999 nice" -n 99999999999999999999 nice
run_cmp "adjustment no command" -n 5
run_cmp "-n needs arg"         -n
run_cmp "bad option"           -x
run_cmp "not found"            -n 5 nonexistent-cmd
run_cmp "directory"            /etc
run_cmp "exit status"          sh -c 'exit 9'
run_cmp "default adds 10"      nice
run_cmp "nested"              -n 3 nice -n 4 nice
run_cmp "-- operand"           -n 2 -- nice
run_cmp "command options kept" nice -n 1 true
run_cmp "args passed"          printf '[%s]' a b
# An adjustment near the ends of 64 bits, from a niceness that is not 0 (MISC-009).
for n in 9223372036854775807 -9223372036854775808 99999999999999999999 -99999999999999999999; do
    run_cmp "nice $n from 5" -n 5 /usr/bin/nice sh -c 'exec "$0" -n "$1" /usr/bin/nice' /usr/bin/nice $n
    exp=$(/usr/bin/nice -n 5 /usr/bin/nice -n $n /usr/bin/nice 2>&1; echo "status $?")
    act=$("$BIN_DIR/nice" -n 5 "$BIN_DIR/nice" -n $n /usr/bin/nice 2>&1; echo "status $?")
    if [ "$exp" = "$act" ]; then PASS=$((PASS + 1)); echo "PASS ours from 5, $n"
    else FAIL=$((FAIL + 1)); echo "FAIL ours from 5, $n: GNU $exp, ours $act"; fi
done

print_summary
[ "$FAIL" -eq 0 ]
