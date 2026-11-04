#!/bin/sh
UTIL="base64"
. "$(dirname "$0")/testlib.sh"

echo "hello world" > /tmp/test_base64.txt
printf "binary: \x00\x01\x02\xff" > /tmp/test_base64_bin.txt

printf "\n[ Encoding ]\n"
run_test_file "encode text file"    /tmp/test_base64.txt
run_test_file "encode binary file"  /tmp/test_base64_bin.txt
run_test "-w 0 no line wrap"       -w 0 /tmp/test_base64.txt
run_test "-w 16 wrap at 16"        -w 16 /tmp/test_base64.txt

printf "\n[ Decoding ]\n"
encoded=$(printf "hello world\n" | /usr/bin/base64)
run_test "-d decode" -d <<< "$encoded"

rm -f /tmp/test_base64.txt /tmp/test_base64_bin.txt
print_summary
