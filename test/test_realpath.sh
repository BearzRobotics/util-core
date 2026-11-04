#!/bin/sh
UTIL="realpath"
. "$(dirname "$0")/testlib.sh"

mkdir -p /tmp/test_realpath_d
touch /tmp/test_realpath_d/file.txt

printf "\n[ Basic usage ]\n"
run_test "resolve path"              /tmp/test_realpath_d/file.txt
run_test "resolve dir"               /tmp/test_realpath_d
run_test "-m missing ok"             -m /tmp/test_realpath_d/missing.txt
run_test "-s no symlink resolution"  -s /tmp/test_realpath_d/file.txt
run_test "--relative-to"             --relative-to=/tmp /tmp/test_realpath_d/file.txt

rm -rf /tmp/test_realpath_d
print_summary
