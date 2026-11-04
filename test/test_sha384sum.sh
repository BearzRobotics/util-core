#!/bin/sh
UTIL="sha384sum"
. "$(dirname "$0")/testlib.sh"

echo "hello world" > /tmp/test_sha384.txt
printf "\n[ Basic hashing ]\n"
run_test_file "hash file"  /tmp/test_sha384.txt
run_test "--tag BSD style" --tag /tmp/test_sha384.txt
/usr/bin/sha384sum /tmp/test_sha384.txt > /tmp/test_sha384.check
run_test_exit "-c check"   -c /tmp/test_sha384.check
rm -f /tmp/test_sha384.txt /tmp/test_sha384.check
print_summary
