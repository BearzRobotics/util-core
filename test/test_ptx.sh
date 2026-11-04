#!/bin/sh
UTIL="ptx"
. "$(dirname "$0")/testlib.sh"

printf "hello world foo\nbar baz qux\n" > /tmp/test_ptx.txt

printf "\n[ Basic usage ]\n"
run_test_file "default output"       /tmp/test_ptx.txt
run_test_file "-r right rotation"    /tmp/test_ptx.txt -r
run_test_file "-w 60 width"          /tmp/test_ptx.txt -w 60
run_test_file "-f fold case"         /tmp/test_ptx.txt -f

rm -f /tmp/test_ptx.txt
print_summary
