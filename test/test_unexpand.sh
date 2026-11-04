#!/bin/sh
UTIL="unexpand"
. "$(dirname "$0")/testlib.sh"

printf "        leading spaces\n"          > /tmp/test_unexpand.txt
printf "no leading spaces here\n"         >> /tmp/test_unexpand.txt
printf "    four spaces here\n"           >> /tmp/test_unexpand.txt

printf "\n[ Basic usage ]\n"
run_test_file "default unexpand"         /tmp/test_unexpand.txt
run_test_file "-a all spaces"            /tmp/test_unexpand.txt -a
run_test_file "-t 4 tab stop"            /tmp/test_unexpand.txt -t 4

rm -f /tmp/test_unexpand.txt
print_summary
