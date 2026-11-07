#!/bin/sh
# logname: differential tests against GNU logname 9.7. The result depends on
# the session (loginuid), so only the cases that agree here are compared.
UTIL="logname"
. "$(dirname "$0")/testlib.sh"
run_cmp "logname"
run_cmp "operand"           x
run_cmp "-x"                -x
run_cmp "--bogus"           --bogus
print_summary
