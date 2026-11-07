#!/bin/sh
# sha256sum: differential tests against GNU sha256sum 9.7 (C locale); see hashtests.sh.
UTIL="sha256sum"
. "$(dirname "$0")/testlib.sh"
. "$(dirname "$0")/hashtests.sh"
print_summary
