#!/bin/sh
UTIL="basename"
. "$(dirname "$0")/testlib.sh"

printf "\n[ Basic usage ]\n"
run_test "simple path"             /usr/bin/echo
run_test "path with trailing /"    /usr/bin/
run_test "just filename"           echo
run_test "root"                    /
run_test "dot"                     .
run_test "dotdot"                  ..

printf "\n[ Suffix stripping ]\n"
run_test "strip .sh suffix"        script.sh .sh
run_test "strip .tar.gz suffix"    archive.tar.gz .tar.gz
run_test "suffix not present"      script.sh .py

printf "\n[ -a multiple args ]\n"
run_test "-a multiple paths"       -a /usr/bin/echo /usr/bin/ls /usr/bin/cat

printf "\n[ -s with -a ]\n"
run_test "-a -s strip suffix"      -a -s .sh foo.sh bar.sh

print_summary
