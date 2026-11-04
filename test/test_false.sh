#!/bin/sh
UTIL="false"
. "$(dirname "$0")/testlib.sh"

printf "\n[ Exit code ]\n"
run_test_exit "always exits 1"
run_test_exit "ignores arguments"   some args here

print_summary
