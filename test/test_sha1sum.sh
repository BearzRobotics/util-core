#!/bin/sh
UTIL="sha1sum"
. "$(dirname "$0")/testlib.sh"

echo "hello world" > /tmp/test_sha1.txt

printf "\n[ Basic hashing ]\n"
run_test_file "hash file"            /tmp/test_sha1.txt
run_test "--tag BSD style"           --tag /tmp/test_sha1.txt
run_test_file "-b binary"            /tmp/test_sha1.txt -b

printf "\n[ Check mode ]\n"
/usr/bin/sha1sum /tmp/test_sha1.txt > /tmp/test_sha1.check
run_test_exit "-c check"             -c /tmp/test_sha1.check

rm -f /tmp/test_sha1.txt /tmp/test_sha1.check
print_summary
