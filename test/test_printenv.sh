#!/bin/sh
UTIL="printenv"
. "$(dirname "$0")/testlib.sh"

printf "\n[ Basic usage ]\n"
run_test "print PATH"                PATH
run_test "print HOME"                HOME
run_test "print nonexistent"         NONEXISTENT_VAR_XYZ
run_test_exit "-0 null terminated"   -0

print_summary
