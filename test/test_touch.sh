#!/bin/sh
UTIL="touch"
. "$(dirname "$0")/testlib.sh"

printf "\n[ Basic usage ]\n"
run_test_exit "create new file"          /tmp/test_touch_new.txt
run_test_exit "touch existing"           /tmp/test_touch_new.txt
run_test_exit "-c no create"             -c /tmp/test_touch_nocreate.txt
run_test_exit "-t set timestamp"         -t 202001010000 /tmp/test_touch_new.txt
run_test_exit "-d date string"           -d "2020-01-01" /tmp/test_touch_new.txt
run_test_exit "-a access time only"      -a /tmp/test_touch_new.txt
run_test_exit "-m modify time only"      -m /tmp/test_touch_new.txt

rm -f /tmp/test_touch_new.txt /tmp/test_touch_nocreate.txt
print_summary
