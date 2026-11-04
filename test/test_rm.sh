#!/bin/sh
UTIL="rm"
. "$(dirname "$0")/testlib.sh"

printf "\n[ Basic removal ]\n"
touch /tmp/test_rm_1.txt
run_test_exit "remove file"          /tmp/test_rm_1.txt

touch /tmp/test_rm_2.txt /tmp/test_rm_3.txt
run_test_exit "remove multiple"      /tmp/test_rm_2.txt /tmp/test_rm_3.txt

mkdir -p /tmp/test_rm_dir/sub
touch /tmp/test_rm_dir/sub/file.txt
run_test_exit "-r recursive"         -r /tmp/test_rm_dir

touch /tmp/test_rm_f.txt
run_test_exit "-f force"             -f /tmp/test_rm_f.txt
run_test_exit "-f no error missing"  -f /tmp/test_rm_nonexistent.txt

rm -rf /tmp/test_rm_*.txt /tmp/test_rm_dir
print_summary
