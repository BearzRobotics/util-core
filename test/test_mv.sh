#!/bin/sh
# mv: differential tests against GNU mv 9.7 (C locale). References: GNU manual
# "mv invocation", POSIX mv. Each case runs in two fresh directories.
UTIL="mv"
. "$(dirname "$0")/testlib.sh"
help_cmp
export TREE_CONTENT=1
SETUP='mkdir -p d/sub e dd; printf "one\n" > a; printf "two\n" > b; printf x > d/f; printf y > d/sub/g; ln -s a l; ln -s nowhere dang; ln -s d dl; ln a hard; mkfifo ff; : > empty; chmod 640 b; mkdir ro; printf z > ro/r; chmod 444 ro/r; chmod 555 ro; touch -d 2001-01-01 old'

# run_tree_t: every file gets the same timestamp first so that only the times
# set by the command are compared.
run_tree_t() {
    d="$1"; su="$2"; shift 2
    extra="${su#"$SETUP"}"
    run_tree "$d" "$SETUP; find . -exec touch -h -d '2000-01-01 00:00:00' {} +$extra" "$@"
}

for args in "a z" "a b" "a empty" "a nosuch/z" "nosuch z" "a a" "a hard" "hard a" "l z" "dang z" "a e" "a d" "a e/" "a b e" "a b z" "a b nosuch" "empty z" "b z" "a d/f" "ro/r z" "ro z" "ro e" "l l2" "a l" "l a" "a dl" "a dl/" "d z" "d e" "d d/sub" "d d" "d d/" "d/ z" "d/ e" "dl z" "dl e" "ff z" "ff e" "dd z" "dd e" "e dd" "e e" "old z" "a ." "d/f ." "e/. z" "z/ a"; do
    run_tree "mv $args" "$SETUP" $args
    run_tree "mv -v $args" "$SETUP" -v $args
    run_tree "mv -f $args" "$SETUP" -f $args
    run_tree "mv -n $args" "$SETUP" -n $args
done
TREE_TIMES=1 run_tree_t "mv times" "$SETUP" old z
TREE_TIMES=1 run_tree_t "mv dir times" "$SETUP; touch -d 2001-01-01 d" d z
run_tree "mv unwritable dst" "$SETUP; chmod 444 b" a b
run_tree "mv -f unwritable dst" "$SETUP; chmod 444 b" -f a b
run_tree "mv into ro dir" "$SETUP" a ro
run_tree "mv from ro dir" "$SETUP" ro/r z
run_tree "mv -T" "$SETUP" -T a z
run_tree "mv -T dir" "$SETUP" -T a e
run_tree "mv -T dirs" "$SETUP" -T d e
run_tree "mv -T extra" "$SETUP" -T a b z
run_tree "mv -t" "$SETUP" -t e a b
run_tree "mv -t missing" "$SETUP" -t nosuch a
run_tree "mv -t file" "$SETUP" -t a b
run_tree "mv -t -T" "$SETUP" -t e -T a
run_tree "mv -t twice" "$SETUP" -t e -t e a
run_tree "mv -t same" "$SETUP" -t e e
run_tree "mv -t trailing slash" "$SETUP" -t e/ a
run_tree "mv strip" "$SETUP" --strip-trailing-slashes d/ z
run_tree "mv strip 2" "$SETUP" --strip-trailing-slashes d/ e
run_tree "mv no operand" ""
run_tree "mv one operand" "$SETUP" a
run_tree "mv three to file" "$SETUP" a b empty
run_tree "mv dup source" "$SETUP" a a e
run_tree "mv hard pair" "$SETUP" a hard e
run_tree "mv same dest" "$SETUP" a d/f e
run_tree "mv same base" "$SETUP; echo q > e/b" a d/f e
run_tree "mv just-created" "$SETUP; mkdir x; echo q > x/a" a x/a e
run_tree "mv just-created -b" "$SETUP; mkdir x; echo q > x/a" -b a x/a e
run_tree "mv just-created numbered" "$SETUP; mkdir x; echo q > x/a" --backup=numbered a x/a e

for o in -b "--backup" "--backup=none" "--backup=simple" "--backup=existing" "--backup=numbered" "--backup=t" "--backup=bogus" "-b -S .bak" "-S .bak" "--suffix=.orig" "-bv" "-bf" "-bi" "-bn" "-bu"; do
    run_tree "mv $o" "$SETUP" $o a b
    run_tree "mv $o twice" "$SETUP; cp a b~; cp a b.~1~" $o a b
    run_tree "mv $o dir" "$SETUP; cp a e/a" $o a e
    run_tree "mv $o dirs" "$SETUP; mkdir z; echo q > z/q" $o d z
    run_tree "mv $o same" "$SETUP" $o a a
    run_tree "mv $o hard" "$SETUP" $o a hard
done
for u in all none none-fail older bogus; do
    run_tree "mv --update=$u" "$SETUP; touch -d 2001-01-01 b" --update=$u a b
    run_tree "mv --update=$u newer" "$SETUP; touch -d 2001-01-01 a" --update=$u a b
    run_tree "mv --update=$u -v" "$SETUP; touch -d 2001-01-01 b" -v --update=$u a b
    run_tree "mv --update=$u new" "$SETUP" --update=$u a z
done
run_tree "mv -u" "$SETUP; touch -d 2001-01-01 b" -u a b
run_tree "mv -u older" "$SETUP; touch -d 2001-01-01 a" -u a b
run_tree "mv -n -i" "$SETUP" -n -i a b
run_tree "mv -i -n" "$SETUP" -i -n a b
run_tree "mv -f -i" "$SETUP" -f -i a b
run_tree "mv -i -f" "$SETUP" -i -f a b
printf 'y\n' > "$TEST_TMP/yes"; printf 'n\n' > "$TEST_TMP/no"; printf '\n' > "$TEST_TMP/nl"
for r in yes no nl; do
    TREE_STDIN="$TEST_TMP/$r" run_tree "mv -i answer $r" "$SETUP" -i a b
    TREE_STDIN="$TEST_TMP/$r" run_tree "mv -i answer $r unwritable" "$SETUP; chmod 444 b" -i a b
    TREE_STDIN="$TEST_TMP/$r" run_tree "mv -i answer $r dir" "$SETUP; echo q > e/a" -i a e
    TREE_STDIN="$TEST_TMP/$r" run_tree "mv -i answer $r multi" "$SETUP; echo q > e/a; echo q > e/b" -i a b e
done
run_tree "mv unwritable no tty" "$SETUP; chmod 444 b" a b
run_tree "mv --debug" "$SETUP" --debug a z
run_tree "mv --debug existing" "$SETUP" --debug a b
run_tree "mv --debug -n" "$SETUP" --debug -n a b
run_tree "mv --no-copy" "$SETUP" --no-copy a z
run_tree "mv --no-copy dir" "$SETUP" --no-copy d z
run_tree "mv bad option" "$SETUP" -z a b
run_tree "mv bad long option" "$SETUP" --bogus a b
run_tree "mv -- " "$SETUP" -- -a z
run_tree "mv file named -" "$SETUP; echo q > ./-x" -- -x z
run_tree "mv empty name" "$SETUP" "" z
run_tree "mv to empty name" "$SETUP" a ""
run_tree "mv long name" "$SETUP" a "$(printf 'n%.0s' $(seq 300))"
run_tree "mv -Z" "$SETUP" -Z a z
run_tree "mv symlink dest dir" "$SETUP; ln -s e z" a z
run_tree "mv symlink dest dir/" "$SETUP; ln -s e z" a z/
run_tree "mv symlink to symlink" "$SETUP; ln -s q z" l z
run_tree "mv onto symlink" "$SETUP; ln -s a z" b z
run_tree "mv hardlinks both" "$SETUP; ln a h2" hard h2
run_tree "mv hardlink onto same file" "$SETUP; ln a h2" hard a
run_tree "mv symlink onto referent" "$SETUP" l a
run_tree "mv symlink onto hardlink" "$SETUP; ln a h2; ln -s a s2" s2 h2
run_tree "mv dir with hardlinks" "$SETUP; ln d/f d/f2" d z
cd /; print_summary
