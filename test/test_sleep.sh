#!/bin/sh
UTIL="sleep"
. "$(dirname "$0")/testlib.sh"

printf "\n[ Basic usage ]\n"
run_test_exit "sleep 0"              0
run_test_exit "sleep 0.1"            0.1
run_test_exit "sleep with suffix s"  0.1s
run_test_exit "sleep with suffix m"  0.01m
run_test_exit "multiple args sum"    0.05 0.05

print_summary
