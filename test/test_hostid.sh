#!/bin/sh
# hostid: differential tests against GNU hostid 9.7.
UTIL="hostid"
. "$(dirname "$0")/testlib.sh"
run_cmp "hostid"
run_cmp "operand"           x
run_cmp "-x"                -x
run_cmp "--bogus"           --bogus
print_summary
