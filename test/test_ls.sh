#!/bin/sh
UTIL="ls"
. "$(dirname "$0")/testlib.sh"

mkdir -p /tmp/test_ls_d
touch /tmp/test_ls_d/file1.txt /tmp/test_ls_d/file2.sh
mkdir /tmp/test_ls_d/subdir

printf "\n[ Basic listing ]\n"
run_test "list directory"            /tmp/test_ls_d
run_test "-a show hidden"            -a /tmp/test_ls_d
run_test "-l long format"            -l /tmp/test_ls_d
run_test "-1 one per line"           -1 /tmp/test_ls_d
run_test "-r reverse"                -r /tmp/test_ls_d
run_test "-R recursive"              -R /tmp/test_ls_d
run_test "-S sort by size"           -S /tmp/test_ls_d
run_test "-t sort by time"           -t /tmp/test_ls_d
run_test "--color=never"             --color=never /tmp/test_ls_d
run_test "-d list dir itself"        -d /tmp/test_ls_d
run_test "-F classify"               -F /tmp/test_ls_d
run_test "-h human readable"         -lh /tmp/test_ls_d

rm -rf /tmp/test_ls_d
print_summary
