#!/bin/sh
UTIL="updatedb"
. "$(dirname "$0")/testlib.sh"

printf "\n[ Basic usage ]\n"
# updatedb typically requires root but we can test exit behavior
run_test_exit "--help"                   --help
run_test_exit "-U limit path"            -U /tmp
run_test_exit "-o output file"           -o /tmp/test_updatedb.db -U /tmp

rm -f /tmp/test_updatedb.db
print_summary
