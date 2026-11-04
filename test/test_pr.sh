#!/bin/sh
UTIL="pr"
. "$(dirname "$0")/testlib.sh"

seq 1 30 > /tmp/test_pr.txt

printf "\n[ Basic formatting ]\n"
run_test_file "default output"       /tmp/test_pr.txt
run_test_file "-l 20 page length"    /tmp/test_pr.txt -l 20
run_test_file "-w 40 page width"     /tmp/test_pr.txt -w 40
run_test_file "-h custom header"     /tmp/test_pr.txt -h "My Header"
run_test_file "-n number lines"      /tmp/test_pr.txt -n
run_test_file "-2 two columns"       /tmp/test_pr.txt -2
run_test_file "-t no header/footer"  /tmp/test_pr.txt -t

rm -f /tmp/test_pr.txt
print_summary
