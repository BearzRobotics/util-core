#!/bin/sh
UTIL="dirname"
. "$(dirname "$0")/testlib.sh"

printf "\n[ Basic usage ]\n"
run_test "simple path"              /usr/bin/echo
run_test "no directory"             echo
run_test "trailing slash"           /usr/bin/
run_test "root"                     /
run_test "dot"                      .
run_test "dotdot"                   ..
run_test "nested path"              /a/b/c/d

printf "\n[ -z zero terminated ]\n"
run_test "-z multiple args"         -z /usr/bin/echo /usr/lib/x86_64

print_summary
