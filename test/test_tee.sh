#!/bin/sh
UTIL="tee"
. "$(dirname "$0")/testlib.sh"

printf "\n[ Basic usage ]\n"
echo "hello world" | run_test_exit "tee to file"       /tmp/test_tee_out.txt
echo "hello world" | run_test_exit "-a append"         -a /tmp/test_tee_out.txt
echo "hello world" | run_test_exit "tee two files"     /tmp/test_tee_1.txt /tmp/test_tee_2.txt

rm -f /tmp/test_tee_out.txt /tmp/test_tee_1.txt /tmp/test_tee_2.txt
print_summary
