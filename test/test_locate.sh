#!/bin/sh
UTIL="locate"
. "$(dirname "$0")/testlib.sh"

printf "\n[ Basic search ]\n"
run_test "find bash"                 bash
run_test "-i case insensitive"       -i BASH
run_test "-c count only"             -c bash
run_test "-l limit results"          -l 5 bash
run_test "-b basename only"          -b bash

print_summary
