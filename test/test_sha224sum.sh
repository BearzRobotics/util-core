#!/bin/sh
# sha224sum: differential tests against GNU sha224sum 9.7 (C locale); see hashtests.sh.
UTIL="sha224sum"
. "$(dirname "$0")/testlib.sh"
. "$(dirname "$0")/hashtests.sh"
print_summary
