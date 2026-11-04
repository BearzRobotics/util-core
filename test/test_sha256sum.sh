#!/bin/sh
UTIL="sha256sum"
. "$(dirname "$0")/testlib.sh"

echo "hello world" > /tmp/test_sha256.txt
printf "\n[ Basic hashing ]\n"
run_test_file "hash file"  /tmp/test_sha256.txt
run_test "--tag BSD style" --tag /tmp/test_sha256.txt
/usr/bin/sha256sum /tmp/test_sha256.txt > /tmp/test_sha256.check
run_test_exit "-c check"   -c /tmp/test_sha256.check
rm -f /tmp/test_sha256.txt /tmp/test_sha256.check
print_summary
