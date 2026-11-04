#!/bin/sh
UTIL="tail"
. "$(dirname "$0")/testlib.sh"

seq 1 20 > /tmp/test_tail.txt

printf "\n[ Line count ]\n"
run_test_file "default 10 lines"     /tmp/test_tail.txt
run_test_file "-n 5 lines"           /tmp/test_tail.txt -n 5
run_test_file "-n +5 from line 5"    /tmp/test_tail.txt -n +5

printf "\n[ Byte count ]\n"
run_test_file "-c 10 bytes"          /tmp/test_tail.txt -c 10
run_test_file "-c +10 from byte 10"  /tmp/test_tail.txt -c +10

printf "\n[ Multiple files ]\n"
run_test "multiple files"            /tmp/test_tail.txt /tmp/test_tail.txt

rm -f /tmp/test_tail.txt
print_summary
