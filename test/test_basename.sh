#!/bin/sh
UTIL="basename"
. "$(dirname "$0")/testlib.sh"

printf "\n[ Basic usage ]\n"
run_cmp "simple path"             /usr/bin/echo
run_cmp "path with trailing /"    /usr/bin/
run_cmp "just filename"           echo
run_cmp "root"                    /
run_cmp "dot"                     .
run_cmp "dotdot"                  ..

printf "\n[ Suffix stripping ]\n"
run_cmp "strip .sh suffix"        script.sh .sh
run_cmp "strip .tar.gz suffix"    archive.tar.gz .tar.gz
run_cmp "suffix not present"      script.sh .py

printf "\n[ -a multiple args ]\n"
run_cmp "-a multiple paths"       -a /usr/bin/echo /usr/bin/ls /usr/bin/cat

printf "\n[ -s with -a ]\n"
run_cmp "-a -s strip suffix"      -a -s .sh foo.sh bar.sh

run_cmp "-z"                      -z /a/b
run_cmp "-za"                     -za /a/b /c/d/
run_cmp "-z -s"                   -z -s .sh x.sh y.sh
run_cmp "no operand"
run_cmp "extra operand"           a b c
run_cmp "bad option"              -x

print_summary
[ "$FAIL" -eq 0 ]
