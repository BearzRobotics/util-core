#!/bin/sh
UTIL="dirname"
. "$(dirname "$0")/testlib.sh"

printf "\n[ Basic usage ]\n"
run_cmp "simple path"              /usr/bin/echo
run_cmp "no directory"             echo
run_cmp "trailing slash"           /usr/bin/
run_cmp "root"                     /
run_cmp "dot"                      .
run_cmp "dotdot"                   ..
run_cmp "nested path"              /a/b/c/d

printf "\n[ -z zero terminated ]\n"
run_cmp "-z multiple args"         -z /usr/bin/echo /usr/lib/x86_64

run_cmp "-z one"                  -z /a/b
run_cmp "no operand"
run_cmp "bad option"              -x

print_summary
[ "$FAIL" -eq 0 ]
