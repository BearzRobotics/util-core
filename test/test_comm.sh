#!/bin/sh
UTIL="comm"
. "$(dirname "$0")/testlib.sh"

printf "apple\nbanana\ncherry\n" > /tmp/test_comm1.txt
printf "banana\ncherry\ndate\n"  > /tmp/test_comm2.txt

printf "\n[ Basic usage ]\n"
run_test "default output"        /tmp/test_comm1.txt /tmp/test_comm2.txt
run_test "-1 suppress col1"      -1 /tmp/test_comm1.txt /tmp/test_comm2.txt
run_test "-2 suppress col2"      -2 /tmp/test_comm1.txt /tmp/test_comm2.txt
run_test "-3 suppress col3"      -3 /tmp/test_comm1.txt /tmp/test_comm2.txt
run_test "-12 only common"       -12 /tmp/test_comm1.txt /tmp/test_comm2.txt
run_test "-13 only in file2"     -13 /tmp/test_comm1.txt /tmp/test_comm2.txt
run_test "-23 only in file1"     -23 /tmp/test_comm1.txt /tmp/test_comm2.txt

printf "\n[ Edge cases ]\n"
run_test "identical files"       /tmp/test_comm1.txt /tmp/test_comm1.txt
run_test "empty vs file"         /dev/null /tmp/test_comm1.txt

rm -f /tmp/test_comm1.txt /tmp/test_comm2.txt
print_summary
