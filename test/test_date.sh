#!/bin/sh
UTIL="date"
. "$(dirname "$0")/testlib.sh"

printf "\n[ Format strings ]\n"
run_test "+%Y year"                 "+%Y"
run_test "+%m month"                "+%m"
run_test "+%d day"                  "+%d"
run_test "+%H hour"                 "+%H"
run_test "+%Y-%m-%d date"           "+%Y-%m-%d"
run_test "+%s unix timestamp"       "+%s"

printf "\n[ -d date string ]\n"
run_test "-d parse date"            -d "2000-01-01" "+%Y-%m-%d"
run_test "-d parse with time"       -d "2000-01-01 12:00:00" "+%Y-%m-%d %H:%M:%S"

printf "\n[ -u UTC ]\n"
run_test "-u UTC output"            -u "+%Z"

print_summary
