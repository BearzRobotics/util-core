#!/bin/sh
# shuf: differential tests against GNU shuf 9.7 (C locale). References: GNU
# manual "shuf invocation". With --random-source the output is deterministic and
# must be byte-identical to GNU's; without it only properties are checked
# (same multiset, requested counts).
UTIL="shuf"
. "$(dirname "$0")/testlib.sh"
help_cmp
W="$(mktemp -d)"; cd "$W"
LC_ALL=C awk 'BEGIN{srand(17); for(i=0;i<400000;i++) printf "%c", 1+int(rand()*255)}' > src1
LC_ALL=C awk 'BEGIN{srand(99); for(i=0;i<400000;i++) printf "%c", 1+int(rand()*255)}' > src2
printf 'abc' > tiny
seq 1 1800000 > big; seq 1 20 > n20; seq 1 1000 > n1000; seq 1 200000 > n200k
printf 'one\ntwo\nthree\nfour\nfive\nsix\nseven\n' > words
printf 'no newline at end' > nonl
printf 'a\0b\0c\0d\0e\0f\0' > nul
printf 'x\n\ny\n\n\nz\n' > blanks
: > empty
RS="--random-source"

printf "\n[ Reproducible output ]\n"
for s in src1 src2; do
    for f in n20 n1000 words nonl blanks one; do
        [ -f $f ] || printf 'only\n' > one
        run_cmp "$RS $s $f"          $RS=$s $f
        run_cmp "$RS $s $f -n 3"     $RS=$s -n 3 $f
        run_cmp "$RS $s $f -n 1"     $RS=$s -n 1 $f
        run_cmp "$RS $s $f -r -n 5"  $RS=$s -r -n 5 $f
    done
    run_cmp "$RS $s -i 1-10"         $RS=$s -i 1-10
    run_cmp "$RS $s -i 5-5"          $RS=$s -i 5-5
    run_cmp "$RS $s -i 0-1000 -n 7"  $RS=$s -i 0-1000 -n 7
    run_cmp "$RS $s -i 1-100 -r -n 12" $RS=$s -i 1-100 -r -n 12
    run_cmp "$RS $s -i huge -n 3"    $RS=$s -i 1-4000000000 -n 3
    run_cmp "$RS $s -i huge sparse"  $RS=$s -i 1-10000000 -n 20
    run_cmp "$RS $s -i u64 -n 2 -r"  $RS=$s -i 0-18446744073709551615 -n 2 -r
    run_cmp "$RS $s -e"              $RS=$s -e a b c d e f g h
    run_cmp "$RS $s -e -n 2"         $RS=$s -e -n 2 a b c d e
    run_cmp "$RS $s -e -r -n 9"      $RS=$s -e -r -n 9 x y z
    run_cmp "$RS $s -z"              $RS=$s -z nul
    run_cmp "$RS $s -z -n 2"         $RS=$s -z -n 2 nul
    run_cmp "$RS $s -zi"             $RS=$s -z -i 1-5
    run_cmp "$RS $s n200k -n 5"      $RS=$s -n 5 n200k
    run_cmp "$RS $s n200k"           $RS=$s n200k
    run_cmp "$RS $s big -n 5 (reservoir)" $RS=$s -n 5 big
    run_cmp "$RS $s big -n 1000 (reservoir)" $RS=$s -n 1000 big
done
run_cmp "big -n 3 from stdin"  $RS=src1 -n 3 - < /dev/null
CMP_STDIN=big run_cmp "reservoir stdin file" $RS=src1 -n 7
run_cmp "$RS short source"    $RS=tiny n20
run_cmp "$RS missing"         $RS=nofile n20
run_cmp "$RS empty source"    $RS=empty n20
run_cmp "$RS empty source n=1" $RS=empty -n 1 one
run_cmp "$RS two same"        $RS=src1 $RS=src1 n20
run_cmp "$RS two different"   $RS=src1 $RS=src2 n20
run_cmp "$RS stdin"           $RS=src1 -
CMP_STDIN=n20 run_cmp "$RS from stdin" $RS=src1
CMP_STDIN=n20 run_cmp "$RS from stdin -n" $RS=src1 -n 4
run_cmp "$RS separate arg"    $RS src1 n20
run_cmp "$RS dev-zero style"  $RS=/dev/null -n 0 n20

printf "\n[ -o ]\n"
run_cmp "-o file"             $RS=src1 -o out n20
run_cmp "-o same file twice"  $RS=src1 -o out -o out n20
run_cmp "-o differ"           $RS=src1 -o a -o b n20
run_cmp "-o missing dir"      $RS=src1 -o nodir/x n20
cp n20 inplace; run_cmp "-o input file" $RS=src1 -o inplace inplace
run_cmp "--output="           $RS=src1 --output=o2 n20

printf "\n[ Edge cases ]\n"
run_cmp "empty input"         $RS=src1 empty
run_cmp "-n 0"                $RS=src1 -n 0 n20
run_cmp "-n 0 missing"        $RS=src1 -n 0 nofile
run_cmp "-n bad"              -n x n20
run_cmp "-n negative"         -n -1 n20
run_cmp "-n huge"             $RS=src1 -n 99999999999999999999999 n20
run_cmp "-n larger than input" $RS=src1 -n 1000 n20
run_cmp "-n twice"            $RS=src1 -n 5 -n 3 n20
run_cmp "-n twice other order" $RS=src1 -n 3 -n 5 n20
run_cmp "--head-count=4"      $RS=src1 --head-count=4 n20
run_cmp "-r empty"            $RS=src1 -r empty
run_cmp "-r -n 0 empty"       $RS=src1 -r -n 0 empty
run_cmp "-r -i range"         $RS=src1 -r -i 3-3 -n 3
run_cmp "-i bad"              -i x
run_cmp "-i no dash"          -i 5
run_cmp "-i reversed"         -i 5-3
run_cmp "-i 0-18446744073709551615" $RS=src1 -i 0-18446744073709551615 -n 1
run_cmp "-i overflow"         -i 1-99999999999999999999999
run_cmp "-i neg"              -i -1-5
run_cmp "-i twice"            -i 1-3 -i 4-6
run_cmp "-i with operand"     -i 1-3 n20
run_cmp "-i with -e"          -i 1-3 -e a
run_cmp "-e no args"          $RS=src1 -e
run_cmp "-e -r no args"       $RS=src1 -e -r
run_cmp "two operands"        n20 words
run_cmp "missing file"        nofile
run_cmp "directory"           .
run_cmp "bad option"          -x
run_cmp "long abbrev"         --head=2 $RS=src1 n20
run_cmp "ambiguous"           --r n20
run_cmp "-- operand"          $RS=src1 -- n20
run_cmp "-e with -- dash args" $RS=src1 -e -- -a -b -c

printf "\n[ Properties without a random source ]\n"
prop() { desc="$1"; shift; if "$@"; then PASS=$((PASS + 1)); printf "PASS %s\n" "$desc"; else FAIL=$((FAIL + 1)); printf "FAIL %s\n" "$desc"; fi; }
O="$BIN_DIR/shuf"
prop "permutation keeps lines"  sh -c "$O n20 | sort -n | cmp - n20"
prop "permutation of 1000"      sh -c "$O n1000 | sort -n | cmp - n1000"
prop "-n 5 gives 5 distinct"    sh -c "[ \$($O -n 5 n20 | sort -u | wc -l) = 5 ]"
prop "-n 100 on 20 gives 20"    sh -c "[ \$($O -n 100 n20 | wc -l) = 20 ]"
prop "-r -n 50 gives 50"        sh -c "[ \$($O -r -n 50 n20 | wc -l) = 50 ]"
prop "-i range permutes"        sh -c "$O -i 1-20 | sort -n | cmp - n20"
prop "-i -z uses NUL"           sh -c "[ \$($O -z -i 1-3 | tr -d \"\\\\0\" | wc -c) = 3 ]"
prop "-e permutes args"         sh -c "[ \$($O -e a b c d | sort | tr -d '\\n') = abcd ]"
prop "two runs differ"          sh -c "[ \"\$($O n1000 | md5sum)\" != \"\$($O n1000 | md5sum)\" ]"
prop "output file"              sh -c "$O -o pout n20 && sort -n pout | cmp - n20"
prop "missing newline appended" sh -c "[ \$($O nonl | wc -c) = 18 ]"
print_summary
[ "$FAIL" -eq 0 ]
