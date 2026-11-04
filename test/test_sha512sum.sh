#!/bin/sh
UTIL="sha512sum"
. "$(dirname "$0")/testlib.sh"

echo "hello world" > /tmp/test_sha512.txt
printf "\n[ Basic hashing ]\n"
run_test_file "hash file"  /tmp/test_sha512.txt
run_test "--tag BSD style" --tag /tmp/test_sha512.txt
/usr/bin/sha512sum /tmp/test_sha512.txt > /tmp/test_sha512.check
run_test_exit "-c check"   -c /tmp/test_sha512.check
rm -f /tmp/test_sha512.txt /tmp/test_sha512.check
print_summary
