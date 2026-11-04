#!/bin/sh
UTIL="cut"
. "$(dirname "$0")/testlib.sh"

printf "one:two:three\nfoo:bar:baz\n" > /tmp/test_cut.txt
printf "abcdefgh\nijklmnop\n"         > /tmp/test_cut2.txt

printf "\n[ By fields ]\n"
run_test_file "-f1 first field"          /tmp/test_cut.txt  -d: -f1
run_test_file "-f2 second field"         /tmp/test_cut.txt  -d: -f2
run_test_file "-f1,3 fields 1 and 3"     /tmp/test_cut.txt  -d: -f1,3
run_test_file "-f2- from field 2"        /tmp/test_cut.txt  -d: -f2-
run_test_file "-f-2 up to field 2"       /tmp/test_cut.txt  -d: -f-2

printf "\n[ By characters ]\n"
run_test_file "-c1 first char"           /tmp/test_cut2.txt -c1
run_test_file "-c1-3 chars 1 to 3"       /tmp/test_cut2.txt -c1-3
run_test_file "-c2,4,6 specific chars"   /tmp/test_cut2.txt -c2,4,6

printf "\n[ By bytes ]\n"
run_test_file "-b1-4 bytes 1 to 4"       /tmp/test_cut2.txt -b1-4

printf "\n[ Flags ]\n"
run_test_file "--complement -f1"         /tmp/test_cut.txt  -d: --complement -f1

rm -f /tmp/test_cut.txt /tmp/test_cut2.txt
print_summary
