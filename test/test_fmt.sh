#!/bin/sh
UTIL="fmt"
. "$(dirname "$0")/testlib.sh"

printf "This is a very long line that should be wrapped at some point because it exceeds the default width of seventy characters\n" > /tmp/test_fmt.txt
printf "short\nlines\nhere\n" > /tmp/test_fmt2.txt

printf "\n[ Basic formatting ]\n"
run_test_file "default wrap"         /tmp/test_fmt.txt
run_test_file "-w 40 width"          /tmp/test_fmt.txt -w 40
run_test_file "-w 100 wide"          /tmp/test_fmt.txt -w 100
run_test_file "-u uniform spacing"   /tmp/test_fmt.txt -u

rm -f /tmp/test_fmt.txt /tmp/test_fmt2.txt
print_summary
