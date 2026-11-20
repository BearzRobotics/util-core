#!/bin/sh
# sdiff: differential tests against GNU sdiff 3.12 (C locale). References: GNU
# diffutils manual "Interactive Merging with sdiff".
# NPAIRS (default 60) sets how many generated pairs are run.
UTIL="sdiff"
. "$(dirname "$0")/testlib.sh"
. "$(dirname "$0")/difflib.sh"
[ -n "$DIFF_BIN_DIR" ] && BIN_DIR="$DIFF_BIN_DIR"

W="$(mktemp -d)"; cd "$W"
printf 'a\nb\nc\nd\ne\n' > i1; printf 'a\nX\nc\nf\ne\ng\n' > i2
printf '1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n' > o; printf '1\n2\nx\n4\n5\n6\n7\n8\n9\n10\ny\nz\n12\n' > n
printf 'a\tb\nlonglonglonglonglonglong\n' > t1; printf 'a\tc\nlonglonglonglonglongXXXXXXXXXX\n' > t2
printf 'a  b\nc d\n' > w1; printf 'a b\nc   d\n' > w2
printf 'Hello\nWORLD\n' > c1; printf 'hello\nworld\n' > c2
printf 'a\n\nb\n\n' > s1; printf 'a\n\nc\nd\n\n' > s3
printf 'a\nb' > m1; printf 'a\nc' > m2
: > empty

printf "\n[ Listing ]\n"
for p in i1,i2 o,n t1,t2 w1,w2 c1,c2 s1,s3 m1,m2 empty,o o,empty empty,empty i1,i1 o,o; do
    a=${p%,*}; b=${p#*,}
    for f in "" -s -l "-s -l" -t "-w 40" "-w 20" "-w 31" "-w 130 -t" "-w 5" "-i" "-b" "-W" "-E" "-Z" "-B" "-d" "-H" "--tabsize=4" "--tabsize=4 -w 50" "--width=60" "--left-column" "--suppress-common-lines" "--ignore-case" "--strip-trailing-cr" "-a" "-I 1" "-I '^a'" "--expand-tabs --tabsize=3 -w 41"; do
        eval run_cmp \"sdiff $f $a $b\" $f $a $b
    done
done

printf "\n[ Option handling and errors ]\n"
for args in "i1" "" "i1 i2 o" "-x i1 i2" "-w 0 i1 i2" "-w x i1 i2" "--tabsize=0 i1 i2" "--tabsize=x i1 i2" "nonex i2" "i1 nonex" "--bogus" "--diff-program=nonexist i1 i2"; do
    eval run_cmp \"sdiff $args\" $args
done
CMP_STDIN="$W/i1"
run_cmp "stdin first" - i2
run_cmp "stdin second" i2 -
unset CMP_STDIN

printf "\n[ Interactive merge (-o) ]\n"
SETUP="printf 'a\nb\nc\nd\ne\n' > i1; printf 'a\nX\nc\nf\ne\ng\n' > i2; printf '1\n2\n3\n' > p; printf '1\n9\n3\n' > q"
mkans() { printf "$1" > "$W/ans"; TREE_STDIN="$W/ans"; TREE_CONTENT=1; export TREE_CONTENT; }
for ans in 'l\nl\nl\n' 'r\nr\nr\n' 'l\nr\nl\n' 'r\nl\nr\n' 'q\n' 'l\nq\n' 'x\nl\nl\nl\n' 's\nl\nl\nr\n' 'v\nl\nl\nl\n' '  l\nl\nl\n' 'll\nl\nl\nl\n' '1\n2\n1\n' 'l\n' '' 's\nv\nl\nr\nl\n' 'l\n\nr\nl\n' 'S\nl\nl\nl\n' 'L\nl\nl\nl\n'; do
    mkans "$ans"
    run_tree "sdiff -o answers [$(printf "$ans" | tr '\n' ' ')]" "$SETUP" -o out i1 i2
    run_tree "sdiff -o -s answers [$(printf "$ans" | tr '\n' ' ')]" "$SETUP" -s -o out i1 i2
done
mkans 'l\n'
run_tree "sdiff -o identical" "$SETUP" -o out i1 i1
run_tree "sdiff -o one hunk" "$SETUP" -o out p q
mkans 'r\n'
run_tree "sdiff -o one hunk right" "$SETUP" -o out p q
mkans 'el\n'
EDSETUP="$SETUP; printf '#!/bin/sh\nsed s/^/E:/ \"\$1\" > \"\$1.n\" && mv \"\$1.n\" \"\$1\"\n' > ed.sh; chmod +x ed.sh"
for e in el er eb e ed e1 e2; do
    mkans "$e\nl\nl\nl\n"
    EDITOR="$W/edit.sh"
    printf '#!/bin/sh\nsed s/^/E:/ "$1" > "$1.n" && mv "$1.n" "$1"\n' > "$W/edit.sh"; chmod +x "$W/edit.sh"
    export EDITOR
    run_tree "sdiff -o EDITOR $e" "$SETUP" -o out i1 i2
    unset EDITOR
done
unset TREE_STDIN TREE_CONTENT

printf "\n[ Help ]\n"
help_cmp_diffutils

printf "\n[ Generated pairs ]\n"
NPAIRS="${NPAIRS:-60}"
START=$PASS; F0=$FAIL
i=0
while [ $i -lt "$NPAIRS" ]; do
    i=$((i + 1))
    awk -v seed=$i 'BEGIN { srand(seed); n = int(rand() * 40); pe = 0.05 + rand() * 0.25;
        for (k = 0; k < n; k++) a[k] = "line" int(rand() * 6) (rand() < 0.1 ? "\twith tab" : "");
        m = 0;
        for (k = 0; k < n; k++) { r = rand(); if (r < pe / 3) continue; if (r < 2 * pe / 3) b[m++] = "new" int(rand() * 4); if (r < pe) { b[m++] = "chg" int(rand() * 4); continue; } b[m++] = a[k]; }
        for (k = 0; k < n; k++) printf "%s\n", a[k] > "g1";
        for (k = 0; k < m; k++) printf "%s\n", b[k] > "g2"; close("g1"); close("g2") }'
    [ -f g1 ] || : > g1
    [ -f g2 ] || : > g2
    for f in "" -s -l -t "-w 60" "-w 41 -l" "-b" "-i" "-B"; do
        run_cmp "gen $i sdiff $f" $f g1 g2
    done
    rm -f g1 g2
done
GENPASS=$((PASS - START)); GENFAILS=$((FAIL - F0))
printf "\nGenerated pairs: %d/%d agree with GNU sdiff\n" "$GENPASS" "$((GENPASS + GENFAILS))"

print_summary
[ "$FAIL" -eq 0 ]
