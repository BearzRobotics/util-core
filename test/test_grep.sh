#!/bin/sh
UTIL="grep"
. "$(dirname "$0")/testlib.sh"

printf "hello world\nfoo bar\nHELLO WORLD\ntest 123\n" > /tmp/test_grep.txt

printf "\n[ Basic matching ]\n"
run_test_file "simple pattern"       /tmp/test_grep.txt hello
run_test_file "no match"             /tmp/test_grep.txt xyz

printf "\n[ Flags ]\n"
run_test_file "-i case insensitive"  /tmp/test_grep.txt -i hello
run_test_file "-v invert match"      /tmp/test_grep.txt -v hello
run_test_file "-c count matches"     /tmp/test_grep.txt -c hello
run_test_file "-n line numbers"      /tmp/test_grep.txt -n hello
run_test_file "-l filename only"     /tmp/test_grep.txt -l hello
run_test_file "-w whole word"        /tmp/test_grep.txt -w hello
run_test_file "-x whole line"        /tmp/test_grep.txt -x "hello world"

printf "\n[ Regex types ]\n"
run_test_file "-E extended regex"    /tmp/test_grep.txt -E "hello|foo"
run_test_file "-F fixed string"      /tmp/test_grep.txt -F "hello"

rm -f /tmp/test_grep.txt
print_summary
