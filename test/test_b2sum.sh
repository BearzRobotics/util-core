#!/bin/sh
# b2sum: differential tests against GNU b2sum 9.7 (C locale); see hashtests.sh.
UTIL="b2sum"
. "$(dirname "$0")/testlib.sh"
. "$(dirname "$0")/hashtests.sh"
print_summary
