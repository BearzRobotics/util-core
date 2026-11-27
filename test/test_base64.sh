#!/bin/sh
# base64: differential tests against GNU base64 9.7; see basetests.sh.
UTIL="base64"
. "$(dirname "$0")/testlib.sh"
ENC_OPT=""
. "$(dirname "$0")/basetests.sh"
# "1_0" is not 10: the digit separators of Zig source are refused (MISC-021).
echo x > "$TEST_TMP/us"
run_cmp "-w 1_0" -w 1_0 "$TEST_TMP/us"

print_summary
