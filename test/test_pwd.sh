#!/bin/sh
UTIL="pwd"
. "$(dirname "$0")/testlib.sh"

printf "\n[ Basic usage ]\n"
run_test "print working directory"
run_test "-L logical path"           -L
run_test "-P physical path"          -P

print_summary
