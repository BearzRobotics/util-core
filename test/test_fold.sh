#!/bin/sh
UTIL="fold"
. "$(dirname "$0")/testlib.sh"

printf "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789\n" > /tmp/test_fold.txt
printf "hello world this is a test of folding long lines\n" > /tmp/test_fold2.txt

printf "\n[ Basic folding ]\n"
run_test_file "default 80 cols"      /tmp/test_fold.txt
run_test_file "-w 20 width"          /tmp/test_fold.txt -w 20
run_test_file "-w 40 width"          /tmp/test_fold.txt -w 40
run_test_file "-s break on spaces"   /tmp/test_fold2.txt -s -w 20
run_test_file "-b byte mode"         /tmp/test_fold.txt -b -w 20

rm -f /tmp/test_fold.txt /tmp/test_fold2.txt
print_summary
