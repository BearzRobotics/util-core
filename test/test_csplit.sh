#!/bin/sh
UTIL="csplit"
. "$(dirname "$0")/testlib.sh"

printf "section1\n--\nsection2\n--\nsection3\n" > /tmp/test_csplit.txt

printf "\n[ Basic splitting ]\n"
cd /tmp
run_test_exit "split on pattern"     /tmp/test_csplit.txt '/--/'
run_test_exit "split with prefix -f" /tmp/test_csplit.txt '/--/' -f csplit_test_
run_test_exit "split keep delim -k"  /tmp/test_csplit.txt '/--/' -k
run_test_exit "repeat pattern {*}"   /tmp/test_csplit.txt '/--/' '{*}'

rm -f /tmp/test_csplit.txt /tmp/xx* /tmp/csplit_test*
print_summary
