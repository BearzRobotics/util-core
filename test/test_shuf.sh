#!/bin/sh
UTIL="shuf"
. "$(dirname "$0")/testlib.sh"

printf "apple\nbanana\ncherry\ndate\n" > /tmp/test_shuf.txt

printf "\n[ Basic usage ]\n"
# shuf output is random so we can only check counts/exit codes
run_test_exit "shuffle file"             /tmp/test_shuf.txt
run_test_exit "-n limit output"          -n 2 /tmp/test_shuf.txt
run_test_exit "-r repeat allowed"        -r -n 5 /tmp/test_shuf.txt
run_test_exit "-e shuffle args"          -e a b c d
run_test_exit "-i range"                 -i 1-10

rm -f /tmp/test_shuf.txt
print_summary
