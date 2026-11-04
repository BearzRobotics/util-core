#!/bin/sh
UTIL="basenc"
. "$(dirname "$0")/testlib.sh"

echo "hello world" > /tmp/test_basenc.txt

printf "\n[ Encoding formats ]\n"
run_test_file "--base64"         /tmp/test_basenc.txt --base64
run_test_file "--base64url"      /tmp/test_basenc.txt --base64url
run_test_file "--base32"         /tmp/test_basenc.txt --base32
run_test_file "--base32hex"      /tmp/test_basenc.txt --base32hex
run_test_file "--base16"         /tmp/test_basenc.txt --base16
run_test_file "--base2msbf"      /tmp/test_basenc.txt --base2msbf
run_test_file "--base2lsbf"      /tmp/test_basenc.txt --base2lsbf
run_test_file "--z85"            /tmp/test_basenc.txt --z85

printf "\n[ Flags ]\n"
run_test "--base64 -w 0"         --base64 -w 0 /tmp/test_basenc.txt

rm -f /tmp/test_basenc.txt
print_summary
