#!/bin/sh
# cp: differential tests against GNU cp 9.7 (C locale). References: GNU manual
# "cp invocation", POSIX cp. Each case runs in two fresh directories.
UTIL="cp"
. "$(dirname "$0")/testlib.sh"
help_cmp
export TREE_CONTENT=1
SETUP='mkdir -p d/sub e; printf "one\n" > a; printf "two\n" > b; printf x > d/f; printf y > d/sub/g; ln -s a l; ln -s nowhere dang; ln -s d dl; ln a hard; mkfifo ff; : > empty; chmod 640 b; chmod 755 d; mkdir ro; printf z > ro/r; chmod 444 ro/r; chmod 555 ro; printf s > sp; truncate -s 100000 sp2; printf q >> sp2'

# run_tree_t: like run_tree, but every file gets the same timestamp first so
# that only the times set by cp are compared.
run_tree_t() {
    d="$1"; su="$2"; shift 2
    extra="${su#"$SETUP"}"
    run_tree "$d" "$SETUP; find . -exec touch -h -d '2000-01-01 00:00:00' {} +$extra" "$@"
}
printf "\n[ Basic file copies ]\n"
for args in "a z" "a b" "a empty" "a nosuch/z" "nosuch z" "a a" "a hard" "hard a" "l z" "dang z" "a e" "a d" "a e/" "a b e" "a b z" "a b nosuch" "a b a" "empty z" "b z" "a d/f" "ro/r z" "ro/r ro/r2" "a ro/z" "sp2 z" "l l2" "a l" "l a" "a dl" "a dl/" "d z" "dl z" "a dang"; do
    run_tree "cp $args" "$SETUP" $args
    run_tree "cp -v $args" "$SETUP" -v $args
    run_tree "cp -p $args" "$SETUP" -p $args
done
run_tree "cp -f unwritable" "$SETUP; chmod 444 b" -f a b
run_tree "cp unwritable" "$SETUP; chmod 444 b" a b
run_tree "cp -f unwritable dir" "$SETUP; chmod 555 e" -f a e
run_tree "cp into unwritable" "$SETUP; chmod 555 e" a e
run_tree "cp --remove-destination" "$SETUP; chmod 444 b" --remove-destination a b
run_tree "cp --remove-destination symlink" "$SETUP; ln -s a z" --remove-destination b z
run_tree "cp through symlink" "$SETUP; ln -s b z" a z
run_tree "cp through dangling" "$SETUP; ln -s nonex z" a z
run_tree "cp through dangling POSIXLY_CORRECT" "$SETUP; ln -s nonex z" a z
run_tree "cp -T" "$SETUP" -T a z
run_tree "cp -T dir" "$SETUP" -T a e
run_tree "cp -T extra" "$SETUP" -T a b z
run_tree "cp -t" "$SETUP" -t e a b
run_tree "cp -t missing" "$SETUP" -t nosuch a
run_tree "cp -t file" "$SETUP" -t a b
run_tree "cp -t -T" "$SETUP" -t e -T a
run_tree "cp -t twice" "$SETUP" -t e -t e a
run_tree "cp -t one dir" "$SETUP" -t e e
run_tree "cp -T trailing slash" "$SETUP" -T a z/
run_tree "cp trailing slash src" "$SETUP" a/ z
run_tree "cp --strip" "$SETUP" --strip-trailing-slashes a/ z
run_tree "cp no operand" ""
run_tree "cp one operand" "$SETUP" a
run_tree "cp dir no -r" "$SETUP" d z
run_tree "cp dir dir -r" "$SETUP" -r d e
run_tree "cp dot dir" "$SETUP" -r d/. e
run_tree "cp dotdot" "$SETUP" a ..
run_tree "cp . e" "$SETUP" a e/.

printf "\n[ Recursive ]\n"
for o in "-r" "-R" "-rv" "-rp" "-ra" "-a" "-rL" "-rH" "-rP" "-rd" "-rl" "-rs" "-rn" "-ru" "-rf" "-ri" "-rx" "-r --parents" "-r --copy-contents" "-r --no-preserve=mode" "-r --preserve=mode" "-r --preserve=timestamps" "-r --preserve=links" "-r --preserve=all" "-r --no-preserve=all" "-r --attributes-only" "-r --sparse=always" "-r --sparse=never" "-r --reflink=never" "-r --backup" "-r -b"; do
    run_tree "cp $o dir" "$SETUP" $o d z
    run_tree "cp $o dir existing" "$SETUP" $o d e
    run_tree "cp $o many" "$SETUP" $o d a l dl empty e
done
run_tree "cp -r into self" "$SETUP" -r d d/sub
run_tree "cp -r into self 2" "$SETUP" -r e e/x
run_tree "cp -r . into" "$SETUP" -r . e
run_tree "cp -a hard links" "$SETUP; ln a d/h2" -a . z
run_tree "cp -r hard links" "$SETUP; ln a d/h2" -r d e
run_tree "cp -rd hard links" "$SETUP; ln a d/h2" -rd d a e
run_tree "cp -a symlink loop" "$SETUP; ln -s .. d/sub/up" -a d z
run_tree "cp -rL symlink loop" "$SETUP; ln -s .. d/sub/up" -rL d z
run_tree "cp -rL" "$SETUP" -rL dl z
run_tree "cp -rH" "$SETUP" -rH dl z
run_tree "cp -rP" "$SETUP" -rP dl z
run_tree "cp -r dl/" "$SETUP" -r dl/ z
run_tree "cp -r unreadable dir" "$SETUP; chmod 000 d/sub" -r d z
run_tree "cp -r dir onto file" "$SETUP" -r d a
run_tree "cp -r file onto dir" "$SETUP; mkdir z" -r a z
run_tree "cp -r dir onto dir" "$SETUP; mkdir z" -r d z
run_tree "cp -r ro" "$SETUP" -r ro z
run_tree "cp -r ro -p" "$SETUP" -rp ro z
run_tree "cp -r ro existing" "$SETUP" -r ro e
run_tree "cp -r mode bits" "$SETUP; chmod 4755 d; chmod 1777 d/sub" -r d z
run_tree "cp -rp mode bits" "$SETUP; chmod 4755 d; chmod 1777 d/sub" -rp d z
run_tree "cp -ra fifo" "$SETUP" -ra ff z
run_tree "cp -r fifo" "$SETUP" -r ff z
run_tree "cp -r --copy-contents fifo" "$SETUP; echo hi > e/in" -r --copy-contents e z

printf "\n[ Links ]\n"
for o in -l -s -ls -lf -sf -sv -lv "-s -f" "-l -f" "-L -l" "-P -l" "-H -l" -sL -sP; do
    run_tree "cp $o" "$SETUP" $o a z
    run_tree "cp $o existing" "$SETUP" $o a b
    run_tree "cp $o symlink" "$SETUP" $o l z
    run_tree "cp $o dir" "$SETUP" $o a b e
    run_tree "cp $o dir/" "$SETUP" $o a e/
done
run_tree "cp -s relative" "$SETUP" -s d/f z
run_tree "cp -s relative in dir" "$SETUP" -s d/f e
run_tree "cp -s absolute" "$SETUP" -s "$PWD/a" e
run_tree "cp -s relative dir" "$SETUP" -s a d/f e
run_tree "cp -l dir" "$SETUP" -l d e
run_tree "cp -lr" "$SETUP" -lr d e
run_tree "cp -l same" "$SETUP" -l a hard
run_tree "cp -l same name" "$SETUP" -l a a
run_tree "cp -l and -s" "$SETUP" -l -s a z
run_tree "cp -lf same" "$SETUP" -lf a hard
run_tree "cp -L l" "$SETUP" -L l z
run_tree "cp -P l" "$SETUP" -P l z
run_tree "cp -H l" "$SETUP" -H l z
run_tree "cp -d l" "$SETUP" -d l z
run_tree "cp -a l" "$SETUP" -a l z
run_tree "cp -P l existing" "$SETUP" -P l b
run_tree "cp -P l existing link" "$SETUP; ln -s q z" -P l z
run_tree "cp -P l -f" "$SETUP; ln -s q z" -Pf l z
run_tree "cp -P dang" "$SETUP" -P dang z
run_tree "cp -L dang" "$SETUP" -L dang z
run_tree "cp -a hard hard" "$SETUP" -a a hard z
run_tree "cp -d hard hard" "$SETUP" -d a hard z
run_tree "cp --preserve=links hard hard" "$SETUP" --preserve=links a hard z

printf "\n[ Backup, update, interactive, no-clobber ]\n"
for o in -b "--backup" "--backup=none" "--backup=off" "--backup=simple" "--backup=never" "--backup=existing" "--backup=nil" "--backup=numbered" "--backup=t" "--backup=bogus" "--backup=n" "--backup=s" "-b -S .bak" "-S .bak" "--suffix=.orig" "--suffix=" "--suffix=/x" "-bS .bak --backup=numbered" "-bv" "-bf" "-bi" "-bn" "-bu" "--backup=numbered -v" "--backup=existing -v"; do
    run_tree "cp $o" "$SETUP" $o a b
    run_tree "cp $o twice" "$SETUP; cp a b; cp b a ; cp --backup=numbered a b" $o a b
    run_tree "cp $o dir" "$SETUP" $o a b e
    run_tree "cp $o same" "$SETUP" $o a a
    run_tree "cp $o -r" "$SETUP; cp -r d e" -r $o d e
done
run_tree "cp backup existing numbered" "$SETUP; : > b.~1~; : > b.~3~" --backup=existing a b
run_tree "cp backup numbered gap" "$SETUP; : > b.~1~; : > b.~9~; : > b.~x~; : > b.~09~" --backup=numbered a b
run_tree "cp backup 99" "$SETUP; : > b.~99~" --backup=numbered a b
run_tree "cp backup env" "$SETUP" -b a b
run_tree "cp backup symlink" "$SETUP; ln -s a z" -b b z
run_tree "cp backup dir existing" "$SETUP; mkdir z" -b -r d z
run_tree "cp backup f same" "$SETUP" -fb a a
run_tree "cp backup f same numbered" "$SETUP" -f --backup=numbered a a
run_tree "cp backup source is backup" "$SETUP; cp a a~" -b a~ a
run_tree "cp backup source is backup 2" "$SETUP; cp a a~" -b --backup=simple a a~
run_tree "cp -u newer" "$SETUP; touch -d 2001-01-01 b" -u a b
run_tree "cp -u older" "$SETUP; touch -d 2001-01-01 a" -u a b
run_tree "cp -u same" "$SETUP; touch -d 2001-01-01 a b" -u a b
run_tree "cp -u missing" "$SETUP" -u a z
run_tree "cp -u -v" "$SETUP; touch -d 2001-01-01 a" -uv a b
run_tree "cp -u -r" "$SETUP; cp -r d e; touch -d 2001-01-01 d/f" -ru d e
for u in all none none-fail older bogus a n "" ; do
    run_tree "cp --update=$u" "$SETUP; touch -d 2001-01-01 b" --update=$u a b
    run_tree "cp --update=$u new" "$SETUP" --update=$u a z
    run_tree "cp --update=$u -v" "$SETUP; touch -d 2001-01-01 b" -v --update=$u a b
    run_tree "cp --update=$u dir" "$SETUP" -r --update=$u d e
done
run_tree "cp --update" "$SETUP; touch -d 2001-01-01 b" --update a b
run_tree "cp -n" "$SETUP" -n a b
run_tree "cp -n new" "$SETUP" -n a z
run_tree "cp -nv" "$SETUP" -nv a b
run_tree "cp -n -i" "$SETUP" -n -i a b
run_tree "cp -i -n" "$SETUP" -i -n a b
run_tree "cp -nn" "$SETUP" -nn a b
run_tree "cp -n -u" "$SETUP" -n -u a b
run_tree "cp -n -r" "$SETUP" -nr d e
run_tree "cp -i yes" "$SETUP" -i a b
TREE_STDIN=/dev/null run_tree "cp -i eof" "$SETUP" -i a b
printf 'y\n' > "$TEST_TMP/yes"; printf 'n\n' > "$TEST_TMP/no"; printf 'yes please\nyes\n' > "$TEST_TMP/yes2"; printf '\n' > "$TEST_TMP/nl"; printf 'Y' > "$TEST_TMP/Y"
for r in yes no yes2 nl Y; do
    TREE_STDIN="$TEST_TMP/$r" run_tree "cp -i answer $r" "$SETUP" -i a b
    TREE_STDIN="$TEST_TMP/$r" run_tree "cp -i answer $r multi" "$SETUP" -i a b e
    TREE_STDIN="$TEST_TMP/$r" run_tree "cp -i answer $r unwritable" "$SETUP; chmod 444 b" -i a b
    TREE_STDIN="$TEST_TMP/$r" run_tree "cp -if answer $r unwritable" "$SETUP; chmod 444 b" -if a b
    TREE_STDIN="$TEST_TMP/$r" run_tree "cp -i answer $r -r" "$SETUP; cp -r d z" -ir d z
    TREE_STDIN="$TEST_TMP/$r" run_tree "cp -i answer $r new" "$SETUP" -i a z
done

printf "\n[ Preserve and attributes ]\n"
for o in -p --preserve --preserve=mode --preserve=ownership --preserve=timestamps --preserve=links --preserve=all --preserve=mode,timestamps --preserve=context --preserve=xattr --preserve=bogus --preserve=a "--preserve=mode --no-preserve=mode" --no-preserve=mode --no-preserve=all --no-preserve=timestamps --no-preserve=bogus "-p --no-preserve=ownership" -a "--attributes-only" "--attributes-only -p" "--attributes-only -r" "--attributes-only -l"; do
    run_tree "cp $o" "$SETUP; touch -d 2001-02-03 a; chmod 4750 a" $o a z
    run_tree "cp $o existing" "$SETUP; touch -d 2001-02-03 a; chmod 4750 a" $o a b
    run_tree "cp $o existing mode" "$SETUP; chmod 600 b; touch -d 2001-02-03 a" $o a b
done
TREE_TIMES=1 run_tree_t "cp -p times" "$SETUP; touch -d '2001-02-03 04:05:06.789' a" -p a z
TREE_TIMES=1 run_tree_t "cp --preserve=timestamps times" "$SETUP; touch -d '2001-02-03 04:05:06.789' a" --preserve=timestamps a z
TREE_TIMES=1 run_tree_t "cp -p times dir" "$SETUP; touch -d '2001-02-03 04:05:06.789' d d/f" -rp d z
TREE_TIMES=1 run_tree_t "cp -p symlink times" "$SETUP; touch -h -d '2001-02-03' l" -P -p l z
TREE_TIMES=1 run_tree_t "cp -a symlink times" "$SETUP; touch -h -d '2001-02-03' l" -a l z
TREE_TIMES=1 run_tree_t "cp -p times existing" "$SETUP; touch -d '2001-02-03 04:05:06.789' a" -p a b
TREE_TIMES=1 run_tree_t "cp -a times" "$SETUP; touch -d '2001-02-03 04:05:06.789' a d d/f" -a a d z
run_tree "cp umask 077" "$SETUP" a z
TREE_UMASK=077 run_tree "cp umask 077" "$SETUP" a z
TREE_UMASK=077 run_tree "cp umask 077 dir" "$SETUP" -r d z
TREE_UMASK=000 run_tree "cp umask 000 mode b" "$SETUP" b z
TREE_UMASK=077 run_tree "cp umask 077 -p" "$SETUP" -p b z
TREE_UMASK=077 run_tree "cp umask 077 --no-preserve=mode" "$SETUP" --no-preserve=mode b z
TREE_UMASK=022 run_tree "cp --no-preserve=mode dir" "$SETUP" -r --no-preserve=mode d z
TREE_UMASK=022 run_tree "cp --no-preserve=mode existing" "$SETUP; chmod 600 b" --no-preserve=mode a b
TREE_UMASK=277 run_tree "cp umask 277 dir" "$SETUP" -r d z
TREE_UMASK=277 run_tree "cp umask 277 file" "$SETUP" a z
TREE_UMASK=077 run_tree "cp umask 077 ro dir" "$SETUP" -r ro z
run_tree "cp executable" "$SETUP; chmod 755 a" a z
run_tree "cp setuid" "$SETUP; chmod 4755 a" a z
run_tree "cp setuid -p" "$SETUP; chmod 4755 a" -p a z
run_tree "cp setgid dir" "$SETUP; chmod 2755 d" -r d z
run_tree "cp sticky dir" "$SETUP; chmod 1755 d" -r d z
run_tree "cp unreadable file" "$SETUP; chmod 000 a" a z
run_tree "cp unreadable file -f" "$SETUP; chmod 000 a" -f a z
run_tree "cp unreadable file onto" "$SETUP; chmod 000 a" a b

printf "\n[ Sparse and data ]\n"
for s in never auto always bogus a n; do
    run_tree "cp --sparse=$s" "$SETUP" --sparse=$s sp2 z
    run_tree "cp --sparse=$s small" "$SETUP; printf '\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0' > zeros" --sparse=$s zeros z
    run_tree "cp --sparse=$s empty" "$SETUP" --sparse=$s empty z
done
for r in auto always never bogus; do
    run_tree "cp --reflink=$r" "$SETUP" --reflink=$r a z
done
run_tree "cp --reflink" "$SETUP" --reflink a z
run_tree "cp --reflink --sparse=always" "$SETUP" --reflink --sparse=always a z
run_tree "cp --sparse=never --reflink" "$SETUP" --sparse=never --reflink=always a z
run_tree "cp large" "$SETUP; seq 1 400000 > big" big z
run_tree "cp large -r" "$SETUP; seq 1 400000 > big" -r big z
run_tree "cp /dev/null" "$SETUP" /dev/null z
run_tree "cp /dev/zero head" "$SETUP" -r /dev/null e
run_tree "cp -a /dev/null" "$SETUP" -a /dev/null z
run_tree "cp --debug" "$SETUP" --debug a z
run_tree "cp --debug sparse" "$SETUP" --debug sp2 z
run_tree "cp --debug always" "$SETUP" --debug --sparse=always a z
run_tree "cp --debug reflink never" "$SETUP" --debug --reflink=never a z
run_tree "cp --debug existing" "$SETUP" --debug a b
run_tree "cp --debug -r" "$SETUP" --debug -r d z
run_tree "cp --debug -l" "$SETUP" --debug -l a z
run_tree "cp --debug -s" "$SETUP" --debug -s a z
run_tree "cp --debug -n" "$SETUP" --debug -n a b
run_tree "cp --debug -u" "$SETUP" --debug -u a b
run_tree "cp --debug --update=none" "$SETUP" --debug --update=none a b

printf "\n[ --parents and misc ]\n"
run_tree "cp --parents" "$SETUP" --parents d/sub/g e
run_tree "cp --parents -v" "$SETUP" --parents -v d/sub/g e
run_tree "cp --parents existing" "$SETUP; mkdir -p e/d" --parents d/sub/g e
run_tree "cp --parents -p" "$SETUP; touch -d 2001-01-01 d d/sub" --parents -p d/sub/g e
run_tree "cp --parents -a" "$SETUP" --parents -a d/sub/g e
run_tree "cp --parents file" "$SETUP" --parents a e
run_tree "cp --parents dir" "$SETUP" --parents -r d/sub e
run_tree "cp --parents several" "$SETUP" --parents d/f d/sub/g a e
run_tree "cp --parents no dir" "$SETUP" --parents d/f z
run_tree "cp --parents file dest" "$SETUP" --parents a b
run_tree "cp --parents absolute" "$SETUP" --parents "$PWD/d/f" e
run_tree "cp --parents dotdot" "$SETUP" --parents ../x e
run_tree "cp --parents missing" "$SETUP" --parents nosuch/x e
run_tree "cp --parents non-dir" "$SETUP" --parents a/x e
run_tree "cp --parents -t" "$SETUP" --parents -t e d/f
run_tree "cp --parents mode" "$SETUP; chmod 500 d d/sub" --parents d/sub/g e
run_tree "cp --parents mode -p" "$SETUP; chmod 500 d d/sub" --parents -p d/sub/g e
run_tree "cp --path" "$SETUP" --path d/f e
run_tree "cp same file twice" "$SETUP" a a e
run_tree "cp same file twice ./" "$SETUP" a ./a e
run_tree "cp same file twice -b" "$SETUP" -b a a e
run_tree "cp same dest twice" "$SETUP" a d/f d/f e
run_tree "cp same base" "$SETUP; echo q > e/b" a d/f e
run_tree "cp same names" "$SETUP; mkdir x; echo q > x/a" a x/a e
run_tree "cp just-created" "$SETUP; mkdir x; echo q > x/a" a x/a e
run_tree "cp just-created -b" "$SETUP; mkdir x; echo q > x/a" -b a x/a e
run_tree "cp just-created numbered" "$SETUP; mkdir x; echo q > x/a" --backup=numbered a x/a e
run_tree "cp -v multiple" "$SETUP" -v a b l empty e
run_tree "cp -vr" "$SETUP" -vr d e
run_tree "cp -vf" "$SETUP; chmod 444 b" -vf a b
run_tree "cp -vi" "$SETUP" -vi a b
run_tree "cp bad option" "$SETUP" -z a b
run_tree "cp bad long option" "$SETUP" --bogus a b
run_tree "cp amb option" "$SETUP" --pa a b
run_tree "cp -- " "$SETUP" -- -a z
run_tree "cp file named -" "$SETUP; echo q > ./-x" -- -x z
run_tree "cp empty name" "$SETUP" "" z
run_tree "cp to empty name" "$SETUP" a ""
run_tree "cp long name" "$SETUP" a "$(printf 'n%.0s' $(seq 300))"
run_tree "cp -Z" "$SETUP" -Z a z
run_tree "cp --context" "$SETUP" --context a z
run_tree "cp --keep-directory-symlink" "$SETUP; mkdir real; ln -s real z" -r --keep-directory-symlink d z
run_tree "cp -r symlink dest dir" "$SETUP; ln -s e z" -r d z
run_tree "cp -r symlink dest dir/" "$SETUP; ln -s e z" -r d z/
run_tree "cp dir symlink to dir dest" "$SETUP" a dl
run_tree "cp onto symlink dir" "$SETUP" a dl/
cd /; print_summary
