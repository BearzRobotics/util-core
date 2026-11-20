#!/bin/sh
# diff3: differential tests against GNU diff3 3.12 (C locale). References: GNU
# diffutils manual "Comparing Three Files" and "Merging".
# NTRIPLES (default 120) sets how many generated triples are run.
UTIL="diff3"
. "$(dirname "$0")/testlib.sh"
. "$(dirname "$0")/difflib.sh"
[ -n "$DIFF_BIN_DIR" ] && BIN_DIR="$DIFF_BIN_DIR"

W="$(mktemp -d)"; cd "$W"
printf 'a\nM\nc\nd\ne\nf\nmm\n' > mine; printf 'a\nb\nc\nd\ne\nf\n' > old; printf 'a\nb\nc\nY\ne\nf\n' > your
printf 'a\nM\nc\nd\nZ\nf\n' > mine2; printf 'a\nQ\nc\nd\nZ\nf\n' > your2
printf 'a\nM\nc\n' > xm; printf 'a\nb\nc\n' > xo; printf 'a\nQ\nc\n' > xy
printf 'a\nc\n' > xm3; printf 'a\nb\nI\nc\n' > xy4; printf 'a\nQ\nc\n' > xm2
printf 'a\nb' > nn1
printf 'x\n.\ny\n' > dot1; printf 'x\ny\n' > dot0; printf 'x\n.\n.\ny\n' > dot2
: > empty
TRIPLES="mine,old,your mine2,old,your2 xm,xo,xy xm2,xo,xy xm3,xo,xy xm,xo,xy4 xo,xo,xy4 xm,xo,xo xo,xo,xo mine,mine,mine nn1,old,your dot1,dot0,dot2 dot0,dot0,dot1 dot1,dot0,dot0 empty,empty,xo xo,empty,empty empty,xo,empty xo,xo,empty"
for t in $TRIPLES; do
    a=${t%%,*}; rest=${t#*,}; b=${rest%,*}; c=${rest#*,}
    for f in "" -e -E -3 -x -X -A -m "-m -E" "-m -A" "-m -3" "-m -x" "-m -e" "-e -i" "-E -i" "-A -i" "-3 -i" "-i" -T "-L X -L Y -L Z" "-m -L X -L Y -L Z" "-E -L X -L Y -L Z" "-A -L X -L Y -L Z" -a --strip-trailing-cr; do
        run_cmp "diff3 $f $a $b $c" $f $a $b $c
    done
done

printf "\n[ Option handling and errors ]\n"
for args in "mine old" "mine old your x" "-L a -L b -L c -L d mine old your" "-L a mine old your" "-L a -L b mine old your" "-e -m mine old your" "-E -x mine old your" "-3 -x mine old your" "-e -3 mine old your" "-A -x mine old your" "-X -E mine old your" "-x -e mine2 old your2" "-m -i mine old your" "nonex old your" "mine nonex your" "mine old nonex" "--bogus" "-e -e mine old your" "--ed mine old your" "--show-all mine old your" "--show-overlap mine old your" "--easy-only mine old your" "--overlap-only mine old your" "--merge mine2 old your2" "--initial-tab mine old your" "--label=a --label=b --label=c mine old your" "--text mine old your"; do
    run_cmp "diff3 $args" $args
done
printf '#!/bin/sh\nexec /usr/bin/diff "$@"\n' > wrapdiff; chmod +x wrapdiff
printf 'echo garbage\n' > badprog; chmod +x badprog
printf '#!/bin/sh\necho "x"\n' > badprog2; chmod +x badprog2
printf '#!/bin/sh\nexit 2\n' > failprog; chmod +x failprog
printf '#!/bin/sh\nexit 1\n' > quietprog; chmod +x quietprog
for args in "--diff-program=./wrapdiff mine old your" "--diff-program=./wrapdiff -e mine old your" "--diff-program=./wrapdiff -m mine2 old your2" "--diff-program=./wrapdiff -A mine2 old your2" "--diff-program=./wrapdiff -a mine old your" "--diff-program=./wrapdiff --strip-trailing-cr -E mine old your" "--diff-program=/usr/bin/diff -x mine old your" "--diff-program=./nonexistent mine old your" "--diff-program=./failprog mine old your" "--diff-program=./quietprog mine old your" "--diff-program=./badprog mine old your" "--diff-program=./badprog2 mine old your" "--diff-program=diff mine old your"; do
    run_cmp "diff3 $args" $args
done
CMP_STDIN="$W/old"
run_cmp "stdin as middle" mine - your
CMP_STDIN="$W/mine"
run_cmp "stdin as first" - old your
unset CMP_STDIN

printf "\n[ Help ]\n"
help_cmp_diffutils

printf "\n[ Generated triples ]\n"
NTRIPLES="${NTRIPLES:-120}"
START=$PASS; F0=$FAIL
i=0
while [ $i -lt "$NTRIPLES" ]; do
    i=$((i + 1))
    awk -v seed=$i 'BEGIN { srand(seed);
        n = 3 + int(rand() * 30);
        for (k = 0; k < n; k++) o[k] = "line" k;
        pe = 0.03 + rand() * 0.15;
        for (f = 0; f < 2; f++) {
            m = 0;
            for (k = 0; k < n; k++) {
                r = rand();
                if (r < pe / 3) continue;
                if (r < 2 * pe / 3) { x[m++] = (f ? "ins" : "INS") int(rand() * 3); }
                if (r < pe) { x[m++] = (rand() < 0.4 ? "shared" : (f ? "yy" : "mm")) int(rand() * 3); continue; }
                x[m++] = o[k];
            }
            fn = f ? "t3" : "t1";
            for (k = 0; k < m; k++) printf "%s\n", x[k] > fn;
            close(fn);
        }
        for (k = 0; k < n; k++) printf "%s\n", o[k] > "t2" }'
    for f in "" -e -E -3 -x -A -m "-m -E" "-e -i"; do
        run_cmp "gen $i diff3 $f" $f t1 t2 t3
    done
    rm -f t1 t2 t3
done
GENPASS=$((PASS - START)); GENFAILS=$((FAIL - F0))
printf "\nGenerated triples: %d/%d agree with GNU diff3\n" "$GENPASS" "$((GENPASS + GENFAILS))"

print_summary
[ "$FAIL" -eq 0 ]
