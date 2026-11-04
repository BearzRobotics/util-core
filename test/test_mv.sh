#!/bin/sh
UTIL="mv"
. "$(dirname "$0")/testlib.sh"

echo "hello" > /tmp/test_mv_src.txt

printf "\n[ Basic move ]\n"
run_test_exit "move file"            /tmp/test_mv_src.txt /tmp/test_mv_dst.txt
run_test_exit "-f force"             -f /tmp/test_mv_dst.txt /tmp/test_mv_dst2.txt
run_test_exit "-n no clobber"        -n /tmp/test_mv_dst2.txt /tmp/test_mv_dst3.txt

rm -f /tmp/test_mv_src.txt /tmp/test_mv_dst*.txt
print_summary
