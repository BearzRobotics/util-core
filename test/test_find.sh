#!/bin/sh
UTIL="find"
. "$(dirname "$0")/testlib.sh"

mkdir -p /tmp/test_find_d/sub
touch /tmp/test_find_d/file1.txt
touch /tmp/test_find_d/file2.sh
touch /tmp/test_find_d/sub/file3.txt

printf "\n[ Basic search ]\n"
run_test "find all"                  /tmp/test_find_d
run_test "-name pattern"             /tmp/test_find_d -name "*.txt"
run_test "-type f files only"        /tmp/test_find_d -type f
run_test "-type d dirs only"         /tmp/test_find_d -type d
run_test "-maxdepth 1"               /tmp/test_find_d -maxdepth 1
run_test "-mindepth 1"               /tmp/test_find_d -mindepth 1

printf "\n[ Filtering ]\n"
run_test "-not -name"                /tmp/test_find_d -not -name "*.txt"
run_test "-name and -type"           /tmp/test_find_d -name "*.txt" -type f

rm -rf /tmp/test_find_d
print_summary
