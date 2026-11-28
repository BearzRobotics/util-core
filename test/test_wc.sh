#!/bin/sh
UTIL="wc"
. "$(dirname "$0")/testlib.sh"

W="$(mktemp -d)"
printf "hello world\nfoo bar baz\nline three\n" > "$W/text"
printf 'a\tbb\t\tc\n12345678\t9\nx\rlonger than that\ry\nff\fnext\fz\nbs\bover\nctl\001\002\033[1m\177 end\n' > "$W/layout"

printf "\n[ Basic counts ]\n"
for o in "" -l -w -c -m -L; do
    run_cmp "text ${o:-default}"     $o "$W/text"
done
for o in "" -w -m -L -lwmcL; do
    run_cmp "tabs and control bytes ${o:-default}" $o "$W/layout"
done

printf "\n[ Multiple files ]\n"
run_cmp "multiple files with total"  "$W/text" "$W/text"

printf "\n[ Column width (GNU compute_number_width) ]\n"
head -c 123456 /dev/zero > "$W/zeros"
CMP_STDIN="$W/zeros" run_cmp "stdin is a regular file (width 6)"
CMP_STDIN="$W/zeros" run_cmp "'-' operand plus file"          - "$W/text"
CMP_STDIN="$W/zeros" run_cmp "/dev/null forces width 7"       "$W/text" /dev/null
CMP_STDIN="$W/zeros" run_cmp "missing file ignored for width" "$W/nonexistent" "$W/text"
e=$(cat "$W/zeros" | LC_ALL=C gnu 2>&1; echo "rc=$?"); a=$(cat "$W/zeros" | LC_ALL=C ours 2>&1; echo "rc=$?")
[ "$e" = "$a" ] && { PASS=$((PASS + 1)); echo "PASS pipe stdin width 7"; } || { FAIL=$((FAIL + 1)); printf "FAIL pipe stdin\n     GNU : %s\n     OURS: %s\n" "$e" "$a"; }

printf "\n[ Fast paths: -l, -lc, -c ]\n"
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

# sysfs says one page for a file holding a few bytes.
for f in /sys/kernel/mm/transparent_hugepage/enabled /sys/devices/system/cpu/online; do
    [ -r "$f" ] && run_cmp "-c $f" -c "$f"
done

print_summary
