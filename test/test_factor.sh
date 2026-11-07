#!/bin/sh
# factor: differential tests against GNU factor 9.7 (C locale). Reference:
# GNU manual "factor invocation".
UTIL="factor"
. "$(dirname "$0")/testlib.sh"
W="$(mktemp -d)"; cd "$W"

printf "\n[ Small numbers ]\n"
n=0
while [ $n -le 300 ]; do run_cmp "factor $n" $n; n=$((n + 1)); done
run_cmp "-h small"          -h 360 1024 7 1 0 12
run_cmp "--exponents"       --exponents 360 2 4 8 9 27 100
run_cmp "several operands"  10 20 30 40 50
run_cmp "-- operands"       -- 12
run_cmp "-h no operand stdin" -h

printf "\n[ Word and 128-bit boundaries ]\n"
for v in 255 256 257 65535 65536 65537 4294967295 4294967296 4294967297 4294967311 \
         18446744073709551557 18446744073709551559 18446744073709551615 18446744073709551616 18446744073709551617 \
         9223372036854775807 9223372036854775808 9223372036854775783 \
         170141183460469231731687303715884105727 170141183460469231731687303715884105728 \
         340282366920938463463374607431768211455 340282366920938463463374607431768211454 \
         340282366920938463463374607431768211456 \
         340282366920938463463374607431768211297 ; do
    run_cmp "factor $v"     $v
    run_cmp "factor -h $v"  -h $v
done

printf "\n[ Products of primes ]\n"
for v in 1000000007 998244353 \
         998244353000000007 1000000007998244353 \
         1000003000009 1000033000289 \
         99999999977 99999999977999999999 \
         1000000007000000007 1000000007998244353000000007 \
         12345678901234567890123456789012345678 \
         123456789123456789123456789123456789 \
         2305843009213693951 4611686014132420609 \
         1180591620717411303424 1180591620717411303423 1180591620717411303425 \
         6766034201497653127 \
         36893488147419103232 36893488147419103231 \
         257 65537 6700417 67280421310721 \
         1000000016000000063 100000000000000000039; do
    run_cmp "factor $v"     $v
done
run_cmp "squares of primes" 1000000014000000049 9999999800000001 4294967311 18446744065119617025
run_cmp "cubes"             1000000021 8 27 125 343 1000000000000000000000000000
run_cmp "powers of two"     1 2 4 8 16 4294967296 18446744073709551616 170141183460469231731687303715884105728

printf "\n[ Beyond 128 bits ]\n"
for v in 99999999999999999999999999999999999999999 \
         123456789012345678901234567890 \
         1000000000000000000000000000000000000000 \
         2000000000000000000000000000000000000001 \
         115792089237316195423570985008687907853269984665640564039457584007913129639936 \
         100000000000000000000000000000000000000000000000000000000000000000000000000000; do
    run_cmp "factor $v"     $v
done

printf "\n[ Input forms ]\n"
for v in '+5' ' 7' '7 ' '00012' '000' '+0' '+' '-' '-3' '0x10' '1e3' '3.5' '' ' ' '12abc' 'abc' '1 2' '٣' '12-' '--' '١٢'; do
    run_cmp "operand '$v'"  -- "$v"
done
run_cmp "valid and invalid"    12 abc 15 -3 21
printf '10 20\n30\n' > in1;                 CMP_STDIN=in1 run_cmp "stdin lines"
printf '1 2  3\t4\n' > in2;                 CMP_STDIN=in2 run_cmp "stdin blanks"
printf '12\n\nx\n 6 \n' > in3;              CMP_STDIN=in3 run_cmp "stdin with bad token"
printf '' > in4;                            CMP_STDIN=in4 run_cmp "empty stdin"
printf '  \n\n  \n' > in5;                  CMP_STDIN=in5 run_cmp "blank stdin"
printf '77' > in6;                          CMP_STDIN=in6 run_cmp "stdin no newline"
printf '18446744073709551616 99999999999999999999999999999999999999999\n' > in7; CMP_STDIN=in7 run_cmp "stdin big"
printf '1\r\n2\r\n' > in8;                  CMP_STDIN=in8 run_cmp "stdin CRLF"
printf '+7 -7 7+\n' > in9;                  CMP_STDIN=in9 run_cmp "stdin signs"
seq 1 2000 > in10;                          CMP_STDIN=in10 run_cmp "stdin 1..2000"
CMP_STDIN=in1 run_cmp "operand beats stdin"  5
run_cmp "unknown option"       --bogus 5
run_cmp "-x"                   -x 5
run_cmp "-h attached"          -h5

printf "\n[ Random numbers ]\n"
# Seeded products of 1 to 5 random factors; awk keeps the values within 2^53,
# so larger products are composed from several smaller random numbers.
awk 'BEGIN { srand(61); for (i = 0; i < 150; i++) { n = 1 + int(rand() * 9007199254740991 / (1 + int(rand() * 1000000))); print n } }' > rnd1
for v in $(cat rnd1); do run_cmp "random $v" $v; done
awk 'BEGIN { srand(62); for (i = 0; i < 40; i++) { s = ""; l = 20 + int(rand() * 18); s = int(1 + rand() * 9); for (j = 1; j < l; j++) s = s int(rand() * 10); print s } }' > rnd2
for v in $(cat rnd2); do run_cmp "random digits $v" $v; done
rm -rf "$W"
print_summary
