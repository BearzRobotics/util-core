#!/bin/sh
# install: differential tests against GNU install 9.7 (C locale). References:
# GNU manual "install invocation". Each case runs in two fresh directories.
UTIL="install"
. "$(dirname "$0")/testlib.sh"
help_cmp
export TREE_CONTENT=1 TREE_OWNER=1
SETUP='mkdir -p d/sub e; printf "one\n" > a; printf "two\n" > b; printf x > d/f; ln -s a l; ln -s nowhere dang; ln -s d dl; ln a hard; mkfifo ff; : > empty; chmod 640 b; touch -d 2001-02-03 old; chmod 4755 old; mkdir ro; chmod 555 ro'

# run_tree_t: every file gets the same timestamp first so that only the times
# set by the command are compared.
run_tree_t() {
    d="$1"; su="$2"; shift 2
    extra="${su#"$SETUP"}"
    run_tree "$d" "$SETUP; find . -exec touch -h -d '2000-01-01 00:00:00' {} +$extra" "$@"
}

for args in "a z" "a b" "a empty" "a nosuch/z" "nosuch z" "a a" "a hard" "l z" "dang z" "a e" "a d" "a e/" "a b e" "a b z" "a l" "d z" "dl z" "a dl" "a dl/" "empty z" "old z" "/dev/null z" "a ro" "a ro/z" "a b c d"; do
    run_tree "install $args" "$SETUP" $args
    run_tree "install -v $args" "$SETUP" -v $args
    run_tree "install -p $args" "$SETUP" -p $args
done
for m in 0 600 644 755 777 4755 2755 1777 u+x a+rwx go-rwx u=rw,g=r,o= +x -x =x a-w 7777 0000 u+s,g+s,o+t bogus 8 99999 ''; do
    run_tree "install -m $m" "$SETUP" -m "$m" a z
    run_tree "install -m $m existing" "$SETUP" -m "$m" a b
    run_tree "install -m $m dir" "$SETUP" -m "$m" a b e
    run_tree "install -dm $m" "$SETUP" -d -m "$m" x/y/z
    run_tree "install -m $m -D" "$SETUP" -m "$m" -D a q/r/z
done
for u in 077 000 022 027; do
    TREE_UMASK=$u run_tree "install umask $u" "$SETUP" a z
    TREE_UMASK=$u run_tree "install umask $u -d" "$SETUP" -d x/y/z
    TREE_UMASK=$u run_tree "install umask $u -D" "$SETUP" -D a q/r/z
done
run_tree "install -d simple" "$SETUP" -d x
run_tree "install -d nested" "$SETUP" -d x/y/z
run_tree "install -d many" "$SETUP" -d x y/z w/v/u
run_tree "install -dv" "$SETUP" -dv x/y/z x/y/w
run_tree "install -d existing" "$SETUP" -d d
run_tree "install -d existing mode" "$SETUP" -d -m 700 d
run_tree "install -d existing file" "$SETUP" -d a
run_tree "install -d under file" "$SETUP" -d a/b
run_tree "install -d symlink" "$SETUP" -d dl
run_tree "install -d symlink child" "$SETUP" -d dl/new
run_tree "install -d trailing slash" "$SETUP" -d x/y/
run_tree "install -d double slash" "$SETUP" -d x//y
run_tree "install -d dotdot" "$SETUP" -d x/../y
run_tree "install -d no operand" "" -d
run_tree "install -d -s" "$SETUP" -d -s x
run_tree "install -d -t" "$SETUP" -d -t e x
run_tree "install -d unwritable" "$SETUP" -d ro/x
run_tree "install -d -g" "$SETUP; id -gn > gname" -d -g "$(id -gn)" x
run_tree "install -d -g bad" "$SETUP" -d -g nosuchgroup x
run_tree "install -d -o" "$SETUP" -d -o "$(id -un)" x
run_tree "install -d -o root" "$SETUP" -d -o root x
run_tree "install -d -o bad" "$SETUP" -d -o nosuchuser x
run_tree "install -D simple" "$SETUP" -D a q/r/z
run_tree "install -D existing" "$SETUP" -D a e/z
run_tree "install -D no parent" "$SETUP" -D a z
run_tree "install -D -t" "$SETUP" -D -t q/r a b
run_tree "install -D -t existing" "$SETUP" -D -t e a b
run_tree "install -D -t missing nested" "$SETUP" -Dv -t q/r/s a
run_tree "install -D dir dest" "$SETUP" -D a e/
run_tree "install -D under file" "$SETUP" -D a b/x/y
run_tree "install -D -T" "$SETUP" -D -T a q/z
run_tree "install -t" "$SETUP" -t e a b
run_tree "install -t missing" "$SETUP" -t nosuch a
run_tree "install -t file" "$SETUP" -t a b
run_tree "install -t -T" "$SETUP" -t e -T a
run_tree "install -t twice" "$SETUP" -t e -t e a
run_tree "install -T" "$SETUP" -T a z
run_tree "install -T dir" "$SETUP" -T a e
run_tree "install -T extra" "$SETUP" -T a b z
run_tree "install no operand" ""
run_tree "install one operand" "$SETUP" a
run_tree "install same file twice" "$SETUP" a a e
run_tree "install over symlink" "$SETUP; ln -s a z" b z
run_tree "install over dangling symlink" "$SETUP; ln -s nonex z" b z
run_tree "install over dir" "$SETUP; mkdir z" b z
run_tree "install unwritable dst" "$SETUP; chmod 444 b" a b
run_tree "install unreadable src" "$SETUP; chmod 000 a" a z
run_tree "install onto itself" "$SETUP" a ./a
run_tree "install hard onto itself" "$SETUP" a hard
for o in -c -C -b "-b -S .bak" "--backup" "--backup=numbered" "--backup=bogus" "-bv" "-Cv" "-C -m 600" "-C -m 4755" "-C -p" "-C -s" "-Z" "--preserve-context" "--debug" "--strip-program=true" "-s" "-s --strip-program=nosuchprog" "-s --strip-program=false" "--strip-program=true" "-S .x" "-p -C"; do
    run_tree "install $o" "$SETUP" $o a b
    run_tree "install $o new" "$SETUP" $o a z
    run_tree "install $o twice" "$SETUP; cp a z" $o a z
    run_tree "install $o same content" "$SETUP; cp a z; chmod 755 z" $o a z
    run_tree "install $o dir" "$SETUP" $o a b e
done
TREE_TIMES=1 run_tree_t "install -p times" "$SETUP" -p old z
TREE_TIMES=1 run_tree_t "install -p times existing" "$SETUP" -p old b
TREE_TIMES=1 run_tree_t "install -p dev null" "$SETUP" -p /dev/null z
TREE_TIMES=1 run_tree_t "install -C times" "$SETUP; cp -p a z; chmod 755 z" -C a z
run_tree "install -o -g" "$SETUP" -o "$(id -un)" -g "$(id -gn)" a z
run_tree "install -o numeric" "$SETUP" -o "$(id -u)" a z
run_tree "install -g numeric" "$SETUP" -g "$(id -g)" a z
run_tree "install -o root" "$SETUP" -o root a z
run_tree "install -g root" "$SETUP" -g root a z
run_tree "install -g bad" "$SETUP" -g nosuchgroup a z
run_tree "install -o bad" "$SETUP" -o nosuchuser a z
run_tree "install -o neg" "$SETUP" -o -1 a z
run_tree "install -g huge" "$SETUP" -g 99999999999999 a z
run_tree "install -o,-g other" "$SETUP" -g "$(id -G | tr ' ' '\n' | tail -1)" a z
run_tree "install bad option" "$SETUP" -z a b
run_tree "install bad long option" "$SETUP" --bogus a b
run_tree "install -- " "$SETUP" -- a z
run_tree "install file named -" "$SETUP; echo q > ./-x" -- -x z
run_tree "install -s file named -" "$SETUP; echo q > ./-x" -s --strip-program=true -- -x z
run_tree "install strip-program no -s" "$SETUP" --strip-program=true a z
run_tree "install -C -p" "$SETUP" -C -p a z
run_tree "install -C -s" "$SETUP" -C -s a z
run_tree "install -d -s" "$SETUP" -d -s x
run_tree "install -d -t" "$SETUP" -d -t e x
run_tree "install empty name" "$SETUP" "" z
run_tree "install to empty name" "$SETUP" a ""
run_tree "install long name" "$SETUP" a "$(printf 'n%.0s' $(seq 300))"
cd /; print_summary
