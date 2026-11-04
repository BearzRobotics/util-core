#!/bin/sh
UTIL="join"
. "$(dirname "$0")/testlib.sh"

printf "1 apple\n2 banana\n3 cherry\n" > /tmp/test_join1.txt
printf "1 red\n2 yellow\n4 orange\n"   > /tmp/test_join2.txt

printf "\n[ Basic join ]\n"
run_test "default join on field 1"   /tmp/test_join1.txt /tmp/test_join2.txt
run_test "-a 1 include unpaired 1"   -a 1 /tmp/test_join1.txt /tmp/test_join2.txt
run_test "-a 2 include unpaired 2"   -a 2 /tmp/test_join1.txt /tmp/test_join2.txt
run_test "-v 1 only unpaired 1"      -v 1 /tmp/test_join1.txt /tmp/test_join2.txt

printf "\n[ Field selection ]\n"
run_test "-t delimiter"              -t: /tmp/test_join1.txt /tmp/test_join2.txt

rm -f /tmp/test_join1.txt /tmp/test_join2.txt
print_summary
