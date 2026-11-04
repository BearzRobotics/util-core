#!/bin/sh
UTIL="cp"
. "$(dirname "$0")/testlib.sh"

echo "hello" > /tmp/test_cp_src.txt
mkdir -p /tmp/test_cp_dir

printf "\n[ Basic copy ]\n"
gnu /tmp/test_cp_src.txt /tmp/test_cp_gnu_dst.txt
ours /tmp/test_cp_src.txt /tmp/test_cp_ours_dst.txt
run_test "content matches after copy" \
    && diff /tmp/test_cp_gnu_dst.txt /tmp/test_cp_ours_dst.txt > /dev/null 2>&1 \
    && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

printf "\n[ Flags ]\n"
run_test_exit "-r recursive copy"    -r /tmp/test_cp_dir /tmp/test_cp_dir2
run_test_exit "-p preserve attrs"    -p /tmp/test_cp_src.txt /tmp/test_cp_p.txt
run_test_exit "-n no clobber"        -n /tmp/test_cp_src.txt /tmp/test_cp_ours_dst.txt
run_test_exit "-f force"             -f /tmp/test_cp_src.txt /tmp/test_cp_ours_dst.txt

rm -rf /tmp/test_cp_src.txt /tmp/test_cp_gnu_dst.txt /tmp/test_cp_ours_dst.txt \
       /tmp/test_cp_p.txt /tmp/test_cp_dir /tmp/test_cp_dir2
print_summary
