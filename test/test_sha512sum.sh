#!/bin/sh
# sha512sum: differential tests against GNU sha512sum 9.7 (C locale); see hashtests.sh.
UTIL="sha512sum"
. "$(dirname "$0")/testlib.sh"
. "$(dirname "$0")/hashtests.sh"
print_summary
