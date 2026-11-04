#!/bin/sh
UTIL="cksum"
. "$(dirname "$0")/testlib.sh"

echo "hello world" > /tmp/test_cksum.txt
echo "foo bar"     > /tmp/test_cksum2.txt

printf "\n[ Basic checksums ]\n"
run_test_file "crc32 default"        /tmp/test_cksum.txt
run_test "multiple files"            /tmp/test_cksum.txt /tmp/test_cksum2.txt
run_test_file "empty file"           /dev/null

printf "\n[ Algorithm flags ]\n"
run_test_file "-a md5"               /tmp/test_cksum.txt -a md5
run_test_file "-a sha256"            /tmp/test_cksum.txt -a sha256
run_test_file "-a sha1"              /tmp/test_cksum.txt -a sha1

printf "\n[ Output flags ]\n"
run_test_file "--untagged"           /tmp/test_cksum.txt --untagged
run_test_file "--tag"                /tmp/test_cksum.txt --tag

rm -f /tmp/test_cksum.txt /tmp/test_cksum2.txt
print_summary
