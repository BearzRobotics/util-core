#!/bin/sh
UTIL="mktemp"
. "$(dirname "$0")/testlib.sh"

printf "\n[ Basic usage ]\n"
run_test_exit "create temp file"
run_test_exit "-d create temp dir"          -d
run_test_exit "-u dry run"                  -u
run_test_exit "--suffix add suffix"         --suffix=.txt
run_test_exit "-p use dir"                  -p /tmp
run_test_exit "custom template"             /tmp/mytemp.XXXXXX

print_summary
