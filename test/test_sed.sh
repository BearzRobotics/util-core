#!/bin/sh
UTIL="sed"
. "$(dirname "$0")/testlib.sh"

printf "hello world\nfoo bar\nhello again\n" > /tmp/test_sed.txt

printf "\n[ Substitution ]\n"
run_test_file "basic substitute"         /tmp/test_sed.txt -e 's/hello/bye/'
run_test_file "global substitute"        /tmp/test_sed.txt -e 's/l/L/g'
run_test_file "case insensitive"         /tmp/test_sed.txt -e 's/HELLO/bye/I'

printf "\n[ Line operations ]\n"
run_test_file "delete line"              /tmp/test_sed.txt -e '/hello/d'
run_test_file "print matching"           /tmp/test_sed.txt -n -e '/hello/p'
run_test_file "quit after line"          /tmp/test_sed.txt -e '2q'

printf "\n[ Address ranges ]\n"
run_test_file "line range"               /tmp/test_sed.txt -e '1,2s/o/0/g'
run_test_file "pattern range"            /tmp/test_sed.txt -e '/hello/,/foo/d'

rm -f /tmp/test_sed.txt
print_summary
