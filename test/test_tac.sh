#!/bin/sh
UTIL="tac"
. "$(dirname "$0")/testlib.sh"

printf "line1\nline2\nline3\n" > /tmp/test_tac.txt

printf "\n[ Basic reversal ]\n"
run_test_file "reverse file"         /tmp/test_tac.txt
run_test "reverse multiple files"    /tmp/test_tac.txt /tmp/test_tac.txt
run_test_file "-s separator"         /tmp/test_tac.txt -s "line"
run_test_file "-r regex separator"   /tmp/test_tac.txt -r -s "[0-9]"

rm -f /tmp/test_tac.txt
print_summary
