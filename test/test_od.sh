#!/bin/sh
UTIL="od"
. "$(dirname "$0")/testlib.sh"

printf "hello\x00\xff\n" > /tmp/test_od.txt

printf "\n[ Output formats ]\n"
run_test_file "default octal"        /tmp/test_od.txt
run_test_file "-c char format"       /tmp/test_od.txt -c
run_test_file "-x hex format"        /tmp/test_od.txt -x
run_test_file "-d decimal"           /tmp/test_od.txt -d
run_test_file "-b octal bytes"       /tmp/test_od.txt -b
run_test_file "-An no address"       /tmp/test_od.txt -An
run_test_file "-Ax hex address"      /tmp/test_od.txt -Ax
run_test_file "-t x1 hex bytes"      /tmp/test_od.txt -t x1
run_test_file "-t a named chars"     /tmp/test_od.txt -t a

rm -f /tmp/test_od.txt
print_summary
