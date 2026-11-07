#!/bin/sh
# seq: differential tests against GNU seq. Reference: GNU manual "seq
# invocation" (POSIX does not specify seq). Cases where GNU's long double
# arithmetic is inexact (huge or non-representable values) are not compared.
UTIL="seq"
. "$(dirname "$0")/testlib.sh"

printf "\n[ Integers ]\n"
for a in "1" "5" "0" "-1" "-3" "3 1" "1 5" "-2 2" "5 -1 1" "1 2 10" "1 3 10" "10 -3 -10" "2 2 3" "3 -1 1" "1 1 1" "7 7" "10 1" \
         "100000 100003" "99999999999 100000000002" "-5 -1 -20" "+3" "1 +2 9" "5."  ".5" "1 .5 3"; do
    run_cmp "seq $a" $a
done

printf "\n[ Decimals: exact steps and precision ]\n"
for a in "0 0.1 0.3" "1 0.1 1.3" "0 0.1 0.7" "0.1 0.1 0.9" "0 0.1 1" "1.5 0.5 3" "0.0 0.1 0.25" "-1 -0.5 -3" "0 0.25 1" \
         "1e-2 3e-2 .1" "1e-5 1e-5 3e-5" "1e2 1e2 3e2" "1 1e1 31" "0 .001 .005" "2.50 .5 4" "0.30 0.01 0.33" "1 0.3 2.5" "10 -0.5 8" "0 1e-3 3e-3"; do
    run_cmp "seq $a" $a
done

printf "\n[ -w equal width ]\n"
for a in "-w 8 10" "-w 1 10" "-w 1 3 1000" "-w 1 1000 1002" "-w 08 10" "-w 9 11" "-w 99 100" "-w 1e1 12" "-w 5 2 3" "-w 1 -1 -3" "-w -1 1" "-w -2 2" \
         "-w 8 0.5 10" "-w 0.5 10" "-w 1.5 3" "-w 0 0.1 0.5" "-w -5 -1 -12" "--equal-width 3 6"; do
    run_cmp "seq $a" $a
done

printf "\n[ -s separator ]\n"
run_cmp "-s,"             -s, 3
run_cmp "-s ', '"         -s ', ' 4
run_cmp "-s empty"        -s '' 3
run_cmp "--separator=:"   --separator=: 3
run_cmp "-s with -w"      -w -s: 8 10
run_cmp "-s multi-char"   -s '--' 1 3
run_cmp "-s one number"   -s, 1

printf "\n[ -f format ]\n"
for f in '%g' '%f' '%e' '%E' '%G' '%.2f' '%5.1f|' '%-6.1f|' '%+f' '% f' '%08.3f' '%.0f' '%#.0f' '%10.3e' '[%g]' '%f%%' '%%%f' 'x%fy' '%Lf' '%5g' '%.10g' '%03.0f' '%.3e'; do
    run_cmp "-f '$f'" -f "$f" 1 3
done
run_cmp "-f with step"       -f '%.2f' 0 0.25 1
run_cmp "-f big"             -f '%.0f' 99999999 99999999
run_cmp "-f exp values"      -f '%g' 1e5 1e5 4e5
run_cmp "--format="          --format='%03.0f' 8 10
run_cmp "-f and -w together" -f '%.1f' -w 1 3
run_cmp "-f attached"        -f%.2f 1 2
run_cmp "-f -s together"     -f '%.1f' -s ' ' 1 3

printf "\n[ Infinity, hex, exponent ]\n"
e=$(/usr/bin/seq inf 2>/dev/null | head -3); o=$("$BIN_DIR/seq" inf | head -3)
[ "$e" = "$o" ] && { PASS=$((PASS + 1)); echo "PASS seq inf (first 3)"; } || { FAIL=$((FAIL + 1)); echo "FAIL seq inf: [$e] [$o]"; }
e=$(/usr/bin/seq 5 inf | head -3); o=$("$BIN_DIR/seq" 5 inf | head -3)
[ "$e" = "$o" ] && { PASS=$((PASS + 1)); echo "PASS seq 5 inf (first 3)"; } || { FAIL=$((FAIL + 1)); echo "FAIL seq 5 inf"; }
e=$(/usr/bin/seq -- 10 -1 -inf | head -3); o=$("$BIN_DIR/seq" -- 10 -1 -inf | head -3)
[ "$e" = "$o" ] && { PASS=$((PASS + 1)); echo "PASS seq 10 -1 -inf (first 3)"; } || { FAIL=$((FAIL + 1)); echo "FAIL seq 10 -1 -inf"; }
run_cmp "exponent last"      1e1
run_cmp "hex operands"       0x1p3 0x1p3 0x1p5
run_cmp "hex last"           0x10
run_cmp "inf with step down" 1 -1 inf

printf "\n[ Errors ]\n"
run_cmp "no operands"
run_cmp "four operands"       1 2 3 4
run_cmp "zero increment"      1 0 3
run_cmp "zero increment 0.0"  1 0.0 3
run_cmp "not a number"        a
run_cmp "nan"                 nan
run_cmp "nan as last"         1 nan
run_cmp "bad second operand"  1 x 3
run_cmp "comma decimal"       1,5
run_cmp "invalid option"      -x 3
run_cmp "unrecognized long"   --nope 3
run_cmp "-f missing arg"      -f
run_cmp "format no directive" -f hello 3
run_cmp "format too many"     -f '%f%f' 3
run_cmp "format unknown d"    -f '%d' 3
run_cmp "format unknown i"    -f '%i' 3
run_cmp "format star"         -f '%*f' 3
run_cmp "format ends in %"    -f '%' 3
run_cmp "format %ll"          -f '%ll' 3
run_cmp "-- then number"      -- 3
run_cmp "negative via --"     -- -3 -1

printf "\n[ Large output ]\n"
e=$(/usr/bin/seq 1 200000 | cksum); o=$("$BIN_DIR/seq" 1 200000 | cksum)
[ "$e" = "$o" ] && { PASS=$((PASS + 1)); echo "PASS seq 1 200000 checksum"; } || { FAIL=$((FAIL + 1)); echo "FAIL large"; }
e=$(/usr/bin/seq -w 0.1 0.1 1000 | cksum); o=$("$BIN_DIR/seq" -w 0.1 0.1 1000 | cksum)
[ "$e" = "$o" ] && { PASS=$((PASS + 1)); echo "PASS seq -w 0.1 0.1 1000 checksum"; } || { FAIL=$((FAIL + 1)); echo "FAIL large decimals"; }

printf "\n[ Integer fast path boundaries ]\n"
run_cmp "i64 max-2 .. max"        9223372036854775805 9223372036854775807
run_cmp "i64 max-2 .. beyond"     9223372036854775805 9223372036854775810
run_cmp "i64 min .. min+2"        -9223372036854775808 -9223372036854775806
run_cmp "i64 min-1 .. min+1"      -9223372036854775809 -9223372036854775807
run_cmp "down to min"             -9223372036854775806 -1 -9223372036854775808
run_cmp "big step overflow"       9223372036854775800 5 9223372036854775807
run_cmp "big negative step"       -9223372036854775800 -5 -9223372036854775808
run_cmp "step larger than range"  1 100 50
run_cmp "single value"            5 1 5
run_cmp "empty ascending"         5 1 4
run_cmp "empty descending"        1 -1 2
run_cmp "negatives"               -5 3 5
run_cmp "powers of ten"           98 1 103
run_cmp "1e3 operands"            1e3 1e3 5e3
run_cmp "-s separator"            -s, 1 5
run_cmp "-s multi char"           -s ' | ' 8 12
run_cmp "-w small"                -w 8 12
run_cmp "-w negative"             -w -3 3
run_cmp "step 0"                  1 0 5
run_cmp "big count 100000 sum"    1 100000
r=$(ours 1 3000000 | md5sum); g=$(gnu 1 3000000 | md5sum)
[ "$r" = "$g" ] && { PASS=$((PASS+1)); echo "PASS 3000000 numbers identical"; } || { FAIL=$((FAIL+1)); echo "FAIL 3000000 numbers differ"; }
r=$(ours -s: -9999 7 99999 | md5sum); g=$(gnu -s: -9999 7 99999 | md5sum)
[ "$r" = "$g" ] && { PASS=$((PASS+1)); echo "PASS step 7 across zero identical"; } || { FAIL=$((FAIL+1)); echo "FAIL step 7 across zero differ"; }

print_summary
