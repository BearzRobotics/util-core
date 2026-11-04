#!/bin/sh
UTIL="xargs"
. "$(dirname "$0")/testlib.sh"

printf "a\nb\nc\nd\ne\n" > /tmp/test_xargs.txt

printf "\n[ Basic usage ]\n"
run_test "basic echo"                    echo   < /tmp/test_xargs.txt
run_test "-n 2 items per command"    -n 2 echo   < /tmp/test_xargs.txt
run_test "-L 1 line per command"     -L 1 echo   < /tmp/test_xargs.txt
run_test "-d newline delimiter"      -d'\n' echo < /tmp/test_xargs.txt
run_test "-I replace str"            -I{} echo "item: {}" < /tmp/test_xargs.txt

printf "\n[ Flags ]\n"
run_test_exit "-r no run if empty"   -r echo <<< ""
run_test_exit "-P parallel"          -P 2 -n 1 echo < /tmp/test_xargs.txt

rm -f /tmp/test_xargs.txt
print_summary
