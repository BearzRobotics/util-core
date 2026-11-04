#!/bin/sh
UTIL="uniq"
. "$(dirname "$0")/testlib.sh"

printf "apple\napple\nbanana\nbanana\nbanana\ncherry\n" > /tmp/test_uniq.txt

printf "\n[ Basic deduplication ]\n"
run_test_file "default uniq"             /tmp/test_uniq.txt
run_test_file "-c count occurrences"     /tmp/test_uniq.txt -c
run_test_file "-d only duplicates"       /tmp/test_uniq.txt -d
run_test_file "-u only unique"           /tmp/test_uniq.txt -u
run_test_file "-i case insensitive"      /tmp/test_uniq.txt -i

printf "\n[ Field skipping ]\n"
printf "1 apple\n1 apple\n2 banana\n" > /tmp/test_uniq2.txt
run_test_file "-f 1 skip field"          /tmp/test_uniq2.txt -f 1
run_test_file "-s 2 skip chars"          /tmp/test_uniq2.txt -s 2

rm -f /tmp/test_uniq.txt /tmp/test_uniq2.txt
print_summary
