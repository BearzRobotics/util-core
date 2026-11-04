#!/bin/sh
UTIL="echo"
. "$(dirname "$0")/testlib.sh"

printf "\n[ Basic usage ]\n"
run_test "no args"
run_test "single arg"            hello
run_test "multiple args"         hello big world
run_test "empty arg"             ""
run_test "-n"                    -n hello
run_test "-- is literal"         -- hello

printf "\n[ Escapes ]\n"
run_test "-e newline"            -e 'a\nb'
run_test "-e tab"                -e 'a\tb'
run_test "-e octal"              -e 'a\0101b'
run_test "-e hex"                -e 'a\x41b'
run_test "-e \\c stops output"   -e 'a\cb' c
run_test "-E leaves escapes"     -E 'a\nb'
run_test "-ne combined"          -ne 'a\nb'
run_test "-x is literal"         -x hello

print_summary
