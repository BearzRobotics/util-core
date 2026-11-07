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

printf "\n[ Fast paths: -l, -lc, -c ]\n"
W="$(mktemp -d)"
awk 'BEGIN { for (i = 0; i < 20000; i++) print "line " i " \t of text" }' > "$W/big"
printf 'no newline at end' > "$W/nonl"
printf '\n\n\n' > "$W/blank"
printf 'a\r\nb\rc\fd\0e\n' > "$W/ctl"
head -c 100003 /dev/urandom > "$W/rand"
: > "$W/empty"
for f in big nonl blank ctl empty; do
    for o in -l -c -lc -cl -lw -lm -lL --lines --bytes; do
        run_cmp "$f $o"      $o "$W/$f"
    done
done
# Random bytes: -w and -m differ from GNU's C locale by design (see wc.zig).
for o in -l -c -lc --lines --bytes; do
    run_cmp "rand $o"        $o "$W/rand"
done
run_cmp "-l several files"   -l "$W/big" "$W/nonl" "$W/blank"
run_cmp "-c several files"   -c "$W/big" "$W/nonl" "$W/empty"
run_cmp "-lc missing file"   -lc "$W/nonexistent" "$W/big"
run_cmp "-c a directory"     -c "$W"
run_cmp "wc a directory"     "$W"
run_cmp "-l dir and file"    -l "$W" "$W/big"
run_cmp "-c /proc file"      -c /proc/self/status
CMP_STDIN="$W/big" run_cmp "-l stdin file"   -l
CMP_STDIN="$W/big" run_cmp "-c stdin file"   -c
CMP_STDIN="$W/big" run_cmp "-c explicit -"   -c -
# Counting must not depend on where the 64 KiB read chunks split the data.
for n in 65535 65536 65537 131072 131073; do
    head -c $n /dev/zero | tr '\0' '\n' > "$W/split$n"
    run_cmp "newlines only, $n bytes -l" -l "$W/split$n"
    run_cmp "newlines only, $n bytes -lc" -lc "$W/split$n"
done
rm -rf "$W"

rm -f /tmp/test_wc.txt /tmp/test_wc_big.bin
print_summary
