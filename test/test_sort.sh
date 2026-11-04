#!/bin/sh
UTIL="sort"
. "$(dirname "$0")/testlib.sh"

printf "banana\napple\ncherry\ndate\n"   > /tmp/test_sort.txt
printf "10\n9\n100\n2\n20\n"            > /tmp/test_sort_n.txt
printf "b 2\na 10\nc 1\n"               > /tmp/test_sort_f.txt

printf "\n[ Basic sorting ]\n"
run_test_file "default alpha"            /tmp/test_sort.txt
run_test_file "-r reverse"               /tmp/test_sort.txt -r
run_test_file "-n numeric"               /tmp/test_sort_n.txt -n
run_test_file "-h human numeric"         /tmp/test_sort_n.txt -h
run_test_file "-u unique"                /tmp/test_sort.txt -u
run_test_file "-f ignore case"           /tmp/test_sort.txt -f

printf "\n[ Field sorting ]\n"
run_test_file "-k2 sort by field 2"      /tmp/test_sort_f.txt -k2
run_test_file "-k2n numeric field 2"     /tmp/test_sort_f.txt -k2n
run_test_file "-t: field delimiter"      /tmp/test_sort_f.txt -t' ' -k2n

printf "\n[ Stability ]\n"
run_test_file "-s stable sort"           /tmp/test_sort.txt -s

rm -f /tmp/test_sort.txt /tmp/test_sort_n.txt /tmp/test_sort_f.txt
print_summary
