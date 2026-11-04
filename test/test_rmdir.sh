#!/bin/sh
UTIL="rmdir"
. "$(dirname "$0")/testlib.sh"

printf "\n[ Basic removal ]\n"
mkdir /tmp/test_rmdir_1
run_test_exit "remove empty dir"         /tmp/test_rmdir_1

mkdir -p /tmp/test_rmdir_p/a/b/c
run_test_exit "-p remove parents"        -p /tmp/test_rmdir_p/a/b/c

mkdir /tmp/test_rmdir_v
run_test_exit "--verbose"                --verbose /tmp/test_rmdir_v

rm -rf /tmp/test_rmdir_1 /tmp/test_rmdir_p /tmp/test_rmdir_v
print_summary
