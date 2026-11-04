#!/bin/sh
UTIL="dd"
. "$(dirname "$0")/testlib.sh"

echo "hello world test data" > /tmp/test_dd_in.txt

printf "\n[ Basic usage ]\n"
run_test_exit "if= of= basic copy"   if=/tmp/test_dd_in.txt of=/tmp/test_dd_out.txt
run_test_exit "bs= block size"       if=/tmp/test_dd_in.txt of=/tmp/test_dd_out2.txt bs=1
run_test_exit "count= limit blocks"  if=/tmp/test_dd_in.txt of=/tmp/test_dd_out3.txt bs=1 count=5

printf "\n[ Conversions ]\n"
run_test_exit "conv=ucase uppercase" if=/tmp/test_dd_in.txt of=/tmp/test_dd_out4.txt conv=ucase
run_test_exit "conv=lcase lowercase" if=/tmp/test_dd_in.txt of=/tmp/test_dd_out5.txt conv=lcase

rm -f /tmp/test_dd_in.txt /tmp/test_dd_out*.txt
print_summary
