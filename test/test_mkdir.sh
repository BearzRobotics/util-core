#!/bin/sh
UTIL="mkdir"
. "$(dirname "$0")/testlib.sh"

printf "\n[ Basic creation ]\n"
run_test_exit "create dir"           /tmp/test_mkdir_new
run_test_exit "-p create parents"    -p /tmp/test_mkdir_p/a/b/c
run_test_exit "-m set mode"          -m 755 /tmp/test_mkdir_m
run_test_exit "-p existing no error" -p /tmp/test_mkdir_p

rm -rf /tmp/test_mkdir_new /tmp/test_mkdir_p /tmp/test_mkdir_m
print_summary
