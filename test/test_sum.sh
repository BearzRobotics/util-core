#!/bin/sh
UTIL="sum"
. "$(dirname "$0")/testlib.sh"

echo "hello world" > /tmp/test_sum.txt

printf "\n[ Basic usage ]\n"
run_test_file "default checksum"     /tmp/test_sum.txt
run_test_file "-r BSD algorithm"     /tmp/test_sum.txt -r
run_test_file "-s System V"          /tmp/test_sum.txt -s
run_test "multiple files"            /tmp/test_sum.txt /tmp/test_sum.txt

rm -f /tmp/test_sum.txt
print_summary
