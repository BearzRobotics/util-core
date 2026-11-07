#!/bin/sh
# od: differential tests against GNU od 9.7 (C locale). References: GNU manual
# "od invocation"; POSIX.1-2024 od. Multibyte characters are not interpreted.
UTIL="od"
. "$(dirname "$0")/testlib.sh"
help_cmp
W="$(mktemp -d)"; cd "$W"
LC_ALL=C awk 'BEGIN{srand(11); for(i=0;i<304;i++) printf "%c", i%256==0 ? 0 : 1+int(rand()*255)}' > rnd
LC_ALL=C awk 'BEGIN{srand(5); for(i=0;i<64;i++) printf "%c", 1+int(rand()*254)}' > r64
printf 'hello world\n\000\001\377 abc' > small
printf 'ab\0cde\0fghij\0\0kl\0mnopqr' > strs
head -c 100 /dev/zero > zeros
(head -c 48 /dev/zero; printf 'xyz'; head -c 48 /dev/zero; head -c 7 /dev/zero) > dups
printf '\000\000\300\177\000\000\300\377\000\000\200\177\000\000\200\377\000\000\000\200\000\000\200\077\000\000\000\100\377\377\177\177\001\000\000\000' > floats
printf '\0\0\0\0\0\0\370\177\0\0\0\0\0\0\370\377\0\0\0\0\0\0\360\177\0\0\0\0\0\0\360\377\1\0\0\0\0\0\0\0\0\0\0\0\0\0\360\077\030\055\104\124\373\041\011\100' > doubles
: > empty
printf 'x' > one

printf "\n[ Defaults and traditional formats ]\n"
for f in small rnd r64 one zeros dups strs empty; do
    run_cmp "default $f" $f
done
for o in -a -b -c -d -f -i -l -o -s -x -ab -bc -cx -dfi; do
    run_cmp "$o small" $o small
    run_cmp "$o rnd"   $o rnd
done

printf "\n[ -t types and sizes ]\n"
for t in a c d1 d2 d4 d8 dC dS dI dL o1 o2 o4 o8 oC oS oI oL u1 u2 u4 u8 uC uS uI uL x1 x2 x4 x8 xC xS xI xL d u o x f4 f8 fF fD fL f fH fB; do
    run_cmp "-t $t rnd"   -t $t rnd
    run_cmp "-t $t r64"   -t $t r64
    run_cmp "-t $t odd"   -t $t -N 13 r64
done
run_cmp "-t f4 specials"     -t f4 floats
run_cmp "-t f8 specials"     -t f8 doubles
run_cmp "-t fL specials"     -t fL doubles
run_cmp "-t fH specials"     -t fH floats
run_cmp "-t fB specials"     -t fB floats
run_cmp "-t d4 specials"     -t d4 floats
run_cmp "--format=x1"        --format=x1 small
run_cmp "-tx1 attached"      -tx1 small
run_cmp "-t x1 -t c"         -t x1 -t c small
run_cmp "-t x1c"             -t x1c small
run_cmp "-t cx1"             -t cx1 small
run_cmp "-t x1 -t d1 -t o2 -t x2" -t x1 -t d1 -t o2 -t x2 r64
run_cmp "-t x1 -t c -t u2"   -t x1 -t c -t u2 r64
run_cmp "-t x4 -t x1"        -t x4 -t x1 r64
run_cmp "-t f4 -t x4"        -t f4 -t x4 r64
run_cmp "-t f8 -t f4 -t x1"  -t f8 -t f4 -t x1 r64
run_cmp "-t fL -t x1"        -t fL -t x1 r64
run_cmp "-t a -t c"          -t a -t c small
run_cmp "-b -c -x"           -b -c -x r64
run_cmp "-t d3"              -t d3 small
run_cmp "-t f3"              -t f3 small
run_cmp "-t f2"              -t f2 small
run_cmp "-t x0"              -t x0 small
run_cmp "-t q"               -t q small
run_cmp "-t xz1"             -t xz1 small
run_cmp "-t d16"             -t d16 small
run_cmp "-t empty"           -t '' small
run_cmp "-t needs arg"       -t

printf "\n[ z suffix ]\n"
for t in x1z x2z x4z x8z cz az d1z o1z fFz u2z; do
    run_cmp "-t $t rnd"   -t $t rnd
    run_cmp "-t $t odd"   -t $t -N 21 r64
done
run_cmp "-t x1z -t x4"       -t x1z -t x4 -N 8 r64
run_cmp "-t x4z -t x1z -w8"  -t x4z -t x1z -w8 -N 20 r64
run_cmp "-t x1z -w4"         -t x1z -w4 -N 10 r64
run_cmp "-t x1z -w32"        -t x1z -w32 r64
run_cmp "-z unknown"         -z small

printf "\n[ Addresses ]\n"
for a in o d x n; do
    run_cmp "-A $a small"    -A $a -t x1 small
    run_cmp "-A $a rnd"      -A $a -t x2 rnd
    run_cmp "-A $a empty"    -A $a empty
    run_cmp "-A$a attached"  -A$a -t c small
    run_cmp "--address-radix=$a" --address-radix=$a -tx1 small
    run_cmp "-A $a -j 5"     -A $a -j 5 -t x1 rnd
    run_cmp "-A $a multiple formats" -A $a -t x1 -t c small
done
run_cmp "-A q"               -A q small
run_cmp "-A dx"              -A dx small
run_cmp "-A needs arg"       -A
run_cmp "-A with big address" -A x -j 250 -t x1 rnd

printf "\n[ -j -N -w -v ]\n"
for j in 0 1 5 16 17 100 299 300 301 0x10 010 1b 1K 1KB 0x1b; do
    run_cmp "-j $j"          -j $j rnd
done
run_cmp "-j bad"             -j abc small
run_cmp "-j negative"        -j -1 small
run_cmp "-j past end"        -j 1000 small
run_cmp "-j exactly end"     -j 300 rnd
run_cmp "--skip-bytes=3"     --skip-bytes=3 small
for n in 0 1 5 16 17 100 299 300 301 0x10 1b 1K; do
    run_cmp "-N $n"          -N $n rnd
done
run_cmp "-N bad"             -N abc small
run_cmp "--read-bytes=4"     --read-bytes=4 small
run_cmp "-j 3 -N 5"          -j 3 -N 5 small
run_cmp "-j 3 -N 5 -tx1"     -j 3 -N 5 -tx1 small
for w in 1 2 3 4 5 8 10 16 17 24 32 48 64; do
    run_cmp "-w $w x1"       -w$w -tx1 rnd
    run_cmp "-w $w x2"       -w$w -tx2 rnd
    run_cmp "-w $w x4"       -w$w -tx4 r64
    run_cmp "-w $w default"  -w$w r64
done
run_cmp "-w alone"           -w -tx1 rnd
run_cmp "--width"            --width -tx1 rnd
run_cmp "--width=8"          --width=8 -tx1 rnd
run_cmp "--width 8 operand"  --width 8 -tx1 small
run_cmp "-w bad"             -wabc small
run_cmp "-w f16"             -w16 -tfL r64
run_cmp "-w with f16 odd"    -w8 -tfL r64
run_cmp "-t fL default width" -tfL rnd
run_cmp "-v zeros"           -v zeros
run_cmp "no -v zeros"        zeros
run_cmp "-v dups"            -v dups
run_cmp "dups"               dups
run_cmp "dups -tx1"          -tx1 dups
run_cmp "dups -w8"           -w8 -tx1 dups
run_cmp "dups -tc"           -tc dups
run_cmp "--output-duplicates" --output-duplicates zeros
run_cmp "dups -N"            -N 96 -tx1 dups
run_cmp "dups two formats"   -tx1 -tc dups
run_cmp "dups with z"        -tx1z dups

printf "\n[ Strings and endian ]\n"
for n in 1 2 3 4 5 8; do
    run_cmp "-S $n"          -S $n strs
    run_cmp "-S $n -A n"     -S $n -A n strs
    run_cmp "-S $n -A x"     -S $n -A x strs
    run_cmp "--strings=$n"   --strings=$n strs
done
run_cmp "-S default"         --strings strs
run_cmp "-S small"           -S 3 small
run_cmp "-S with -t"         -S 3 -tx1 strs
run_cmp "-S bad"             -S abc strs
run_cmp "-S -j"              -S 2 -j 2 strs
run_cmp "-S rnd"             -S 4 rnd
for e in big little; do
    for t in x2 x4 x8 d2 d4 u4 u8 f4 f8 fL fH fB; do
        run_cmp "--endian=$e -t $t" --endian=$e -t $t r64
    done
    run_cmp "--endian=$e -c"  --endian=$e -c small
done
run_cmp "--endian bad"       --endian=middle small

printf "\n[ Files and operands ]\n"
run_cmp "two files"          small strs
run_cmp "two files -tx1"     -tx1 small one
run_cmp "dash stdin"         - 
CMP_STDIN=small run_cmp "stdin"
CMP_STDIN=small run_cmp "stdin dash" -
CMP_STDIN=small run_cmp "stdin plus offset" +3
CMP_STDIN=small run_cmp "stdin plus offset -An" -An +3
CMP_STDIN=small run_cmp "stdin traditional offset" --traditional +3
CMP_STDIN=small run_cmp "stdin traditional octal" --traditional 10
CMP_STDIN=small run_cmp "stdin traditional 0x" --traditional 0x3
run_cmp "missing file"       nofile
run_cmp "missing then good"  nofile small
run_cmp "good then missing"  small nofile
run_cmp "directory"          .
run_cmp "modern option: digits are a file" -An small 3
run_cmp "modern option -j"   -j 0 small 3
for off in 3 +3 10 010 1b +1b 1B 0x3 0x10 08 3. 10. 1.b .5 + x 9x 0b; do
    run_cmp "plain offset $off" -c small $off
    run_cmp "plain offset $off rnd" -c rnd $off
    run_cmp "plain offset $off nopt" rnd $off
done
run_cmp "plain offset two files" small strs 3
run_cmp "plain offset with plus only" -c +3
for off in 3 +3 10 010 1b +1b 1B 0x3 0x10 0X10 0x10b 08 09 3. 10. 1.b .5 + x 9x 1000 0 0b; do
    run_cmp "--traditional offset $off" --traditional rnd $off
    run_cmp "--traditional label $off" --traditional rnd 5 $off
done
run_cmp "--traditional 3 operands" --traditional small 1 2 3
run_cmp "--traditional two files"  --traditional small strs
run_cmp "two operands not offset" small strs
run_cmp "file named like num" -- 3
run_cmp "three operands"     small strs 3
run_cmp "--traditional offset" --traditional small 3
run_cmp "--traditional label"  --traditional small 1 2
run_cmp "--traditional label x" --traditional -A x small 1 2
run_cmp "--traditional only file" --traditional small
run_cmp "--traditional label big" --traditional rnd 0 100

printf "\n[ Option parsing ]\n"
run_cmp "bad option"         -y small
run_cmp "bundled -bcx"       -bcx small
run_cmp "-An attached"       -An small
run_cmp "-j3N4"              -j3 -N4 small
run_cmp "-- file"            -- small
run_cmp "long abbrev"        --skip=3 small
run_cmp "--address abbrev"   --address=x small
run_cmp "ambiguous"          --e small

print_summary
[ "$FAIL" -eq 0 ]
