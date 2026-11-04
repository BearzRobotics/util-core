#!/bin/sh
UTIL="md5sum"
. "$(dirname "$0")/testlib.sh"

echo "hello world" > /tmp/test_md5.txt
echo "foo bar baz" > /tmp/test_md5_2.txt

printf "\n[ Basic hashing ]\n"
run_test_file "hash file"            /tmp/test_md5.txt
run_test "hash multiple files"       /tmp/test_md5.txt /tmp/test_md5_2.txt
run_test_file "-b binary mode"       /tmp/test_md5.txt -b
run_test_file "-t text mode"         /tmp/test_md5.txt -t
run_test "--tag BSD style"           --tag /tmp/test_md5.txt

printf "\n[ Check mode ]\n"
/usr/bin/md5sum /tmp/test_md5.txt > /tmp/test_md5.check
run_test_exit "-c check file"        -c /tmp/test_md5.check

rm -f /tmp/test_md5.txt /tmp/test_md5_2.txt /tmp/test_md5.check
print_summary
