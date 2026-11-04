#!/bin/sh
UTIL="vdir"
. "$(dirname "$0")/testlib.sh"

mkdir -p /tmp/test_vdir_d
touch /tmp/test_vdir_d/file1.txt /tmp/test_vdir_d/file2.sh

printf "\n[ Basic listing ]\n"
run_test "default verbose list"      /tmp/test_vdir_d
run_test "-a show hidden"            -a /tmp/test_vdir_d
run_test "-r reverse"                -r /tmp/test_vdir_d
run_test "--color=never"             --color=never /tmp/test_vdir_d

rm -rf /tmp/test_vdir_d
print_summary
