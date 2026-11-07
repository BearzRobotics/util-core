#!/bin/sh
# base32: differential tests against GNU base32 9.7; see basetests.sh.
UTIL="base32"
. "$(dirname "$0")/testlib.sh"
ENC_OPT=""
. "$(dirname "$0")/basetests.sh"
print_summary
