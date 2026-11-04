#!/bin/sh
UTIL="env"
. "$(dirname "$0")/testlib.sh"

printf "\n[ Basic usage ]\n"
run_test_exit "print environment"
run_test_exit "-i empty environment"    -i
run_test_exit "set var"                 TEST_VAR=hello printenv TEST_VAR
run_test_exit "-u unset var"            -u HOME printenv HOME

printf "\n[ Running commands ]\n"
run_test "run command with var"         TEST_VAR=hello printenv TEST_VAR
run_test_exit "-i run clean env"        -i PATH=/usr/bin printenv PATH

print_summary
