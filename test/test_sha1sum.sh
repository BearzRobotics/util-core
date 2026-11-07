#!/bin/sh
# sha1sum: differential tests against GNU sha1sum 9.7 (C locale); see hashtests.sh.
UTIL="sha1sum"
. "$(dirname "$0")/testlib.sh"
. "$(dirname "$0")/hashtests.sh"
print_summary
