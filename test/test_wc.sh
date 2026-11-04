#!/bin/sh
UTIL="wc"
. "$(dirname "$0")/testlib.sh"

printf "hello world\nfoo bar baz\nline three\n" > /tmp/test_wc.txt

printf "\n[ Basic counts ]\n"
run_test_file "default (l w c)"      /tmp/test_wc.txt
run_test_file "-l lines only"        /tmp/test_wc.txt -l
run_test_file "-w words only"        /tmp/test_wc.txt -w
run_test_file "-c bytes only"        /tmp/test_wc.txt -c
run_test_file "-m chars only"        /tmp/test_wc.txt -m
run_test_file "-L max line length"   /tmp/test_wc.txt -L

printf "\n[ Multiple files ]\n"
run_test "multiple files with total" /tmp/test_wc.txt /tmp/test_wc.txt

printf "\n[ Column width (GNU compute_number_width) ]\n"
head -c 123456 /dev/zero > /tmp/test_wc_big.bin
check_stdin() { # description, args...: compare GNU and ours with stdin from the big file
    d="$1"; shift
    e=$(gnu "$@" < /tmp/test_wc_big.bin 2>&1); a=$(ours "$@" < /tmp/test_wc_big.bin 2>&1)
    [ "$e" = "$a" ] && { PASS=$((PASS + 1)); printf "PASS %s\n" "$d"; } || { FAIL=$((FAIL + 1)); printf "FAIL %s\n     GNU : %s\n     OURS: %s\n" "$d" "$e" "$a"; }
}
check_stdin "stdin is a regular file (width 6)"
check_stdin "'-' operand plus file"            - /tmp/test_wc.txt
check_stdin "/dev/null forces width 7"         /tmp/test_wc.txt /dev/null
check_stdin "missing file ignored for width"   /nonexistent-wc-test /tmp/test_wc.txt
e=$(cat /tmp/test_wc_big.bin | gnu 2>&1); a=$(cat /tmp/test_wc_big.bin | ours 2>&1)
[ "$e" = "$a" ] && { PASS=$((PASS + 1)); echo "PASS pipe stdin width 7"; } || { FAIL=$((FAIL + 1)); printf "FAIL pipe stdin\n     GNU : %s\n     OURS: %s\n" "$e" "$a"; }

rm -f /tmp/test_wc.txt /tmp/test_wc_big.bin
print_summary
