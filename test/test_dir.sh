#!/bin/sh
UTIL="dir"
. "$(dirname "$0")/testlib.sh"

mkdir -p /tmp/test_dir_d
touch /tmp/test_dir_d/file1.txt /tmp/test_dir_d/file2.sh

printf "\n[ Basic listing ]\n"
run_test "list directory"            /tmp/test_dir_d
run_test "-l long format"            -l /tmp/test_dir_d
run_test "-a show hidden"            -a /tmp/test_dir_d
run_test "-1 one per line"           -1 /tmp/test_dir_d
run_test "-r reverse order"          -r /tmp/test_dir_d
run_test "-S sort by size"           -S /tmp/test_dir_d
run_test "--color=never no color"    --color=never /tmp/test_dir_d

rm -rf /tmp/test_dir_d
print_summary
