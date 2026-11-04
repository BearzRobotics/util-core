#!/bin/sh
UTIL="timeout"
. "$(dirname "$0")/testlib.sh"

printf "\n[ Basic usage ]\n"
run_test_exit "command completes"        1 sleep 0.1
run_test_exit "command times out"        0.1 sleep 5
run_test_exit "-k kill after"            -k 1 0.1 sleep 5
run_test_exit "--preserve-status"        --preserve-status 1 true
run_test_exit "-s signal"                -s TERM 1 sleep 5

print_summary
