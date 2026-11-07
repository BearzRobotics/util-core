#!/bin/sh
# join: differential tests against GNU join 9.7 (C locale). References: GNU
# manual "join invocation"; POSIX.1-2024 join.
UTIL="join"
. "$(dirname "$0")/testlib.sh"
W="$(mktemp -d)"; cd "$W"
printf 'a 1\nb 2\nc 3\nd 4\n' > f1
printf 'a x\nc y\ne z\n' > f2
printf 'a 1\na 2\nb 3\n' > d1
printf 'a x\na y\nb z\n' > d2
printf 'b 2\na 1\n' > u1
printf 'a x\nb y\n' > u2
printf 'b 1\na 2\nz 3\n' > v1
printf 'a q\nz r\nzz s\n' > v2
printf 'k v\na 1\nb 2\n' > h1
printf 'k w\na x\nb y\n' > h2
printf 'A 1\nb 2\nC 3\n' > c1
printf 'a x\nB y\nc z\n' > c2
printf 'a,1,x\nb,2,y\nc,3,z\n' > t1
printf 'a,p\nc,q\nd,r\n' > t2
printf '  a   1\n b\t2\n' > ws1
printf 'a x\nb y\n' > ws2
printf '' > empty
printf 'a\0b\0c\0' > z1
printf 'a\0c\0' > z2
printf 'x a 1\ny b 2\nz c 3\n' > k1
printf '1 a\n2 b\n3 d\n' > k2

printf "\n[ Basic joins ]\n"
run_cmp "default"                 f1 f2
run_cmp "-a1"                     -a1 f1 f2
run_cmp "-a2"                     -a2 f1 f2
run_cmp "-a1 -a2"                 -a1 -a2 f1 f2
run_cmp "-v1"                     -v1 f1 f2
run_cmp "-v2"                     -v2 f1 f2
run_cmp "-v1 -v2"                 -v1 -v2 f1 f2
run_cmp "-a1 -v2"                 -a1 -v2 f1 f2
run_cmp "-a 1 separate arg"       -a 1 f1 f2
run_cmp "duplicates cross product" d1 d2
run_cmp "empty first"             empty f2
run_cmp "empty second"            f1 empty
run_cmp "both empty"              empty empty
run_cmp "-a1 empty second"        -a1 f1 empty
run_cmp "-a2 empty first"         -a2 empty f2
run_cmp "same file"               f1 f1
CMP_STDIN=f2 run_cmp "stdin second" f1 -
CMP_STDIN=f1 run_cmp "stdin first"  - f2
run_cmp "both stdin"              - -
run_cmp "-- operands"             -- f1 f2

printf "\n[ Fields and output formats ]\n"
run_cmp "-1 2 -2 1"               -1 2 -2 1 k1 k2
run_cmp "-j 2 same"               -j 2 f1 f1
run_cmp "-j1 2 obsolete"          -j1 2 -j2 1 k1 k2
run_cmp "-1 3 -2 2"               -1 2 -2 2 k1 k2
run_cmp "-o 0,1.2,2.2"            -o 0,1.2,2.2 f1 f2
run_cmp "-o 1.1,2.1"              -o 1.1,2.1 f1 f2
run_cmp "-o with spaces"          -o '1.2 2.2' f1 f2
run_cmp "-o 2.2,0,1.2"            -o 2.2,0,1.2 f1 f2
run_cmp "-o missing field no -e"  -o 1.5,2.2 f1 f2
run_cmp "-o missing field -e"     -o 1.5,2.2 -e NONE f1 f2
run_cmp "-e alone"                -e X -a1 f1 f2
run_cmp "-e with -a1 -a2 -o"      -a1 -a2 -o 0,1.2,2.2 -e MISSING f1 f2
run_cmp "-o auto"                 -o auto f1 f2
run_cmp "-o auto -a1 -e"          -o auto -a1 -e X f1 f2
run_cmp "-o auto -a2 -e"          -o auto -a2 -e X f1 f2
run_cmp "-o auto uneven"          -o auto -a1 -a2 -e - k1 k2
run_cmp "-o bad"                  -o 3.1 f1 f2
run_cmp "-o 1.0"                  -o 1.0 f1 f2
run_cmp "-o x"                    -o x f1 f2
run_cmp "-v1 -o"                  -v1 -o 0,1.2,2.2 -e Z f1 f2
run_cmp "whitespace fields"       ws1 ws2
run_cmp "-t ,"                    -t, t1 t2
run_cmp "-t, -a1"                 -t, -a1 t1 t2
run_cmp "-t, -o"                  -t, -o 0,1.3,2.2 t1 t2
run_cmp "-t, -j 2"                -t, -j 2 t1 t1
run_cmp "-t ''"                   -t '' f1 f2
run_cmp "-t 'x' multi-char"       -t xy f1 f2
run_cmp "-t '\\0'"                -t '\0' f1 f2
run_cmp "-i"                      -i c1 c2
run_cmp "--ignore-case"           --ignore-case c1 c2
run_cmp "no -i, case differs"     c1 c2
run_cmp "-z"                      -z z1 z2
run_cmp "-z -a1"                  -z -a1 z1 z2
run_cmp "--zero-terminated"       --zero-terminated z1 z2

printf "\n[ Header ]\n"
run_cmp "--header"                --header h1 h2
run_cmp "--header -a1"            --header -a1 h1 h2
run_cmp "--header -o"             --header -o 0,1.2,2.2 h1 h2
run_cmp "--header empty"          --header empty h2
run_cmp "--header both empty"     --header empty empty
run_cmp "--header -v1"            --header -v1 h1 h2

printf "\n[ Order checking ]\n"
run_cmp "unsorted default"        u1 u2
run_cmp "unsorted --check-order"  --check-order u1 u2
run_cmp "unsorted --nocheck-order" --nocheck-order u1 u2
run_cmp "unsorted with unpairable" v1 v2
run_cmp "unsorted -a1"            -a1 v1 v2
run_cmp "unsorted --check-order v" --check-order v1 v2
run_cmp "unsorted --nocheck v"    --nocheck-order v1 v2
run_cmp "unsorted second file"    f1 u1
run_cmp "unsorted both"           u1 v1
run_cmp "sorted --check-order"    --check-order f1 f2
run_cmp "unsorted -v1"            -v1 u1 u2

printf "\n[ When disorder is reported (tiny inputs) ]\n"
tiny() { # file1-content file2-content [options]
    printf "$1" > t_a; printf "$2" > t_b
    d="$(printf "$1" | tr '\n' ',') | $(printf "$2" | tr '\n' ',')"; shift 2
    run_cmp "tiny $d $*" "$@" t_a t_b
}
for pair in 'b\na\n|z\n' 'b\na\n|a\n' 'a\nb\na\n|c\n' 'c\nb\na\n|a\nb\nc\n' 'b\na\n|b\nz\n' 'b\nc\na\n|b\nc\nz\n' \
            'a\nc\nb\n|a\nb\nc\n' 'a\nc\nb\n|x\n' 'x\n|a\nc\nb\n' 'a\nc\nb\n|a\nc\nb\n' 'a\nb\nb\na\n|a\nb\n' 'm\nb\n|a\nb\nc\n' \
            'b\na\nc\n|a\nc\n' 'a\na\nb\nb\n|a\nb\nb\n' 'a\n|' '|a\n' 'b\na\n|' 'a\nb\n|b\na\n' 'b\na\n|b\na\n' 'a\nz\ny\n|a\ny\nz\n'; do
    for o in "" "-a1" "-a2" "-v1" "--check-order" "--nocheck-order"; do
        tiny "${pair%%|*}" "${pair#*|}" $o
    done
done
printf "\n[ Errors ]\n"
run_cmp "no operands"
run_cmp "one operand"             f1
run_cmp "three operands"          f1 f2 f1
run_cmp "missing file 1"          nofile f2
run_cmp "missing file 2"          f1 nofile
run_cmp "directory"               . f2
run_cmp "-j 0"                    -j 0 f1 f2
run_cmp "-1 x"                    -1 x f1 f2
run_cmp "-2 0"                    -2 0 f1 f2
run_cmp "-a 3"                    -a 3 f1 f2
run_cmp "-v 0"                    -v 0 f1 f2
run_cmp "unknown option"          -x f1 f2
run_cmp "--bogus"                 --bogus f1 f2
run_cmp "-t missing arg"          f1 f2 -t
run_cmp "-o missing arg"          f1 f2 -o

printf "\n[ Randomised ]\n"
# Seeded sorted inputs with duplicates and unpairable lines; both tools are
# fed the same files and every option mix is compared.
gen() { # seed lines keyrange
    awk -v seed="$1" -v n="$2" -v kr="$3" 'BEGIN { srand(seed)
        for (i = 0; i < n; i++) printf "k%03d v%d w%d\n", int(rand() * kr), i, int(rand() * 100) }' | LC_ALL=C /usr/bin/sort -k1,1 -s
}
r=0
while [ $r -lt 12 ]; do
    gen $r 40 25 > ra; gen $((r + 100)) 35 25 > rb
    for o in "" "-a1" "-a2" "-a1 -a2" "-v1" "-v2" "-v1 -v2" "-o 0,1.2,2.3" "-a1 -a2 -e E -o 0,1.2,2.2" "-1 2 -2 2" "-i" "-o auto -a1 -a2 -e -" "-j 1 -a2" "--check-order"; do
        eval run_cmp \"random $r $o\" $o ra rb
    done
    r=$((r + 1))
done
rm -rf "$W"
print_summary
