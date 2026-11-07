#!/bin/sh
# ln: differential tests against GNU ln 9.7 (C locale). The trees compared
# include symlink targets.
UTIL="ln"
. "$(dirname "$0")/testlib.sh"
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
print_summary
