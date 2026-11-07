#!/bin/sh
# numfmt: differential tests against GNU numfmt 9.7 (C locale). References: GNU
# manual "numfmt invocation". Output, diagnostics and exit status must match.
UTIL="numfmt"
. "$(dirname "$0")/testlib.sh"
help_cmp
W="$(mktemp -d)"; cd "$W"

printf "\n[ --to scaling ]\n"
NUMS="0 1 9 10 99 100 999 1000 1001 1024 1500 1999 2000 9999 10000 10240 99999 100000 999999 1000000 1048576 1234567 12345678 999999999 1000000000 1099511627776 123456789012 1.5 0.5 9.99 99.9 -1 -999 -1000 -1500 -1048576 1e3 007 000"
for to in si iec iec-i none; do
    for n in $NUMS; do
        run_cmp "--to=$to $n" --to=$to -- $n
    done
done
for r in up down from-zero towards-zero nearest; do
    for n in 1 1234 1999 1949 1950 1951 2500 9999 99999 999499 999500 -1234 -1950 1.04 1.05 1.06 0.001; do
        run_cmp "--to=si --round=$r $n" --to=si --round=$r -- $n
        run_cmp "--to=iec --round=$r $n" --to=iec --round=$r -- $n
        run_cmp "--round=$r $n" --round=$r -- $n
    done
done
printf "\n[ --from ]\n"
for from in none auto si iec iec-i; do
    for n in 1 1K 1k 1Ki 1ki 1M 1Mi 2.5G 2.5Gi 3.7k 0K 1T 1P 1E 1Z 1Y 1R 1Q 999Q 1X 1B 1KiB 1KB K Ki "1 K" "1  Mi" 5 5. .5 -5K -1.5Mi 1e3 0x10 1,5 12K34 --5 +5 ""; do
        run_cmp "--from=$from '$n'" --from=$from -- "$n"
    done
done
printf "\n[ both ]\n"
for n in 1K 1.5K 1M 999K 1000K 1Ki 2048Ki 10Mi 1G 5.5G 100P; do
    for f in auto si iec; do
        for t in si iec iec-i; do
            run_cmp "--from=$f --to=$t $n" --from=$f --to=$t -- $n
        done
    done
done
printf "\n[ units ]\n"
for u in 1 2 512 1000 1K 1Ki 1M 1KiB 1KB 0 x -1 '' 1k 1G; do
    run_cmp "--from-unit=$u 100"   --from-unit=$u 100
    run_cmp "--to-unit=$u 100000"  --to-unit=$u 100000
    run_cmp "--from-unit=$u --to=si 1000" --from-unit=$u --to=si 1000
done
run_cmp "unit both"          --from-unit=512 --to-unit=1024 10 3 5
run_cmp "unit both iec"      --from-unit=1Ki --to=iec 1 3 1000

printf "\n[ padding ]\n"
for pad in 5 10 -5 -10 1 20 -1 0 x 1x ''; do
    for n in 1 123 12345 1.5; do
        run_cmp "--padding=$pad $n"      --padding=$pad $n
        run_cmp "--padding=$pad --to=si $n" --padding=$pad --to=si $n
    done
done
run_cmp "auto padding stdin"  --to=si -- 1000
printf '  1000\n' > in_pad; CMP_STDIN=in_pad run_cmp "leading blanks stdin" --to=si
printf '   5\n' > in_pad2; CMP_STDIN=in_pad2 run_cmp "leading blanks plain" 
printf 'a  1000   b\n' > in_pad3; CMP_STDIN=in_pad3 run_cmp "mid field auto pad" --field=2 --to=si
CMP_STDIN=in_pad3 run_cmp "delim no autopad" -d' ' --field=3 --to=si

printf "\n[ --format ]\n"
for f in '%f' '%10f' '%-10f|' '%010f' '%.2f' '%10.3f' '%-10.1f|' "%'f" '[%f]' 'a%fb' '%%%f' '%f%%' '%5f suffix' '% f' '%+f' '%.0f' '%.f' '%.' '%.-1f' '%.+1f' '% .1f' '%0.2f' '%00f' "%0'10f" '%d' '%e' 'abc' '%' '%f%f' '%%' '%10' '%-' '%.100f'; do
    for n in 1 3.14159 12345 -2.5 0; do
        run_cmp "--format '$f' $n"       --format "$f" $n
    done
    run_cmp "--format '$f' --to=si" --format "$f" --to=si 12345
done
run_cmp "--format and --padding" --format '%10f' --padding=5 3
run_cmp "--format and --padding debug" --format '%10f' --padding=5 --debug 3
run_cmp "--format and --grouping" --format '%f' --grouping 3

printf "\n[ fields and delimiters ]\n"
printf '10 2000 abc 4000\n1 22 333 4444\n  5   6   7\n' > fields
for fs in 1 2 3 4 5 1,3 2-3 2- -2 - 1-2,4 4,1 3-3 1,1 2-1 0 a '' 1- 1,,2 '1 3' 99999999999999999999 18446744073709551615 3- ,1 1, 1--2 --1; do
    CMP_STDIN=fields run_cmp "--field='$fs'" --field="$fs" --to=si --invalid=ignore
done
CMP_STDIN=fields run_cmp "--field 2 sep"   --field 2 --to=si
printf 'a:2000:c\n1000:b:3\n::\n:5:\n' > colons
for d in : ' ' , x ''; do
    CMP_STDIN=colons run_cmp "-d '$d' field1" -d "$d" --to=si --invalid=ignore
    CMP_STDIN=colons run_cmp "-d '$d' field 1-3" -d "$d" --field=1-3 --to=si --invalid=ignore
done
CMP_STDIN=colons run_cmp "-d multi"        -d :: --to=si
CMP_STDIN=colons run_cmp "-d : --field 2"  -d : --field 2 --to=si --invalid=warn
run_cmp "two fields specs"    --field 1 --field 2 5
printf '1 2\0003 4\0' > zero_in
CMP_STDIN=zero_in run_cmp "-z"             -z --field 1-2 --to=si
CMP_STDIN=zero_in run_cmp "--zero-terminated" --zero-terminated --to=si

printf "\n[ header ]\n"
printf 'H1\nH2\n1000\n2000\n' > hdr
CMP_STDIN=hdr run_cmp "--header"           --header --to=si
CMP_STDIN=hdr run_cmp "--header=2"         --header=2 --to=si
CMP_STDIN=hdr run_cmp "--header=3"         --header=3 --to=si
CMP_STDIN=hdr run_cmp "--header=10"        --header=10 --to=si
CMP_STDIN=hdr run_cmp "--header=0"         --header=0 --to=si
CMP_STDIN=hdr run_cmp "--header=x"         --header=x --to=si
CMP_STDIN=hdr run_cmp "--header 2 (operand)" --header 2 --to=si
run_cmp "--header with operand"     --header=1 --to=si 1000 2000
run_cmp "--header debug operand"    --header --debug --to=si 1000

printf "\n[ suffix ]\n"
for s in B Hz abc; do
    for n in 5 5B 5Hz 5abc 5K 5KB 500B1 B; do
        run_cmp "--suffix=$s $n"          --suffix=$s -- $n
        run_cmp "--suffix=$s --to=si $n"  --suffix=$s --to=si -- $n
        run_cmp "--suffix=$s --from=si $n" --suffix=$s --from=si -- $n
    done
done
run_cmp "--suffix with padding"   --suffix=B --padding=8 --to=si 1500 

printf "\n[ invalid handling ]\n"
printf '1000\nabc\n2000\n\n3000 x\n' > mixed
for mode in abort fail warn ignore a f w i x ''; do
    CMP_STDIN=mixed run_cmp "--invalid=$mode stdin" --invalid=$mode --to=si
    run_cmp "--invalid=$mode args"       --invalid=$mode --to=si 1000 abc 2000
    run_cmp "--invalid=$mode field"      --invalid=$mode --to=si --field=2 "x 1000 y"
done
printf 'x 1 2\n' > badf
CMP_STDIN=badf run_cmp "--invalid=fail --field 1-"  --invalid=fail --field 1- --to=si
run_cmp "empty arg"         ""
run_cmp "blank arg"         " "
run_cmp "blank arg si"      --to=si " "
run_cmp "huge digits"       123456789012345678901234567890123
run_cmp "too many digits"   1234567890123456789012345678901234
run_cmp "huge --to"         --to=si 123456789012345678901234567890123
run_cmp "huge --to 999Q"    --to=si 999999999999999999999999999999999
run_cmp "huge frac"         0.123456789012345678901234
run_cmp "max prec"          1234567890123456.789
run_cmp "prec loss debug"   --debug 1234567890123456789012
run_cmp "prec 18"           123456789012345678
run_cmp "prec 19"           1234567890123456789
run_cmp "1e19"              10000000000000000000
run_cmp "frac exceeds"      1.0000000000000000001
run_cmp "-0"                -- -0
run_cmp "-0.0 --to=si"      --to=si -- -0.0
run_cmp "dot only"          .
run_cmp "dot 5"             .5
run_cmp "5 dot"             5.
run_cmp "minus only"        -- -
run_cmp "plus"              +5
run_cmp "trailing space"    "5 "
run_cmp "trailing space si" --from=si "5 "
run_cmp "tab suffix"        --from=si "5	K"
run_cmp "space suffix"      --from=si "5 K"
run_cmp "multiple operands" 1 2 3 --to=si
run_cmp "no operands"
run_cmp "debug no-op"       --debug 5
run_cmp "debug large"       --debug --to=si 99999999999999999999
run_cmp "--grouping --to"   --grouping --to=si 5
run_cmp "--grouping"        --grouping 1234567
run_cmp "--grouping debug"  --grouping --debug 1234567

printf "\n[ options ]\n"
run_cmp "bad option"        -x 1
run_cmp "--to bad"          --to=bad 1
run_cmp "--to=iec-i abbrev" --to=iec- 1
run_cmp "--to ambiguous"    --to=i 1
run_cmp "--from=a"          --from=a 1K
run_cmp "--round bad"       --round=bad 1
run_cmp "--round=n abbrev"  --round=n 1
run_cmp "--round=to abbrev" --round=to 1
run_cmp "--round=towards"   --round=towards-zero 1
run_cmp "long abbrev"       --pad=5 1
run_cmp "-- operands"       -- -5
run_cmp "-z no input"       -z

printf "\n[ random stress ]\n"
LC_ALL=C awk 'BEGIN{srand(23); for(i=0;i<300;i++){ d=1+int(rand()*14); s=""; for(j=0;j<d;j++) s=s int(rand()*10); if (rand()<0.3) s=s "." int(rand()*1000); r=rand(); suf=""; if (r<0.2) suf="K"; else if(r<0.3) suf="Mi"; else if (r<0.35) suf="G"; print s suf }}' > rnd
while read -r line; do
    run_cmp "rnd --to=si $line"   --to=si -- "$line" --from=auto
    run_cmp "rnd --to=iec $line"  --to=iec --from=auto -- "$line"
    run_cmp "rnd --to=iec-i --round=nearest $line" --to=iec-i --from=auto --round=nearest -- "$line"
    run_cmp "rnd fmt $line"       --from=auto --format='%.2f' -- "$line"
done < rnd

print_summary
[ "$FAIL" -eq 0 ]
