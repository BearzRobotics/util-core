#!/bin/sh
UTIL="base32"
. "$(dirname "$0")/testlib.sh"

echo "hello world" > /tmp/test_base32.txt

printf "\n[ Encoding ]\n"
run_test_file "encode file"      /tmp/test_base32.txt
run_test "encode stdin"          <<< "hello"
run_test "-w 0 no wrap"         -w 0 /tmp/test_base32.txt
run_test "-w 16 wrap at 16"     -w 16 /tmp/test_base32.txt

printf "\n[ Decoding ]\n"
encoded=$(printf "hello world\n" | /usr/bin/base32)
run_test "-d decode" -d <<< "$encoded"

rm -f /tmp/test_base32.txt
print_summary
