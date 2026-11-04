#!/bin/sh
UTIL="expr"
. "$(dirname "$0")/testlib.sh"

printf "\n[ Arithmetic ]\n"
run_test "addition"                 1 + 2
run_test "subtraction"             10 - 3
run_test "multiplication"           3 \* 4
run_test "division"                 10 / 3
run_test "modulo"                   10 % 3

printf "\n[ Comparison ]\n"
run_test "equal"                    1 = 1
run_test "not equal"                1 != 2
run_test "less than"                1 \< 2
run_test "greater than"             2 \> 1

printf "\n[ String ops ]\n"
run_test "length"                   length "hello"
run_test "substr"                   substr "hello" 2 3
run_test "index"                    index "hello" "l"
run_test "match"                    match "hello123" '[0-9]*'

printf "\n[ Logic ]\n"
run_test "and true"                 1 \& 1
run_test "or false true"            0 \| 1

print_summary
