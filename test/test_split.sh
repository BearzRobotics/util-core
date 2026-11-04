#!/bin/sh
UTIL="split"
. "$(dirname "$0")/testlib.sh"

seq 1 100 > /tmp/test_split.txt

printf "\n[ Basic splitting ]\n"
run_test_exit "default 1000 lines"       /tmp/test_split.txt /tmp/test_split_out_
run_test_exit "-l 10 lines per file"     -l 10 /tmp/test_split.txt /tmp/test_split_l_
run_test_exit "-b 100 bytes per file"    -b 100 /tmp/test_split.txt /tmp/test_split_b_
run_test_exit "-n 3 chunks"              -n 3 /tmp/test_split.txt /tmp/test_split_n_
run_test_exit "-d numeric suffixes"      -d -l 10 /tmp/test_split.txt /tmp/test_split_d_
run_test_exit "-a 3 suffix length"       -a 3 -l 10 /tmp/test_split.txt /tmp/test_split_a_

rm -f /tmp/test_split.txt /tmp/test_split_*
print_summary
