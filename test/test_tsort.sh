#!/bin/sh
UTIL="tsort"
. "$(dirname "$0")/testlib.sh"

printf "a b\nb c\na c\n" > /tmp/test_tsort.txt

printf "\n[ Basic topological sort ]\n"
run_test_file "basic tsort"          /tmp/test_tsort.txt

printf "a b\nb a\n" > /tmp/test_tsort_cycle.txt
run_test_exit "cycle detection"      /tmp/test_tsort_cycle.txt

rm -f /tmp/test_tsort.txt /tmp/test_tsort_cycle.txt
print_summary
