#!/bin/sh
UTIL="echo"
. "$(dirname "$0")/testlib.sh"

printf "\n[ Basic usage ]\n"
run_cmp "no args"
run_cmp "single arg"            hello
run_cmp "multiple args"         hello big world
run_cmp "empty arg"             ""
run_cmp "-n"                    -n hello
run_cmp "-- is literal"         -- hello

printf "\n[ Escapes ]\n"
run_cmp "-e newline"            -e 'a\nb'
run_cmp "-e tab"                -e 'a\tb'
run_cmp "-e octal"              -e 'a\0101b'
run_cmp "-e hex"                -e 'a\x41b'
run_cmp "-e \\c stops output"   -e 'a\cb' c
run_cmp "-E leaves escapes"     -E 'a\nb'
run_cmp "-ne combined"          -ne 'a\nb'
run_cmp "-x is literal"         -x hello

run_cmp "-n alone"                -n
run_cmp "-n with nothing printed" -n ""
run_cmp "-n -n"                   -n -n x
run_cmp "-e trailing newline"     -e 'a\n'
run_cmp "-e NUL"                  -e 'a\0000b'
run_cmp "trailing newlines kept"  "$(printf 'a\n\nx')" ""
run_cmp "--help is literal here"  hello --help

print_summary
[ "$FAIL" -eq 0 ]
