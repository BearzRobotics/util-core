#!/bin/sh
UTIL="seq"
. "$(dirname "$0")/testlib.sh"

printf "\n[ Basic sequences ]\n"
run_test "1 to 5"                    5
run_test "2 to 8"                    2 8
run_test "1 to 10 step 2"            1 2 10
run_test "float step"                0 0.5 2
run_test "descending"                5 -1 1

printf "\n[ Formatting ]\n"
run_test "-w equal width"            -w 1 10
run_test "-f format"                 -f "%05g" 5
run_test "-s separator"              -s, 1 5

print_summary
