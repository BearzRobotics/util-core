#!/bin/sh
UTIL="head"
. "$(dirname "$0")/testlib.sh"

seq 1 20 > /tmp/test_head.txt

printf "\n[ Line count ]\n"
run_test_file "default 10 lines"     /tmp/test_head.txt
run_test_file "-n 5 lines"           /tmp/test_head.txt -n 5
run_test_file "-n 1 line"            /tmp/test_head.txt -n 1
run_test_file "-n -5 all but last 5" /tmp/test_head.txt -n -5

printf "\n[ Byte count ]\n"
run_test_file "-c 10 bytes"          /tmp/test_head.txt -c 10
run_test_file "-c -10 all but 10"    /tmp/test_head.txt -c -10

printf "\n[ Multiple files ]\n"
run_test "multiple files with header" /tmp/test_head.txt /tmp/test_head.txt

rm -f /tmp/test_head.txt
print_summary
