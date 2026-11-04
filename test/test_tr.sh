#!/bin/sh
UTIL="tr"
. "$(dirname "$0")/testlib.sh"

printf "\n[ Basic translation ]\n"
run_test "uppercase"                 'a-z' 'A-Z' <<< "hello world"
run_test "lowercase"                 'A-Z' 'a-z' <<< "HELLO WORLD"
run_test "digits to x"               '0-9' 'x'   <<< "abc123def"

printf "\n[ Delete mode ]\n"
run_test "-d delete chars"           -d 'aeiou'   <<< "hello world"
run_test "-d delete digits"          -d '0-9'     <<< "abc123def"

printf "\n[ Squeeze mode ]\n"
run_test "-s squeeze spaces"         -s ' '       <<< "hello   world"
run_test "-s squeeze chars"          -s 'a-z'     <<< "aaabbbccc"

printf "\n[ Complement ]\n"
run_test "-c complement"             -c 'a-z' 'x' <<< "hello 123 world"
run_test "-cd keep only"             -cd 'a-z'    <<< "hello 123 world"

print_summary
