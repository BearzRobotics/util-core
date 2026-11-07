#!/bin/sh
# sort: differential tests against GNU sort (C locale). References: GNU manual
# "sort invocation"; POSIX.1-2024 sort. Not covered (not implemented): -R, -V,
# --debug.
UTIL="sort"
. "$(dirname "$0")/testlib.sh"

W="$(mktemp -d)"; cd "$W"
printf 'banana\napple\ncherry\ndate\nApple\nbanana\n' > words
printf '10\n9\n100\n2\n20\n-5\n-50\n0\n-0\n007\n' > nums
printf '1.5\n1.25\n-1.5\n.5\n-.5\n1.\n10.0\n1e3\n+7\n abc\n\n   12\n1,000\n' > fnums
printf '2K\n1G\n1023M\n5\n1.5K\n-3K\n0\n10k\n1T\n3P\n\nx\n0K\n-0K\n' > human
printf 'b 2\na 10\nc 1\nb 1\na 2\n' > kv
printf 'Mar\nfeb\nJAN\njanuary\nDec\nxyz\n\n  apr\nMAY x\nsep\nOct\nnov\naug\njul\njun\n' > months
printf 'b:2:x\na:10:y\nc:1:z\nb:1:w\n::\na:2\n' > colon
printf '  lead\nlead\n\tlead\n lead  two\nz\n' > blanks
printf 'a-b\na b\nab\na_b\nA1\na1\n!x\nx!\n' > punct
printf 'zeta\nalpha\x01beta\nalpha beta\nalphabeta\n' > ctrl
printf '3\n1\n2\n1\n3\n' > dup
printf 'a\nb\nc\n' > sorted
printf 'a\0c\0b\0' > nul
printf 'no newline' > nonl
printf 'x\n' > one
: > empty
printf '0x10\n0x2\n1e2\n-inf\ninf\nnan\n5\nabc\n0x1p3\n1e-2\n 3\n+5\n-0\n0\n' > gnum
printf 'ab\nAB\naB\nba\nBA\n_a\n' > cases
printf '1.5 a\n1.50 b\n1.5 c\n01.5 d\n1.4 e\n' > ties

printf "\n[ Default and ordering options ]\n"
for o in "" -r -u -ru -f -fr -fu -d -di -i -b -s -sr -su; do
    run_cmp "words $o"        $o words
    run_cmp "punct $o"        $o punct
    run_cmp "cases $o"        $o cases
    run_cmp "ctrl $o"         $o ctrl
    run_cmp "blanks $o"       $o blanks
done
run_cmp "empty"               empty
run_cmp "single"              one
run_cmp "no trailing newline" nonl
run_cmp "two files"           words kv
run_cmp "dup -u"              -u dup
run_cmp "stdin"               -
CMP_STDIN=words run_cmp "stdin default" -
CMP_STDIN=words run_cmp "stdin implicit"
CMP_STDIN=words run_cmp "stdin and file" - dup
CMP_STDIN=words run_cmp "file and stdin" dup -
CMP_STDIN=words run_cmp "-- operand" -- words

printf "\n[ Numeric -n -g -h -M ]\n"
for o in -n -nr -nu -g -gr -gu -h -hr -hu -M -Mr -Mu; do
    run_cmp "nums $o"         $o nums
    run_cmp "fnums $o"        $o fnums
    run_cmp "human $o"        $o human
    run_cmp "months $o"       $o months
    run_cmp "gnum $o"         $o gnum
done
run_cmp "-n ties stable order"    -n ties
run_cmp "-n -s ties"              -n -s ties
run_cmp "-n -u ties"              -n -u ties
run_cmp "--numeric-sort"          --numeric-sort nums
run_cmp "--general-numeric-sort"  --general-numeric-sort gnum
run_cmp "--human-numeric-sort"    --human-numeric-sort human
run_cmp "--month-sort"            --month-sort months
run_cmp "--sort=numeric"          --sort=numeric nums
run_cmp "--sort=general"          --sort=general gnum
run_cmp "--sort=human"            --sort=human human
run_cmp "--sort=month"            --sort=month months
run_cmp "--sort=n (abbrev)"       --sort=n nums
run_cmp "--sort=bad"              --sort=bad nums

printf "\n[ Keys ]\n"
for k in -k1 -k2 -k2n -k2,2n -k2,2nr -k1,1 -k1,1r -k1.2 -k1.2,1.3 -k2.1,2.1 -k3 -k1,2 -k1n,2 -k1,1 -k1b -k2b,2b -k5 -k2.5 -k1.1,1.1; do
    run_cmp "kv $k"           $k kv
    run_cmp "kv -s $k"        -s $k kv
    run_cmp "kv -u $k"        -u $k kv
    run_cmp "blanks $k"       $k blanks
done
for t in : ' ' a '\0'; do
    for k in -k1 -k2 -k2n -k2,2 -k3 -k1,2 -k2.2 -k2,3 -k1.2,2.1; do
        run_cmp "colon -t'$t' $k"   -t "$t" $k colon
    done
done
run_cmp "two keys -k1,1 -k2n"         -k1,1 -k2n kv
run_cmp "two keys -k2n -k1"           -k2n -k1 kv
run_cmp "two keys -k1,1r -k2,2n"      -k1,1r -k2,2n kv
run_cmp "three keys"                  -k1,1 -k2,2n -k1 kv
run_cmp "global -n key inherits"      -n -k2 kv
run_cmp "global -n key own letter"    -n -k2,2 -k1,1r kv
run_cmp "global -r inherited"         -r -k2n kv
run_cmp "global -r with key r"        -r -k2nr kv
run_cmp "global -b -k"                -b -k2 blanks
run_cmp "key b modifiers"             -k2b,2b blanks
run_cmp "key letters override global" -n -k1,1f kv
run_cmp "-k 2 (separate arg)"         -k 2 kv
run_cmp "--key=2n"                    --key=2n kv
run_cmp "--key 2n"                    --key 2n kv
run_cmp "--field-separator=:"         --field-separator=: -k2n colon
run_cmp "-t: -k2n,2"                  -t: -k2n,2 colon
run_cmp "-k end before start"         -k2,1 kv
run_cmp "-k2.0 end char 0"            -k2,2.0 kv
run_cmp "-k1.3 past end"              -k1.9 kv
run_cmp "key with -f"                 -k1f cases
run_cmp "key with -d"                 -k1d punct
run_cmp "key with -i"                 -k1i ctrl
run_cmp "-M key"                      -k1M months
run_cmp "-h key"                      -k1h human
run_cmp "-g key"                      -k1g gnum

printf "\n[ Key and option errors ]\n"
for k in -k0 -kx -k1.0 -k1,0 -k1.x -k1,x -k1q -k1,2q -k -k1,2,3 -k1.2.3 "-k 1n,2q" ; do
    run_cmp "error $k"        $k kv
done
run_cmp "-nd incompatible"    -nd kv
run_cmp "-gn incompatible"    -gn kv
run_cmp "-nM incompatible"    -nM kv
run_cmp "-ni incompatible"    -ni kv
run_cmp "-k1nd incompatible"  -k1nd kv
run_cmp "-t multi char"       -t ab kv
run_cmp "-t empty"            -t '' kv
run_cmp "-t twice different"  -t: -t, kv
run_cmp "-t twice same"       -t: -t: colon
run_cmp "-x"                  -x kv
run_cmp "--bogus"             --bogus kv
run_cmp "-S abc"              -S abc kv
run_cmp "-S 10"               -S 10 kv
run_cmp "-S 1M"               -S 1M kv
run_cmp "-S 10%"              -S 10% kv
run_cmp "-S b"                -S b kv
run_cmp "--parallel=0"        --parallel=0 kv
run_cmp "--parallel=2"        --parallel=2 kv
run_cmp "--parallel=x"        --parallel=x kv
run_cmp "--batch-size=1"      --batch-size=1 kv
run_cmp "--batch-size=4"      --batch-size=4 kv
run_cmp "-T /tmp"             -T /tmp kv
run_cmp "missing file"        nonexistent
run_cmp "missing among good"  words nonexistent
run_cmp "directory"           .
run_cmp "--output= no arg"    --output
run_cmp "-o bad dir"          -o /nonexistent/x words

printf "\n[ -z, -o, --files0-from ]\n"
run_cmp "-z"                  -z nul
run_cmp "-z -r"               -z -r nul
run_cmp "-z on text"          -z words
run_cmp "--zero-terminated"   --zero-terminated nul
printf 'a\nb\0a\nc\0a\nb\0' > nulnl
run_cmp "-z newlines in records" -z nulnl
run_cmp "-z -u"               -z -u nulnl
run_cmp "-z -k2 newline fields" -z -k2 nulnl
printf 'words\0kv\0' > list0
run_cmp "--files0-from"       --files0-from=list0
printf 'words\0kv' > list0b
run_cmp "--files0-from no trailing NUL" --files0-from=list0b
printf 'words\0\0kv\0' > list0c
run_cmp "--files0-from empty name" --files0-from=list0c
: > list0d
run_cmp "--files0-from empty list" --files0-from=list0d
run_cmp "--files0-from + operand" --files0-from=list0 words
run_cmp "--files0-from missing"  --files0-from=nonexistent
CMP_STDIN=list0 run_cmp "--files0-from=-" --files0-from=-

# -o: compare the written file as well as the stream output.
for o in "" -r -u -n; do
    cp words o1; cp words o2
    LC_ALL=C gnu $o -o o1 o1; ours $o -o o2 o2
    if cmp -s o1 o2; then PASS=$((PASS+1)); printf "PASS -o in place %s\n" "$o"; else FAIL=$((FAIL+1)); printf "FAIL -o in place %s\n" "$o"; fi
done
rm -f o1 o2
LC_ALL=C gnu -o g.out words kv; ours -o o.out words kv
if cmp -s g.out o.out; then PASS=$((PASS+1)); echo "PASS -o two inputs"; else FAIL=$((FAIL+1)); echo "FAIL -o two inputs"; fi
LC_ALL=C gnu --output=g2.out words; ours --output=o2.out words
if cmp -s g2.out o2.out; then PASS=$((PASS+1)); echo "PASS --output="; else FAIL=$((FAIL+1)); echo "FAIL --output="; fi
rm -f g.out o.out g2.out o2.out

printf "\n[ Check -c -C ]\n"
for f in sorted words dup nonl empty one; do
    for o in -c -C -cu -Cu -cr -cn "-c -s"; do
        run_cmp "check $o $f"  $o $f
    done
done
run_cmp "--check"                 --check words
run_cmp "--check=quiet"           --check=quiet words
run_cmp "--check=silent"          --check=silent words
run_cmp "--check=diagnose-first"  --check=diagnose-first words
run_cmp "--check=bad"             --check=bad words
run_cmp "-c two files"            -c words kv
run_cmp "-C two files"            -C sorted kv
run_cmp "-c with -k"              -c -k2n kv
run_cmp "-c -z"                   -c -z nul
CMP_STDIN=sorted run_cmp "-c stdin sorted" -c
CMP_STDIN=words run_cmp "-c stdin unsorted" -c
CMP_STDIN=words run_cmp "-c explicit -" -c -

printf "\n[ Merge -m ]\n"
printf 'a\nc\ne\n' > m1; printf 'b\nd\nf\n' > m2; printf 'a\nb\nz\n' > m3
printf 'c\na\nb\n' > mu1; printf 'z\ny\nx\n' > mu2
printf '1\n3\n5\n' > n1; printf '2\n4\n10\n' > n2
for o in "" -u -r -s -n "-n -u" -c; do
    run_cmp "merge $o m1 m2"       -m $o m1 m2
    run_cmp "merge $o m1 m2 m3"    -m $o m1 m2 m3
    run_cmp "merge $o m3 m1 m2"    -m $o m3 m1 m2
done
run_cmp "merge n1 n2 -n"          -m -n n1 n2
run_cmp "merge n1 n2 lexical"     -m n1 n2
run_cmp "merge unsorted inputs"   -m mu1 mu2
run_cmp "merge unsorted -u"       -m -u mu1 mu2
run_cmp "merge single"            -m m1
run_cmp "merge with empty"        -m m1 empty m2
run_cmp "merge ties -s"           -m -s -k1,1 kv kv
run_cmp "merge ties keys"         -m -k1,1 m1 m3
run_cmp "--merge"                 --merge m1 m2
run_cmp "merge -z"                -m -z nul nul
CMP_STDIN=m2 run_cmp "merge stdin" -m m1 -

printf "\n[ -n prefix edge cases ]\n"
# Numbers around the 15-digit exactness limit, equal values written
# differently, signs, and near-equal long decimals.
printf '%s\n' 123456789012345 123456789012346 1234567890123456 1234567890123457 \
    1234567890123456789 1234567890123456788 0.123456789012345 0.1234567890123450 \
    0.12345678901234500001 0.123456789012346 -123456789012345 -123456789012346 \
    -1234567890123456 -1234567890123457 999999999999999 1000000000000000 \
    0.000000000000001 0.0000000000000001 1e5 100000 0.1 0.10 .1 00.1 -0.1 -.1 \
    -0 0 +0 3 03 3.0 3.00 3.000000000000001 3.0000000000000001 > bign
for o in -n -nr -nu -ns -k1n "-k1,1n -k1" "-k1,1nr -k1"; do
    run_cmp "bign $o"        $o bign
done
awk 'BEGIN { srand(7); for (i = 0; i < 3000; i++) {
    n = int(rand() * 4); s = (rand() < 0.4) ? "-" : ""
    d = 1 + int(rand() * 20); x = ""
    for (j = 0; j < d; j++) x = x int(rand() * (rand() < 0.5 ? 3 : 10))
    if (rand() < 0.5) { p = int(rand() * d); x = substr(x, 1, p) "." substr(x, p + 1) }
    print s x (n == 0 ? " tail" i : "") } }' > bigrnd
for o in -n -nr -nu -ns "-k1,1n -k1,1" "-nk1,1 -k2"; do
    run_cmp "bigrnd $o"      $o bigrnd
done

printf "\n[ Randomised differential runs ]\n"
# Deterministic pseudo-random inputs: lines of 1-4 fields drawn from a small
# vocabulary so that ties, blanks, signs, units and months all occur often.
gen() {
    awk -v seed="$1" -v n="$2" 'BEGIN {
        srand(seed)
        split("a b B apple Apple 10 9 -3 0 -0 1.5 .5 2K 1G 5M x Jan feb DEC 007 _ -", v, " ")
        nv = 24
        sepc[1] = " "; sepc[2] = "  "; sepc[3] = "\t"; sepc[4] = ":"; sepc[5] = ","
        for (i = 0; i < n; i++) {
            nf = 1 + int(rand() * 4); line = ""
            if (rand() < 0.2) line = " "
            for (f = 0; f < nf; f++) {
                line = line v[1 + int(rand() * nv)]
                if (f < nf - 1) line = line sepc[1 + int(rand() * 5)]
            }
            print line
        }
    }'
}
r=0
while [ $r -lt 12 ]; do
    gen $r 60 > rnd
    for o in "" -r -u -s -n -nr -g -h -M -f -d -i -b "-k2" "-k2,2" "-k2n" "-k1,1 -k2n" "-k2,3r" "-k1.2,1.3" "-k2b,2" "-t: -k2" "-t: -k2n" "-t, -k1,2" "-nk2" "-n -k1 -k2" "-fk1,1 -k2n" "-ur -k2,2" "-su -k1,1" "-hr" "-Mk1" "-gk2" "-bk2n" "-dk2" "-ik1"; do
        eval run_cmp \"rnd\$r \$o\" $o rnd
    done
    TAB="$(printf '\t')"
    run_cmp "rnd$r -t TAB -k2"   -t "$TAB" -k2 rnd
    run_cmp "rnd$r -t TAB -k2n,2 -k1" -t "$TAB" -k2n,2 -k1 rnd
    r=$((r+1))
done
print_summary
