#!/bin/sh
# md5sum: differential tests against GNU md5sum 9.7 (C locale); see hashtests.sh.
UTIL="md5sum"
. "$(dirname "$0")/testlib.sh"
. "$(dirname "$0")/hashtests.sh"
print_summary
