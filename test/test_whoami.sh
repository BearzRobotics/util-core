#!/bin/sh
# whoami: differential tests against GNU whoami 9.7.
UTIL="whoami"
. "$(dirname "$0")/testlib.sh"
run_cmp "whoami"
run_cmp "operand"           x
run_cmp "-x"                -x
run_cmp "--bogus"           --bogus
run_cmp "--"                --
print_summary
