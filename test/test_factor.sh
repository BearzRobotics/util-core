#!/bin/sh
UTIL="factor"
. "$(dirname "$0")/testlib.sh"

printf "\n[ Factoring numbers ]\n"
run_test "factor 12"                12
run_test "factor 100"               100
run_test "factor prime 97"          97
run_test "factor 1"                 1
run_test "factor large"             123456789
run_test "multiple numbers"         12 15 20

print_summary
