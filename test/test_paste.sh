#!/bin/sh
UTIL="paste"
. "$(dirname "$0")/testlib.sh"

printf "a\nb\nc\n" > /tmp/test_paste1.txt
printf "1\n2\n3\n" > /tmp/test_paste2.txt

printf "\n[ Basic pasting ]\n"
run_test "paste two files"           /tmp/test_paste1.txt /tmp/test_paste2.txt
run_test "-d comma delimiter"        -d, /tmp/test_paste1.txt /tmp/test_paste2.txt
run_test "-s serial"                 -s /tmp/test_paste1.txt
run_test "-d tab delimiter"          -d'\t' /tmp/test_paste1.txt /tmp/test_paste2.txt

rm -f /tmp/test_paste1.txt /tmp/test_paste2.txt
print_summary
