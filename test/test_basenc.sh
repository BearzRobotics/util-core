#!/bin/sh
# basenc: differential tests against GNU basenc 9.7, once per encoding; see basetests.sh.
UTIL="basenc"
TD="$(cd "$(dirname "$0")" && pwd)"
. "$TD/testlib.sh"
for ENC_OPT in --base64 --base64url --base32 --base32hex --base16 --base2msbf --base2lsbf --z85; do
    printf "\n##### basenc %s #####\n" "$ENC_OPT"
    . "$TD/basetests.sh"
done
printf "\n[ basenc option errors ]\n"
run_cmp "no encoding"          /dev/null
run_cmp "no encoding -d"       -d /dev/null
run_cmp "two encodings"        --base64 --base32 /dev/null
print_summary
