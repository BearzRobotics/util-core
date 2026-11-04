#!/bin/sh
UTIL="truncate"
. "$(dirname "$0")/testlib.sh"

echo "hello world" > /tmp/test_truncate.txt

printf "\n[ Basic usage ]\n"
run_test_exit "-s set size"          -s 5 /tmp/test_truncate.txt
run_test_exit "-s 0 empty file"      -s 0 /tmp/test_truncate.txt
run_test_exit "-s +10 extend"        -s +10 /tmp/test_truncate.txt
run_test_exit "-s -5 shrink"         -s -5 /tmp/test_truncate.txt
run_test_exit "-c no create"         -c -s 10 /tmp/test_truncate_new.txt

rm -f /tmp/test_truncate.txt /tmp/test_truncate_new.txt
print_summary
