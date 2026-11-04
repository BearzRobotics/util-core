#!/bin/sh
UTIL="printf"
. "$(dirname "$0")/testlib.sh"

printf "\n[ Format strings ]\n"
run_test "string %s"                 "%s\n" "hello"
run_test "integer %d"                "%d\n" 42
run_test "float %f"                  "%f\n" 3.14
run_test "hex %x"                    "%x\n" 255
run_test "octal %o"                  "%o\n" 8
run_test "char %c"                   "%c\n" 65

printf "\n[ Escape sequences ]\n"
run_test "newline in format"         "hello\nworld\n"
run_test "tab in format"             "hello\tworld\n"

printf "\n[ Width and precision ]\n"
run_test "%10s right align"          "%10s\n" "hello"
run_test "%-10s left align"          "%-10s\n" "hello"
run_test "%.3f precision"            "%.3f\n" 3.14159

print_summary
