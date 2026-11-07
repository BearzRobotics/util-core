#!/bin/sh
# arch: differential tests against GNU arch 9.7.
UTIL="arch"
. "$(dirname "$0")/testlib.sh"
run_cmp "arch"
run_cmp "operand"           x
run_cmp "-x"                -x
run_cmp "--bogus"           --bogus
run_cmp "--"                --
print_summary
