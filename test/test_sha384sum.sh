#!/bin/sh
# sha384sum: differential tests against GNU sha384sum 9.7 (C locale); see hashtests.sh.
UTIL="sha384sum"
. "$(dirname "$0")/testlib.sh"
. "$(dirname "$0")/hashtests.sh"
print_summary
