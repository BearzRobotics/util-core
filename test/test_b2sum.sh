#!/bin/sh
UTIL="b2sum"
. "$(dirname "$0")/testlib.sh"

echo "hello world" > /tmp/test_b2sum.txt
echo "foo bar baz" > /tmp/test_b2sum2.txt

printf "\n[ Basic hashing ]\n"
run_test_file "hash a file"              /tmp/test_b2sum.txt
run_test_file "hash empty input"         /dev/null
run_test_file "-l 256 truncated hash"   /tmp/test_b2sum.txt -l 256
run_test_file "-l 128 truncated hash"   /tmp/test_b2sum.txt -l 128

printf "\n[ Multiple files ]\n"
run_test "hash two files" /tmp/test_b2sum.txt /tmp/test_b2sum2.txt

printf "\n[ Flags ]\n"
run_test "--tag BSD style" --tag /tmp/test_b2sum.txt
run_test "-b binary mode" -b /tmp/test_b2sum.txt
run_test "-t text mode"   -t /tmp/test_b2sum.txt

rm -f /tmp/test_b2sum.txt /tmp/test_b2sum2.txt
print_summary
