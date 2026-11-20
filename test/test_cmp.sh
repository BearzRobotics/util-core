#!/bin/sh
# cmp: differential tests against GNU cmp 3.12 (C locale). References: GNU
# diffutils manual "Invoking cmp"; POSIX.1-2024 cmp.
UTIL="cmp"
. "$(dirname "$0")/testlib.sh"
. "$(dirname "$0")/difflib.sh"

W="$(mktemp -d)"; cd "$W"
printf 'abc\ndef\nghi\n' > a
printf 'abc\ndXf\nghi\nzz' > b
printf 'abc\n' > c
: > e
printf 'abc' > p
printf 'abcdef\n' > q
printf 'abc\nabcd' > r
printf 'abc\nab' > s2
printf '\001\200\377\177 ' > u
printf 'x\002\001\000\n' > v
seq 1 100000 > big1
seq 1 100001 | sed 's/^5000$/x/' > big2
mkdir dd

printf "\n[ Basic ]\n"
for args in "a b" "-b a b" "-l a b" "-lb a b" "-s a b" "a c" "c a" "-l a c" "-b a c" "a e" "e a" "e e" "a a" "p q" "q p" "-l p q" "r s2" "s2 r" "r q" "u v" "-b u v" "-l u v" "-lb u v" "-c a b" "--print-chars a b" "-bl p q" "-s a c" "-s a a" "-l big1 big2" "big1 big2" "-b big1 big2" "-l -n 20000 big1 big2" "a b a" "-- a b"; do
    run_cmp "cmp $args" $args
done

printf "\n[ -n, -i and SKIP operands ]\n"
for args in "-n 2 a b" "-n 6 a b" "-n 0 a b" "-n 1M a b" "-n k a b" "-n 1kB a b" "-n 1KiB a b" "-n +3 a b" "-n 07 a b" "-n 0x6 a b" "-n 99999999999999999999 a b" "-n 1Y a b"
do run_cmp "cmp $args" $args; done
for args in "-i 2 a b" "-i 2:3 a b" "-i 1k a b" "-i 1kB a b" "-i 99 a b" "-i 99 a c" "-i 010 a b" "-i 8 a b" "-i 1 -i 2 a b" "-i 3:1 -i 1:3 a b" "--ignore-initial=1:2 a b" "--ignore-init=1 a b" "--i=1 a b" "-i 99999999999999999999 a b" "-i kB a b" "-i 4 -n 3 a b" "-l -i 1 a b"; do
    run_cmp "cmp $args" $args
done
for args in "a b 1 2" "a b 1" "a b 99" "a b 3 3" "-i 1 a b 2" "-i 5 a b 1" "-i 5 a b 6" "a b 4 4" "a b 1k" "a b 1 1k" "-l a b 2 3" "a b -- 1"; do
    run_cmp "cmp $args" $args
done

printf "\n[ Errors ]\n"
for args in "a nonexist" "nonexist a" "-s a nonexist" "-n -1 a b" "-n x a b" "-n 3x a b" "-n 1e3 a b" "-n 1D a b" "-n 1b a b" "-n 1c a b" "-n 1kBx a b" "-i x a b" "-i : a b" "-i 1: a b" "-i :1 a b" "-i 1:2:3 a b" "-i 08 a b" "-i 1b a b" "-i 1,2 a b" "a b b" "a b 1 b" "a b 1 2 3" "a b 1 2 3 4" "-x a b" "--foo" "--v a b" "-sl a b" "-ls a b" "--verbose --quiet a b" "a /" "a ." ". ." ". a" "a dd" "dd a" "dd dd" "dd nonexist" "nonexist dd" "-V a b" "--bytes" "-n" "-i" "-l a" "-n a b" "-s"; do
    run_cmp "cmp $args" $args
done

printf "\n[ Standard input ]\n"
CMP_STDIN="$W/a"
run_cmp "stdin vs a"        - a
run_cmp "a vs stdin"        a -
run_cmp "stdin default"     a
run_cmp "stdin both"        - -
run_cmp "stdin -l"          -l - b
CMP_STDIN="$W/b"
run_cmp "stdin vs a (b)"    - a
run_cmp "-l stdin vs a"     -l - a
run_cmp "-i stdin"          -i 3 a -
run_cmp "-n stdin"          -n 5 a -
CMP_STDIN="$W/e"
run_cmp "stdin empty"       a -
run_cmp "stdin empty e"     e -
unset CMP_STDIN

printf "\n[ --help and --version ]\n"
help_cmp_diffutils
exp=$(LC_ALL=C /usr/bin/cmp --version | head -n 1 | sed 's/^cmp (GNU diffutils).*/cmp/')
act=$("$BIN_DIR/cmp" --version | head -n 1 | sed 's/^cmp (.*/cmp/')
if [ "$exp" = "$act" ]; then PASS=$((PASS + 1)); echo "PASS --version first line"; else FAIL=$((FAIL + 1)); echo "FAIL --version first line"; fi
run_cmp "--version rc" --version-x
for args in "-v" ; do
    "$BIN_DIR/cmp" $args >/dev/null; rc=$?
    if [ $rc = 0 ]; then PASS=$((PASS + 1)); echo "PASS cmp -v exits 0"; else FAIL=$((FAIL + 1)); echo "FAIL cmp -v exits 0"; fi
done

printf "\n[ Generated pairs ]\n"
i=0
while [ $i -lt 120 ]; do
    i=$((i + 1))
    awk -v seed=$i 'BEGIN { srand(seed); n = int(rand() * 3000);
        for (k = 0; k < n; k++) { r = rand(); if (r < 0.1) printf "\n"; else printf "%c", 97 + int(rand() * 4) } }' > g1
    awk -v seed=$i 'BEGIN { srand(seed + 1000); }
        { }' /dev/null
    cp g1 g2
    # mutate a few places
    awk -v seed=$i 'BEGIN { RS = "^$"; srand(seed * 7) } { s = $0; k = int(rand() * 4);
        for (j = 0; j < k && length(s) > 0; j++) { p = 1 + int(rand() * length(s)); s = substr(s, 1, p - 1) sprintf("%c", 65 + int(rand() * 3)) substr(s, p + 1) }
        t = rand(); if (t < 0.2) s = substr(s, 1, int(rand() * length(s))); else if (t < 0.3) s = s "zz";
        printf "%s", s }' g1 > g2
    for o in "" -l -b -lb -s "-n 100" "-i 5" "-i 3:7" "-l -n 50"; do
        run_cmp "gen $i $o" $o g1 g2
    done
done

printf "\n[ Closed and full output ]\n"
gx=$(LC_ALL=C /usr/bin/cmp -l a b > /dev/full 2>/dev/null; echo $?)
ox=$("$BIN_DIR/cmp" -l a b > /dev/full 2>/dev/null; echo $?)
if [ "$gx" = "$ox" ]; then PASS=$((PASS + 1)); echo "PASS write error status"; else FAIL=$((FAIL + 1)); echo "FAIL write error status gnu=$gx ours=$ox"; fi

print_summary
[ "$FAIL" -eq 0 ]
