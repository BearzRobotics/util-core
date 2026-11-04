#!/bin/sh
UTIL="nl"
. "$(dirname "$0")/testlib.sh"

printf "line one\nline two\n\nline four\n" > /tmp/test_nl.txt

printf "\n[ Basic numbering ]\n"
run_test_file "default numbering"        /tmp/test_nl.txt
run_test_file "-b a number all lines"    /tmp/test_nl.txt -b a
run_test_file "-b n number no lines"     /tmp/test_nl.txt -b n
run_test_file "-n ln left aligned"       /tmp/test_nl.txt -n ln
run_test_file "-n rn right no zeros"     /tmp/test_nl.txt -n rn
run_test_file "-n rz right with zeros"   /tmp/test_nl.txt -n rz
run_test_file "-w 4 width"               /tmp/test_nl.txt -w 4
run_test_file "-v 10 start at 10"        /tmp/test_nl.txt -v 10
run_test_file "-i 2 increment by 2"      /tmp/test_nl.txt -i 2

rm -f /tmp/test_nl.txt
print_summary
