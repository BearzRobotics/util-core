#!/bin/sh
UTIL="sha224sum"
. "$(dirname "$0")/testlib.sh"

echo "hello world" > /tmp/test_sha224.txt
printf "\n[ Basic hashing ]\n"
run_test_file "hash file"  /tmp/test_sha224.txt
run_test "--tag BSD style" --tag /tmp/test_sha224.txt
/usr/bin/sha224sum /tmp/test_sha224.txt > /tmp/test_sha224.check
run_test_exit "-c check"   -c /tmp/test_sha224.check
rm -f /tmp/test_sha224.txt /tmp/test_sha224.check
print_summary
