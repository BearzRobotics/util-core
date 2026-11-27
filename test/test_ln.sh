#!/bin/sh
# ln: differential tests against GNU ln 9.7 (C locale). The trees compared
# include symlink targets.
UTIL="ln"
. "$(dirname "$0")/testlib.sh"
TREE_LINKS=1    # a copy must not pass for a hard link
S='echo A > a; echo B > b; mkdir d; echo C > d/c; ln -s a sl; ln -s d sd; ln -s nowhere dang'

printf "\n[ Hard links ]\n"
run_tree "a b"                     "$S" a new
run_tree "existing dest"           "$S" a b
run_tree "-f existing"             "$S" -f a b
run_tree "into directory"          "$S" a d
run_tree "into directory slash"    "$S" a d/
run_tree "two files into dir"      "$S" a b d
run_tree "source missing"          "$S" nofile x
run_tree "source directory"        "$S" d x
run_tree "source symlink default"  "$S" sl x
run_tree "-L symlink source"       "$S" -L sl x
run_tree "-P symlink source"       "$S" -P sl x
run_tree "dangling source"         "$S" dang x
run_tree "same file"               "$S" a a
run_tree "same file -f"            "$S" -f a a
run_tree "link twice same name"    "$S" a x x
run_tree "one operand"             "$S" a
run_tree "one operand in subdir"   "$S" d/c
run_tree "no operand"              "$S"
run_tree "three, last not dir"     "$S" a b x
run_tree "dest in missing dir"     "$S" a nodir/x
run_tree "dest is symlink to dir"  "$S" a sd
run_tree "-n dest symlink to dir"  "$S" -n a sd
run_tree "-T to dir"               "$S" -T a d
run_tree "-T plain"                "$S" -T a new
run_tree "-T three"                "$S" -T a b new
run_tree "-T one"                  "$S" -T a
run_tree "-t dir"                  "$S" -t d a b
run_tree "-t not dir"              "$S" -t a b
run_tree "-t missing"              "$S" -t nodir a
run_tree "-t and -T"               "$S" -t d -T a
run_tree "-v"                      "$S" -v a new
run_tree "-v into dir"             "$S" -v a b d
run_tree "-fv"                     "$S" -fv a b
run_tree "name with space"         'echo A > "a b"' "a b" "c d"
run_tree "trailing slash source"   "$S" a/ x

printf "\n[ Symbolic links ]\n"
run_tree "-s a new"                "$S" -s a new
run_tree "-s existing"             "$S" -s a b
run_tree "-sf existing"            "$S" -sf a b
run_tree "-s missing target"       "$S" -s nofile new
run_tree "-s into dir"             "$S" -s a d
run_tree "-s two into dir"         "$S" -s a b d
run_tree "-s one operand"          "$S" -s a
run_tree "-s dir/file one operand" "$S" -s d/c
run_tree "-s absolute"             "$S" -s /etc/passwd new
run_tree "-sv"                     "$S" -sv a new
run_tree "-sfv"                    "$S" -sfv a b
run_tree "-sn over symlink to dir" "$S" -sn a sd
run_tree "-s over symlink to dir"  "$S" -s a sd
run_tree "-sT"                     "$S" -sT a new
run_tree "-sT dir"                 "$S" -sT a d
run_tree "-st"                     "$S" -st d a b
run_tree "-s to dir"               "$S" -s d new
run_tree "-s slash target"         "$S" -s d/ new
run_tree "-s same name"            "$S" -s a a
run_tree "-sf same name"           "$S" -sf a a
run_tree "-s dangling"             "$S" -s dang new

printf "\n[ Relative links ]\n"
run_tree "-sr same dir"            "$S" -sr a new
run_tree "-sr into dir"            "$S" -sr a d/new
run_tree "-sr from subdir"         "$S" -sr d/c new
run_tree "-sr dir to dir"          "$S" -sr d d/inner
run_tree "-sr absolute source"     "$S" -sr /etc/passwd new
run_tree "-sr multiple"            "$S" -sr a b d
run_tree "-r without -s"           "$S" -r a new

printf "\n[ Backups ]\n"
run_tree "-b"                      "$S" -b a b
run_tree "-sb"                     "$S" -sb a b
run_tree "--backup"                "$S" --backup a b
run_tree "--backup=simple"         "$S" --backup=simple a b
run_tree "--backup=numbered"       "$S" --backup=numbered a b
run_tree "--backup=numbered twice" 'echo A > a; echo B > b; ln -s x b.~1~' --backup=numbered a b
run_tree "--backup=existing"       'echo A > a; echo B > b; echo old > b.~1~' --backup=existing a b
run_tree "--backup=existing none"  "$S" --backup=existing a b
run_tree "--backup=none"           "$S" --backup=none a b
run_tree "--backup=bogus"          "$S" --backup=bogus a b
run_tree "-S suffix"               "$S" -b -S .bak a b
# Backup naming is the same as cp's, mv's and install's.
B='echo A > a; echo cur > b; echo oldsimple > b~'
run_tree "existing: only .~10~ left"  "$B; echo ten > b.~10~" -f -b -s a b
run_tree "numbered: after the highest" "$B; echo five > b.~5~" -f --backup=numbered -s a b
run_tree "numbered: past a gap"      "$B; : > b.~1~; : > b.~9~" --backup=t a b
run_tree "-S alone makes a backup"   "$S" -S .bak a b
run_tree "-f -S keeps the old file"  "$B" -f -S .bak a b
run_tree "--suffix= alone"           "$B" -f --suffix=.orig a b
run_tree "empty suffix is ~"         "$S" -b -S '' a b
run_tree "suffix with a slash is ~"  "$S; mkdir sub" -b -S /../sub/x a b
run_tree "-S .bak --backup=numbered" "$S" -S .bak --backup=numbered a b
run_tree "--backup= (empty)"         "$S" --backup= a b
for v in numbered existing simple none bogus ''; do
    VERSION_CONTROL=$v run_tree "VERSION_CONTROL='$v' -b" "$S" -b a b
done
for v in '' /x .env; do
    SIMPLE_BACKUP_SUFFIX=$v run_tree "SIMPLE_BACKUP_SUFFIX='$v'" "$S" -b a b
done
run_tree "--suffix=.orig"          "$S" -b --suffix=.orig a b
run_tree "-bv"                     "$S" -bv a b
run_tree "-sbv"                    "$S" -sbv a b

printf "\n[ Interactive ]\n"
run_tree "-i without tty input"    "$S" -i a b
run_tree "-i no conflict"          "$S" -i a new

printf "\n[ Errors and odd forms ]\n"
run_tree "-x"                      "$S" -x a b
run_tree "--bogus"                 "$S" --bogus a b
run_tree "--"                      'echo A > ./-x' -- -x y
run_tree "empty source"            "$S" '' x
run_tree "empty dest"              "$S" a ''
run_tree "-S missing arg"          "$S" a b -S
run_tree "unreadable dest dir"     'echo A > a; mkdir d; chmod 500 d' a d/x
run_tree "-d -F accepted"          "$S" -d -F a new

printf "\n[ A link that cannot be made leaves the destination alone ]\n"
LONG=$(awk 'BEGIN { while (n++ < 5000) printf "a" }')
# (the symlink target is too long; GNU keeps b, and restores it after -b)
run_tree "-sf failure keeps dest"   "$S" -sf "$LONG" b
run_tree "-sfb failure restores"    "$S" -sfb "$LONG" b
run_tree "-sb failure restores"     "$S" -sb "$LONG" b
run_tree "-sf failure into dir"     "$S; echo D > d/x" -sf "$LONG" d/x
# A hard link to another file system.
other=$(mktemp /dev/shm/lntest.XXXXXX 2>/dev/null)
if [ -n "$other" ] && [ "$(stat -c %d "$other")" != "$(stat -c %d "$TEST_TMP")" ]; then
    run_tree "-f across devices keeps dest"  "$S" -f "$other" b
    run_tree "-fb across devices restores"   "$S" -f -b "$other" b
    run_tree "-b across devices restores"    "$S" -b "$other" b
else
    skip_test "hard links across devices (no second file system)"
fi
[ -z "$other" ] || rm -f "$other"
run_tree "-f replaces a hard link"  "$S" -f a b
run_tree "-sf replaces"             "$S" -sf a b
run_tree "-sf replaces in subdir"   "$S" -sf a d/c

printf "\n[ Same file ]\n"
# The destination is the only name of the data the source leads to.
ONE='echo data > a; ln -s a l; ln -s l l2; mkdir d; echo data > d/b; ln -s d/b m'
TWO='echo data > a; ln a h; ln -s a l'
export TREE_CONTENT=1
run_tree "-sf link to dest"          "$ONE" -sf l a
run_tree "-sf link chain to dest"    "$ONE" -sf l2 a
run_tree "-sf link into subdir"      "$ONE" -sf m d/b
run_tree "-sfn link to dest"         "$ONE" -sfn l a
run_tree "-sf same entry"            "$ONE" -sf ./a a
run_tree "-sf same entry, two names" "$TWO" -sf ./a a
run_tree "-sf other hard link"       "$TWO" -sf a h
run_tree "-f other hard link"        "$TWO" -f a h
run_tree "-sf link, data kept by h"  "$TWO" -sf l a
run_tree "-Lf link to dest"          "$ONE" -Lf l a
run_tree "-f onto own symlink"       "$ONE" -f a l
run_tree "-sf onto own symlink"      "$ONE" -sf a l
run_tree "-sfb link to dest"         "$ONE" -sfb l a
run_tree "-b onto itself"            "$ONE" -b a a
run_tree "-b onto other hard link"   "$TWO" -b a h
unset TREE_CONTENT
# -i: GNU 9.7 answers "yes" by destroying the data; we refuse as with -f.
d=$(mktemp -d); echo data > "$d/a"; ln -s a "$d/l"
out=$(cd "$d" && echo y | ours -si l a 2>&1); rc=$?
if [ "$rc" -eq 1 ] && [ "$(cat "$d/a")" = data ] && [ ! -L "$d/a" ]; then
    PASS=$((PASS + 1)); echo "PASS -si link to dest is refused"
else
    FAIL=$((FAIL + 1)); echo "FAIL -si link to dest is refused (rc=$rc $out)"
fi
rm -rf "$d"
# A hard link of a symbolic link, put in place of the file the link leads to,
# would point at itself and lose the data. GNU 9.7 does that; we refuse.
for case in "-f l a" "-fn l a" "-f m a" "-f sub/up a" "-i l a" "-f l ./a"; do
    d=$(mktemp -d); echo data > "$d/a"; ln -s a "$d/l"; ln -s l "$d/m"; mkdir "$d/sub"; ln -s ../a "$d/sub/up"
    out=$(cd "$d" && echo y | ours $case 2>&1); rc=$?
    set -- $case
    if [ "$rc" -eq 1 ] && [ "$out" = "ln: '$2' and '$3' are the same file" ] && [ "$(cat "$d/a")" = data ] && [ ! -L "$d/a" ]; then
        PASS=$((PASS + 1)); echo "PASS ln $case keeps the data"
    else
        FAIL=$((FAIL + 1)); echo "FAIL ln $case keeps the data (rc=$rc $out)"
    fi
    rm -rf "$d"
done
# The data stays reachable: through another name, or in the backup.
TREE_CONTENT=1
run_tree "-f link to a file with two names" 'echo data > a; ln a h; ln -s h l' -f l a
run_tree "-fb link to dest"                 'echo data > a; ln -s a l' -fb l a
run_tree "-f link to another file"          'echo data > a; echo b > b; ln -s b l' -f l a
run_tree "-f dangling link"                 'echo data > a; ln -s nowhere l' -f l a
unset TREE_CONTENT
# One line of standard input answers one -i question (FSOP-018).
for answers in 'n\ny\n' 'y\nn\n' 'nnnnnnnn\ny\n' 'yes\nyes\n' 'n' ''; do
    for who in gnu ours; do
        rm -rf "$TEST_TMP/ans" && mkdir -p "$TEST_TMP/ans/d" && ( cd "$TEST_TMP/ans" && echo x > x && echo y > y && echo old > d/x && echo old > d/y )
        out=$( cd "$TEST_TMP/ans" && printf "$answers" | LC_ALL=C $who -i x y d/ > ../ans.out 2>&1; echo "status $?"; sed 's|/usr/bin/ln:|ln:|g' ../ans.out; cat "$TEST_TMP/ans/d/x" "$TEST_TMP/ans/d/y" )
        eval "got_$who=\$out"
    done
    if [ "$got_gnu" = "$got_ours" ]; then PASS=$((PASS + 1)); echo "PASS -i answers '$answers'"
    else FAIL=$((FAIL + 1)); echo "FAIL -i answers '$answers'"; printf '     GNU : %s\n     OURS: %s\n' "$got_gnu" "$got_ours"; fi
done

print_summary
