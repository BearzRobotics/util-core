#!/bin/sh
UTIL="tree"
. "$(dirname "$0")/testlib.sh"

mkdir -p /tmp/test_tree_d/sub1/subsub
mkdir -p /tmp/test_tree_d/sub2
touch /tmp/test_tree_d/file1.txt
touch /tmp/test_tree_d/sub1/file2.txt

printf "\n[ Basic usage ]\n"
run_test "default tree"              /tmp/test_tree_d
run_test "-a show hidden"            -a /tmp/test_tree_d
run_test "-d dirs only"              -d /tmp/test_tree_d
run_test "-L 1 max depth"            -L 1 /tmp/test_tree_d
run_test "-f full path"              -f /tmp/test_tree_d
run_test "--noreport no summary"     --noreport /tmp/test_tree_d

rm -rf /tmp/test_tree_d
print_summary
