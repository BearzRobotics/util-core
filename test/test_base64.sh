#!/bin/sh
# base64: differential tests against GNU base64 9.7; see basetests.sh.
UTIL="base64"
. "$(dirname "$0")/testlib.sh"
ENC_OPT=""
. "$(dirname "$0")/basetests.sh"
print_summary
