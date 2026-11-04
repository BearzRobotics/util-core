#!/bin/sh
UTIL="test"
. "$(dirname "$0")/testlib.sh"

touch /tmp/test_test_file.txt
mkdir /tmp/test_test_dir

printf "\n[ File tests ]\n"
run_test_exit "-e file exists"       -e /tmp/test_test_file.txt
run_test_exit "-f is regular file"   -f /tmp/test_test_file.txt
run_test_exit "-d is directory"      -d /tmp/test_test_dir
run_test_exit "-r is readable"       -r /tmp/test_test_file.txt
run_test_exit "-w is writable"       -w /tmp/test_test_file.txt
run_test_exit "-s file not empty"    -s /tmp/test_test_file.txt

printf "\n[ String tests ]\n"
run_test_exit "-z empty string"      -z ""
run_test_exit "-n non-empty string"  -n "hello"
run_test_exit "string equality"      "hello" = "hello"
run_test_exit "string inequality"    "hello" != "world"

printf "\n[ Integer tests ]\n"
run_test_exit "-eq equal"            1 -eq 1
run_test_exit "-ne not equal"        1 -ne 2
run_test_exit "-lt less than"        1 -lt 2
run_test_exit "-gt greater than"     2 -gt 1
run_test_exit "-le less or equal"    1 -le 1
run_test_exit "-ge greater or equal" 2 -ge 2

printf "\n[ Logic ]\n"
run_test_exit "-a and"               -f /tmp/test_test_file.txt -a -d /tmp/test_test_dir
run_test_exit "-o or"                -f /tmp/test_test_file.txt -o -f /tmp/nonexistent
run_test_exit "! not"                ! -f /tmp/nonexistent

rm -f /tmp/test_test_file.txt
rm -rf /tmp/test_test_dir
print_summary
