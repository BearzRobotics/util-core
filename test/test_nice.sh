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
print_summary
[ "$FAIL" -eq 0 ]
